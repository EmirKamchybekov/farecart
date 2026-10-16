import { Hono } from 'hono';
import { z } from 'zod';
import { parseQuery, TEN_MINUTES } from '../lib/http.js';
import { findFare, formatCents, withSavings } from '../lib/money.js';
import { FARE_RIDERS, fetchFares, type FareRow } from '../lib/supabase.js';

const Query = z.object({
  rider: z.enum(FARE_RIDERS).default('full'),
});

/** Transfer columns from the fares row (shared by bus and train today, but kept per row). */
function transferRules(row: FareRow) {
  return {
    transfer_cents: row.transfer_cents,
    transfer_window_min: row.transfer_window_min,
    max_transfers: row.max_transfers,
  };
}

export const fares = new Hono().get('/', async (c) => {
  const { rider } = parseQuery(c, Query);
  const rows = await fetchFares();

  const fullBus = findFare(rows, 'bus', 'full');
  const fullTrain = findFare(rows, 'train', 'full');
  const bus = findFare(rows, 'bus', rider);
  const train = findFare(rows, 'train', rider);

  c.header('Cache-Control', TEN_MINUTES);
  return c.json({
    agency: bus.agency,
    rider,
    effective_on: bus.effective_on,
    bus: { ...withSavings(bus, fullBus), ...transferRules(bus) },
    train: { ...withSavings(train, fullTrain), ...transferRules(train) },
    transfer_rules: { ...transferRules(bus), transfer_formatted: formatCents(bus.transfer_cents) },
    how_to_get: bus.how_to_get,
    signup_url: bus.signup_url,
    source_url: bus.source_url,
    riders_available: FARE_RIDERS,
  });
});
