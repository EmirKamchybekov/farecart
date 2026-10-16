import { Hono } from 'hono';
import { z } from 'zod';
import { metersToMiles, transitDirections } from '../lib/directions.js';
import { parseQuery } from '../lib/http.js';
import { LOCATION_TYPES, sbRpc, type LocationType, type NearbyRow } from '../lib/supabase.js';

const Query = z.object({
  lat: z.coerce.number().min(-90).max(90),
  lng: z.coerce.number().min(-180).max(180),
  types: z
    .string()
    .trim()
    .optional()
    .transform((s, ctx) => {
      if (!s) return undefined;
      const list = [...new Set(s.split(',').map((t) => t.trim().toLowerCase()).filter(Boolean))];
      const bad = list.filter((t) => !(LOCATION_TYPES as readonly string[]).includes(t));
      if (bad.length) {
        ctx.addIssue({ code: 'custom', message: `Unknown type(s): ${bad.join(', ')}. Allowed: ${LOCATION_TYPES.join(', ')}` });
        return z.NEVER;
      }
      return list as LocationType[];
    }),
  limit: z.coerce.number().int().min(1).max(100).default(25),
  radius_m: z.coerce.number().int().min(100).max(50_000).default(8000),
});

export const nearby = new Hono().get('/', async (c) => {
  const q = parseQuery(c, Query);
  const rows = await sbRpc<NearbyRow[]>('nearby_locations', {
    p_lat: q.lat,
    p_lng: q.lng,
    p_types: q.types ?? null,
    p_limit: q.limit,
    p_radius_m: q.radius_m,
  });

  const locations = rows.map((r) => ({
    ...r,
    distance_m: Math.round(r.distance_m),
    distance_miles: metersToMiles(r.distance_m),
    directions: transitDirections(r.lat, r.lng, r.name),
  }));

  c.header('Cache-Control', 'public, max-age=60, s-maxage=60');
  return c.json({
    origin: { lat: q.lat, lng: q.lng },
    radius_m: q.radius_m,
    types: q.types ?? [...LOCATION_TYPES],
    count: locations.length,
    locations,
  });
});
