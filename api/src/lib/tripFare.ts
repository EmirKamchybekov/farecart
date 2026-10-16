/**
 * CTA trip cost for an itinerary, from the `fares` table (never hardcoded).
 *
 * Rule (README "Trip cost rule"): the first transit boarding pays its mode's price
 * (bus -> mode='bus', any rail -> mode='train'). Each further boarding within
 * `transfer_window_min` of the boarding that started the fare costs `transfer_cents`,
 * up to `max_transfers`. A boarding beyond that or outside the window starts a new fare.
 * Walk-only -> $0. Non-CTA legs (Pace, Metra) are skipped and flagged, not guessed.
 */
import { findFare, formatCents } from './money.js';
import type { FareMode, FareRider, FareRow } from './supabase.js';
import type { LegMode } from './transitous.js';

export const NON_CTA_NOTE = 'Includes a non-CTA leg; fare not included';
const CTA_AGENCY = 'chicago transit authority';

export type FareLegInput = {
  mode: LegMode;
  agency_name: string | null;
  /** ISO 8601 boarding time (leg start). Missing/invalid -> treated as inside the window. */
  start_time: string | null;
};

export type TripCost = {
  rider_cents: number;
  rider_formatted: string;
  full_cents: number;
  full_formatted: string;
  savings_cents: number;
  /** Transit boardings in the itinerary (all agencies). */
  boardings: number;
  note?: string;
};

export function isCtaAgency(agencyName: string | null | undefined): boolean {
  return (agencyName ?? '').toLowerCase().includes(CTA_AGENCY);
}

function fareMode(mode: LegMode): FareMode | null {
  if (mode === 'bus') return 'bus';
  if (mode === 'train') return 'train';
  return null;
}

/** Cost in cents of the CTA boardings for one rider. */
export function ctaCostCents(legs: FareLegInput[], fares: FareRow[], rider: FareRider): number {
  let cents = 0;
  let fareStart: number | null = null; // ms epoch of the boarding that started the current fare
  let fareRow: FareRow | null = null; // row of that boarding (its window + transfer cap apply)
  let transfersUsed = 0;

  for (const leg of legs) {
    const mode = fareMode(leg.mode);
    if (!mode || !isCtaAgency(leg.agency_name)) continue;
    const row = findFare(fares, mode, rider);
    const at = leg.start_time ? Date.parse(leg.start_time) : NaN;

    const withinWindow =
      fareRow !== null &&
      (fareStart === null || Number.isNaN(at) || at - fareStart <= fareRow.transfer_window_min * 60_000);
    const transferAvailable = fareRow !== null && transfersUsed < fareRow.max_transfers;

    if (fareRow && withinWindow && transferAvailable) {
      cents += row.transfer_cents;
      transfersUsed += 1;
    } else {
      cents += row.price_cents;
      fareRow = row;
      fareStart = Number.isNaN(at) ? null : at;
      transfersUsed = 0;
    }
  }
  return cents;
}

export function tripCost(legs: FareLegInput[], fares: FareRow[], rider: FareRider): TripCost {
  const transit = legs.filter((l) => l.mode !== 'walk');
  const riderCents = ctaCostCents(legs, fares, rider);
  const fullCents = rider === 'full' ? riderCents : ctaCostCents(legs, fares, 'full');
  const cost: TripCost = {
    rider_cents: riderCents,
    rider_formatted: formatCents(riderCents),
    full_cents: fullCents,
    full_formatted: formatCents(fullCents),
    savings_cents: Math.max(0, fullCents - riderCents),
    boardings: transit.length,
  };
  if (transit.some((l) => !isCtaAgency(l.agency_name))) cost.note = NON_CTA_NOTE;
  return cost;
}
