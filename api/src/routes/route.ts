import { Hono } from 'hono';
import { z } from 'zod';
import { transitDirections } from '../lib/directions.js';
import { ApiError, errorBody, parseQuery } from '../lib/http.js';
import { FARE_RIDERS, fetchFares } from '../lib/supabase.js';
import { fetchPlan, mapPlan } from '../lib/transitous.js';
import { tripCost } from '../lib/tripFare.js';

const Query = z.object({
  from_lat: z.coerce.number().min(-90).max(90),
  from_lng: z.coerce.number().min(-180).max(180),
  to_lat: z.coerce.number().min(-90).max(90),
  to_lng: z.coerce.number().min(-180).max(180),
  rider: z.enum(FARE_RIDERS).default('full'),
  depart_at: z.iso
    .datetime({ offset: true, local: true })
    .optional()
    .transform((s) => (s ? new Date(s) : undefined)),
  n: z.coerce.number().int().min(1).max(6).default(3),
});

export const route = new Hono().get('/', async (c) => {
  const q = parseQuery(c, Query);
  const origin = { lat: q.from_lat, lng: q.from_lng };
  const destination = { lat: q.to_lat, lng: q.to_lng };
  const fallback = transitDirections(destination.lat, destination.lng, undefined, origin);

  const planParams = q.depart_at
    ? { from: origin, to: destination, numItineraries: q.n, departAt: q.depart_at }
    : { from: origin, to: destination, numItineraries: q.n };

  const [faresResult, planResult] = await Promise.allSettled([fetchFares(), fetchPlan(planParams)]);
  if (faresResult.status === 'rejected') throw faresResult.reason;

  if (planResult.status === 'rejected') {
    const reason = planResult.reason;
    const message = reason instanceof Error ? reason.message : 'Transitous request failed';
    const details = reason instanceof ApiError ? reason.details : undefined;
    console.warn(`Transitous unavailable: ${message}`);
    c.header('Cache-Control', 'no-store');
    return c.json(
      { ...errorBody('upstream_unavailable', `Transit routing is temporarily unavailable (${message})`, details), origin, destination, rider: q.rider, fallback },
      502,
    );
  }

  const fares = faresResult.value;
  const itineraries = mapPlan(planResult.value, q.n).map((it) => ({
    ...it,
    cost: tripCost(it.legs.map((l) => ({ mode: l.mode, agency_name: l.agency_name, start_time: l.from.time })), fares, q.rider),
  }));

  c.header('Cache-Control', 'public, max-age=30, s-maxage=30');
  return c.json({ origin, destination, rider: q.rider, depart_at: q.depart_at?.toISOString() ?? null, itineraries, fallback });
});
