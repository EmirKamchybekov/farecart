// Mirrors the live `fares` rows (agency=CTA) after migration 0003_fare_rules.sql.
import type { FareRow } from '../../src/lib/supabase.js';

const base = {
  agency: 'CTA',
  transfer_cents: 0,
  transfer_window_min: 120,
  max_transfers: 2,
  how_to_get: null,
  signup_url: null,
  effective_on: '2023-02-20',
  source_url: null,
} as const;

export const FARES: FareRow[] = [
  { ...base, id: 1, mode: 'bus', rider: 'full', price_cents: 225, label: 'Full fare bus' },
  { ...base, id: 2, mode: 'train', rider: 'full', price_cents: 250, label: 'Full fare train' },
  { ...base, id: 3, mode: 'bus', rider: 'reduced_access', price_cents: 110, label: 'Access reduced fare bus' },
  { ...base, id: 4, mode: 'train', rider: 'reduced_access', price_cents: 125, label: 'Access reduced fare train' },
  { ...base, id: 5, mode: 'bus', rider: 'student', price_cents: 75, label: 'Student reduced fare bus' },
  { ...base, id: 6, mode: 'train', rider: 'student', price_cents: 75, label: 'Student reduced fare train' },
];
