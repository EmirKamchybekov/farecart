/**
 * Transitous (community MOTIS instance) client + mapping to the Farecart itinerary shape.
 * https://api.transitous.org/api/v1/plan — free, no key, no SLA.
 */
import { createHash } from 'node:crypto';
import { optionalEnv } from '../env.js';
import { fetchJson } from './http.js';
import { detectPrecision, type PolylinePrecision } from './polyline.js';

export const TRANSITOUS_USER_AGENT = 'Farecart/0.1 (hello@farecart.org)';
export const TRANSITOUS_TIMEOUT_MS = 8000;

function baseUrl(): string {
  return (optionalEnv('TRANSITOUS_BASE_URL') ?? 'https://api.transitous.org').replace(/\/+$/, '');
}

// ---- upstream (MOTIS) shapes: only the fields we read ----

export type MotisPlace = {
  name?: string;
  lat: number;
  lon: number;
  departure?: string;
  arrival?: string;
  scheduledDeparture?: string;
  scheduledArrival?: string;
};

export type MotisLeg = {
  mode: string;
  from: MotisPlace;
  to: MotisPlace;
  duration: number;
  startTime: string;
  endTime: string;
  headsign?: string;
  routeShortName?: string;
  routeLongName?: string;
  routeColor?: string;
  routeTextColor?: string;
  agencyName?: string;
  legGeometry?: { points: string; precision?: number; length?: number };
  intermediateStops?: Array<{ name?: string; lat: number; lon: number }>;
};

export type MotisItinerary = {
  id?: string;
  duration: number;
  startTime: string;
  endTime: string;
  transfers: number;
  legs: MotisLeg[];
};

export type MotisPlanResponse = {
  itineraries?: MotisItinerary[];
  direct?: MotisItinerary[];
};

// ---- Farecart shapes ----

export type LegMode = 'walk' | 'bus' | 'train' | 'other';

export type RoutePlace = { name: string | null; lat: number; lng: number; time: string | null };

export type RouteLeg = {
  mode: LegMode;
  route_short_name: string | null;
  route_long_name: string | null;
  headsign: string | null;
  agency_name: string | null;
  from: RoutePlace;
  to: RoutePlace;
  duration_s: number;
  route_color: string | null;
  intermediate_stop_count: number;
  polyline: { points: string; precision: PolylinePrecision } | null;
};

export type RouteItinerary = {
  id: string;
  duration_s: number;
  start_time: string;
  end_time: string;
  transfers: number;
  legs: RouteLeg[];
};

const RAIL_MODES = new Set([
  'TRAM', 'SUBWAY', 'METRO', 'RAIL', 'HIGHSPEED_RAIL', 'LONG_DISTANCE', 'NIGHT_RAIL',
  'REGIONAL_FAST_RAIL', 'REGIONAL_RAIL',
]);
const BUS_MODES = new Set(['BUS', 'COACH']);

/** MOTIS mode -> walk | bus | train | other. CTA rail shows up as SUBWAY/RAIL/TRAM. */
export function mapMode(motisMode: string): LegMode {
  const m = motisMode.toUpperCase();
  if (m === 'WALK') return 'walk';
  if (BUS_MODES.has(m)) return 'bus';
  if (RAIL_MODES.has(m)) return 'train';
  return 'other';
}

function place(p: MotisPlace, time: string | undefined): RoutePlace {
  return { name: p.name ?? null, lat: p.lat, lng: p.lon, time: time ?? null };
}

export function mapLeg(leg: MotisLeg): RouteLeg {
  const geometry = leg.legGeometry?.points
    ? { points: leg.legGeometry.points, precision: detectPrecision(leg.legGeometry.points, leg.legGeometry.precision) }
    : null;
  return {
    mode: mapMode(leg.mode),
    route_short_name: leg.routeShortName ?? null,
    route_long_name: leg.routeLongName ?? null,
    headsign: leg.headsign ?? null,
    agency_name: leg.agencyName ?? null,
    from: place(leg.from, leg.from.departure ?? leg.startTime),
    to: place(leg.to, leg.to.arrival ?? leg.endTime),
    duration_s: leg.duration,
    route_color: leg.routeColor ?? null,
    intermediate_stop_count: leg.intermediateStops?.length ?? 0,
    polyline: geometry,
  };
}

/** MOTIS itinerary ids are ~500-char opaque blobs; expose a short stable hash instead. */
function shortId(it: MotisItinerary, index: number): string {
  const seed = it.id ?? `${index}:${it.startTime}:${it.endTime}:${it.legs.map((l) => l.mode).join(',')}`;
  return createHash('sha1').update(seed).digest('hex').slice(0, 12);
}

export function mapItinerary(it: MotisItinerary, index: number): RouteItinerary {
  return {
    id: shortId(it, index),
    duration_s: it.duration,
    start_time: it.startTime,
    end_time: it.endTime,
    transfers: it.transfers,
    legs: it.legs.map(mapLeg),
  };
}

/** Transit itineraries first, then any walk-only "direct" ones, capped at `limit`. */
export function mapPlan(plan: MotisPlanResponse, limit: number): RouteItinerary[] {
  const all = [...(plan.itineraries ?? []), ...(plan.direct ?? [])];
  return all.slice(0, limit).map(mapItinerary);
}

export type PlanParams = {
  from: { lat: number; lng: number };
  to: { lat: number; lng: number };
  numItineraries: number;
  departAt?: Date;
};

export async function fetchPlan(params: PlanParams): Promise<MotisPlanResponse> {
  const url = new URL(`${baseUrl()}/api/v1/plan`);
  url.searchParams.set('fromPlace', `${params.from.lat},${params.from.lng}`);
  url.searchParams.set('toPlace', `${params.to.lat},${params.to.lng}`);
  url.searchParams.set('numItineraries', String(params.numItineraries));
  if (params.departAt) {
    url.searchParams.set('time', params.departAt.toISOString());
    url.searchParams.set('arriveBy', 'false');
  }
  const plan = await fetchJson<MotisPlanResponse>(url, 'Transitous', {
    timeoutMs: TRANSITOUS_TIMEOUT_MS,
    headers: { 'User-Agent': TRANSITOUS_USER_AGENT, Accept: 'application/json' },
  });
  if (!plan || typeof plan !== 'object' || (!Array.isArray(plan.itineraries) && !Array.isArray(plan.direct))) {
    throw new Error('Transitous returned an unexpected body');
  }
  return plan;
}
