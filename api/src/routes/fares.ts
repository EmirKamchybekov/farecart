import { Hono } from 'hono';
import { z } from 'zod';
import { parseQuery, TEN_MINUTES } from '../lib/http.js';
import { findFare, withSavings } from '../lib/money.js';
import { FARE_RIDERS, fetchFares } from '../lib/supabase.js';

const Query = z.object({
  rider: z.enum(FARE_RIDERS).default('full'),
});

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
    bus: withSavings(bus, fullBus),
    train: withSavings(train, fullTrain),
    how_to_get: bus.how_to_get,
    signup_url: bus.signup_url,
    source_url: bus.source_url,
    riders_available: FARE_RIDERS,
  });
});
