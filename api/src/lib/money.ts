import { ApiError } from './http.js';
import type { FareMode, FareRider, FareRow } from './supabase.js';

export function formatCents(cents: number): string {
  return `$${(cents / 100).toFixed(2)}`;
}

export type Price = { price_cents: number; formatted: string };

export function price(cents: number): Price {
  return { price_cents: cents, formatted: formatCents(cents) };
}

export type PriceWithSavings = Price & {
  label: string;
  full_price_cents: number;
  full_formatted: string;
  savings_cents: number;
  savings_formatted: string;
  savings_pct: number;
};

export function findFare(fares: FareRow[], mode: FareMode, rider: FareRider): FareRow {
  const row = fares.find((f) => f.mode === mode && f.rider === rider);
  if (!row) {
    throw new ApiError(502, 'fare_missing', `No ${rider} ${mode} fare in the fares table`);
  }
  return row;
}

export function withSavings(row: FareRow, full: FareRow): PriceWithSavings {
  const savings = Math.max(0, full.price_cents - row.price_cents);
  return {
    ...price(row.price_cents),
    label: row.label,
    full_price_cents: full.price_cents,
    full_formatted: formatCents(full.price_cents),
    savings_cents: savings,
    savings_formatted: formatCents(savings),
    savings_pct: full.price_cents > 0 ? Math.round((savings / full.price_cents) * 100) : 0,
  };
}
