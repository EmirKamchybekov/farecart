import { requireEnv } from '../env.js';
import { fetchJson } from './http.js';

function headers(): Record<string, string> {
  const anon = requireEnv('SUPABASE_ANON_KEY');
  return {
    apikey: anon,
    Authorization: `Bearer ${anon}`,
    Accept: 'application/json',
  };
}

function baseUrl(): string {
  return requireEnv('SUPABASE_URL').replace(/\/+$/, '');
}

/** GET {SUPABASE_URL}/rest/v1/{table}?{query} with the anon key (RLS: public read). */
export async function sbSelect<T>(table: string, query: Record<string, string>): Promise<T[]> {
  const url = new URL(`${baseUrl()}/rest/v1/${table}`);
  for (const [k, v] of Object.entries(query)) url.searchParams.set(k, v);
  return fetchJson<T[]>(url, 'Supabase', { headers: headers() });
}

/** POST {SUPABASE_URL}/rest/v1/rpc/{fn} with the anon key. */
export async function sbRpc<T>(fn: string, args: Record<string, unknown>): Promise<T> {
  return fetchJson<T>(`${baseUrl()}/rest/v1/rpc/${fn}`, 'Supabase', {
    method: 'POST',
    headers: { ...headers(), 'Content-Type': 'application/json' },
    body: JSON.stringify(args),
  });
}

// ---- row types mirroring supabase/migrations/0001_init.sql + 0003_fare_rules.sql ----

export type LocationType = 'grocery' | 'pantry' | 'giveaway';
export const LOCATION_TYPES = ['grocery', 'pantry', 'giveaway'] as const satisfies readonly LocationType[];

export type NearbyRow = {
  id: string;
  name: string;
  type: LocationType;
  address: string;
  neighborhood: string | null;
  lat: number;
  lng: number;
  hours: Record<string, string> | null;
  hours_text: string | null;
  accepts_ebt: boolean | null;
  requirements: string | null;
  languages: string[] | null;
  phone: string | null;
  website: string | null;
  source_url: string | null;
  notes: string | null;
  verified_on: string | null;
  distance_m: number;
  source_kind: string;
  logo_url: string | null;
  /** 0007_pantry_scheduling.sql */
  pantry_model: 'client_choice' | 'pre_packed' | 'both' | null;
  requires_snap: boolean;
  requires_id: boolean | null;
  feedam_id: number | null;
};

// ---- pantry inventory + visit scheduling (0007_pantry_scheduling.sql) ----

export type PantryCategory = 'produce' | 'dairy' | 'protein' | 'canned' | 'bread' | 'baby' | 'water' | 'other';
export type PantryLevel = 'plenty' | 'low' | 'out';

export type PantryInventoryRow = {
  id: string;
  category: PantryCategory;
  level: PantryLevel;
  note: string | null;
  reported_at: string;
  expires_at: string;
  source: 'staff' | 'feedam' | 'demo';
};

export type PantrySlotRow = {
  id: string;
  starts_at: string;
  ends_at: string;
  capacity: number;
  booked: number;
  remaining: number;
  notes: string | null;
};

/** Return shape of the `pantry_availability(p_location_id)` RPC. */
export type PantryAvailability = {
  location_id: string;
  inventory: PantryInventoryRow[];
  slots: PantrySlotRow[];
  staff_updated_at: string | null;
};

export type FareMode = 'bus' | 'train';
export type FareRider = 'full' | 'reduced_access' | 'student' | 'senior_disabled';
export const FARE_RIDERS = ['full', 'reduced_access', 'student'] as const;

export type FareRow = {
  id: number;
  agency: string;
  mode: FareMode;
  rider: FareRider;
  price_cents: number;
  /** Cost of each further boarding within `transfer_window_min` of the first (0 = free). */
  transfer_cents: number;
  transfer_window_min: number;
  max_transfers: number;
  label: string;
  how_to_get: string | null;
  signup_url: string | null;
  effective_on: string | null;
  source_url: string | null;
};

export type ProgramRow = {
  key: string;
  name: string;
  who: string;
  what: string;
  how: string;
  signup_url: string | null;
  phone: string | null;
  source_url: string | null;
  updated_at: string;
};

export function fetchFares(): Promise<FareRow[]> {
  return sbSelect<FareRow>('fares', { select: '*', agency: 'eq.CTA', order: 'mode.asc,rider.asc' });
}

export function fetchPrograms(): Promise<ProgramRow[]> {
  return sbSelect<ProgramRow>('programs', { select: '*', order: 'key.asc' });
}
