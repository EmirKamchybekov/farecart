# Farecart API

Hono (TypeScript, ESM) on Vercel Functions. Thin, read-only JSON API over the live Supabase project,
the US Census geocoder (with Nominatim fallback), and CTA Bus Tracker.

## Layout

```
api/
  src/index.ts        Vercel entry: `export default app` (zero-config Hono preset)
  src/app.ts          Hono app, routes, CORS, error JSON
  src/dev.ts          Local server (@hono/node-server) for `npm run dev`
  src/routes/*.ts     One file per endpoint
  src/lib/*.ts        Supabase REST/RPC client, geocoding helpers, money, deep links
  test/smoke.mjs      Hits every route on a live server
```

## Run locally

```bash
cd api
npm install
cp .env.example .env.local   # or rely on ../.env.local at the repo root (auto-loaded)
npm run dev                  # http://localhost:3000
npm run typecheck
npm test                     # starts a server on a random port, runs test/smoke.mjs
BASE_URL=http://localhost:3000 npm test   # test an already-running server
```

Env vars: `SUPABASE_URL`, `SUPABASE_ANON_KEY` (required), `CTA_BUS_KEY`, `NOMINATIM_USER_AGENT`, `PORT` (optional).
Only the anon key is used; RLS makes every table public-read.

## Routes

All responses are JSON. CORS is open (`*`) for `GET`. Errors look like
`{"error":{"code":"bad_request","message":"...","details":[{"param":"lat","message":"..."}]}}`.

| Route | Cache | Notes |
|---|---|---|
| `GET /` | - | Route list |
| `GET /health` | no-store | `?deep=1` pings Supabase |
| `GET /nearby?lat&lng&types&limit&radius_m` | 60s | RPC `nearby_locations`; adds `distance_miles`, `directions.{apple,google}` |
| `GET /geocode?q=` | 1h / 1d | neighborhood table -> Census -> Nominatim; Chicago only |
| `GET /fares?rider=full\|reduced_access\|student` | 10 min | prices in cents + formatted + savings vs full |
| `GET /eligibility?snap=&student=` | 10 min | programs, best fare, one-line message, signup_url, phone |
| `GET /arrivals?stop_id=` | 20s | CTA Bus Tracker; `{available:false}` without `CTA_BUS_KEY` |

## curl examples

```bash
B=http://localhost:3000

curl "$B/health?deep=1"

# Nearest grocery stores and pantries to Garfield Park, within 5 km
curl "$B/nearby?lat=41.8807&lng=-87.7262&types=grocery,pantry&limit=10&radius_m=5000"

# Geocode a street address (Census), a POI (Nominatim fallback) and a neighborhood (instant)
curl "$B/geocode?q=4000+W+Madison+St"
curl "$B/geocode?q=Garfield+Park+Conservatory"
curl "$B/geocode?q=Little+Village"

# Fares for an Access (SNAP) rider
curl "$B/fares?rider=reduced_access"

# Discount quiz
curl "$B/eligibility?snap=true&student=false"
curl "$B/eligibility?snap=false&student=true"
curl "$B/eligibility?snap=false&student=false"

# Bus arrivals (stub until CTA_BUS_KEY is set)
curl "$B/arrivals?stop_id=1234"
```

### Example `/nearby` row

```json
{
  "id": "…", "name": "…", "type": "grocery", "address": "…", "neighborhood": "Austin",
  "lat": 41.88, "lng": -87.76, "hours": null, "hours_text": "Mon-Sat 8-8", "accepts_ebt": true,
  "requirements": null, "languages": ["en","es"], "phone": null, "website": null,
  "source_url": "…", "notes": null, "verified_on": null,
  "distance_m": 812, "distance_miles": 0.5,
  "directions": {
    "apple": "maps://?daddr=41.88%2C-87.76&dirflg=r&q=…",
    "google": "https://www.google.com/maps/dir/?api=1&destination=41.88%2C-87.76&travelmode=transit"
  }
}
```

## Deploy

```bash
cd api
vercel link --yes --project farecart-api
printf '%s' "$SUPABASE_URL"      | vercel env add SUPABASE_URL production preview development
printf '%s' "$SUPABASE_ANON_KEY" | vercel env add SUPABASE_ANON_KEY production preview development
vercel deploy --yes          # preview
vercel deploy --yes --prod   # production
```

`vercel.json` only sets `"framework": "hono"`; Vercel builds `src/index.ts` into a Fluid-compute function
that serves every path.
