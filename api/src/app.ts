import { Hono } from 'hono';
import { cors } from 'hono/cors';
import { HTTPException } from 'hono/http-exception';
import { ApiError, errorBody } from './lib/http.js';
import { arrivals } from './routes/arrivals.js';
import { eligibility } from './routes/eligibility.js';
import { fares } from './routes/fares.js';
import { geocode } from './routes/geocode.js';
import { health } from './routes/health.js';
import { nearby } from './routes/nearby.js';
import { route } from './routes/route.js';

export const ROUTES = [
  { method: 'GET', path: '/', description: 'This route list' },
  { method: 'GET', path: '/health', description: 'Liveness; add ?deep=1 to ping Supabase' },
  { method: 'GET', path: '/nearby', params: 'lat, lng, types=grocery,pantry,giveaway, limit=25, radius_m=8000', description: 'Nearest food locations with distance and transit deep links' },
  { method: 'GET', path: '/geocode', params: 'q=<address or neighborhood>', description: 'Address/neighborhood -> lat/lng (Chicago only)' },
  { method: 'GET', path: '/fares', params: 'rider=full|reduced_access|student', description: 'CTA bus/train prices and savings vs full fare' },
  { method: 'GET', path: '/eligibility', params: 'snap=true|false, student=true|false', description: 'Which discount program applies and the best fare' },
  { method: 'GET', path: '/arrivals', params: 'stop_id=<CTA bus stop>, route?', description: 'CTA Bus Tracker predictions (needs CTA_BUS_KEY)' },
  { method: 'GET', path: '/route', params: 'from_lat, from_lng, to_lat, to_lng, rider=full|reduced_access|student, depart_at=<ISO 8601>?, n=3', description: 'Transit itineraries (Transitous) with CTA trip cost for the rider; 502 + fallback deep links when routing is down' },
] as const;

const app = new Hono();

app.use('*', cors({ origin: '*', allowMethods: ['GET', 'OPTIONS'], maxAge: 86400 }));
app.use('*', async (c, next) => {
  await next();
  c.header('X-Content-Type-Options', 'nosniff');
});

app.get('/', (c) => c.json({ service: 'farecart-api', version: '0.1.0', routes: ROUTES }));
app.route('/health', health);
app.route('/nearby', nearby);
app.route('/geocode', geocode);
app.route('/fares', fares);
app.route('/eligibility', eligibility);
app.route('/arrivals', arrivals);
app.route('/route', route);

app.notFound((c) => c.json(errorBody('not_found', `No route for ${c.req.method} ${c.req.path}`), 404));

app.onError((err, c) => {
  if (err instanceof ApiError) {
    c.header('Cache-Control', 'no-store');
    return c.json(errorBody(err.code, err.message, err.details), err.status);
  }
  if (err instanceof HTTPException) {
    return c.json(errorBody('http_error', err.message), err.status);
  }
  console.error(err);
  return c.json(errorBody('internal_error', 'Unexpected server error'), 500);
});

export default app;
export type AppType = typeof app;
