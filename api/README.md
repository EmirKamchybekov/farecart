# Farecart API

Hono (TypeScript, ESM) on Vercel Functions. Thin, read-only JSON API over the live Supabase project,
the US Census geocoder (with Nominatim fallback), CTA Bus Tracker, and Transitous (MOTIS) transit routing.

## Layout

```
api/
  src/index.ts        Vercel entry: `export default app` (zero-config Hono preset)
  src/app.ts          Hono app, routes, CORS, error JSON
  src/dev.ts          Local server (@hono/node-server) for `npm run dev`
  src/routes/*.ts     One file per endpoint
  src/lib/*.ts        Supabase REST/RPC client, geocoding helpers, money, deep links,
                      transitous (plan client + leg mapping), tripFare (CTA cost rule), polyline
  test/unit/*.test.ts node:test unit tests (tripFare, polyline precision, /route against a fixture)
  test/fixtures/      Real Transitous /plan response captured with curl
  test/smoke.mjs      Hits every route on a live server (incl. /route against live Transitous)
```

## Run locally

```bash
cd api
npm install
cp .env.example .env.local   # or rely on ../.env.local at the repo root (auto-loaded)
npm run dev                  # http://localhost:3000
npm run typecheck
npm test                     # unit tests, then starts a server on a random port and runs test/smoke.mjs
npm run test:unit            # node:test only (no network; Transitous and Supabase are stubbed)
BASE_URL=http://localhost:3000 npm run test:smoke   # smoke-test an already-running server
```

Env vars: `SUPABASE_URL`, `SUPABASE_ANON_KEY` (required), `CTA_BUS_KEY`, `NOMINATIM_USER_AGENT`,
`TRANSITOUS_BASE_URL`, `PORT` (optional).
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
| `GET /fares?rider=full\|reduced_access\|student` | 10 min | prices in cents + formatted + savings vs full; `transfer_cents`, `transfer_window_min`, `max_transfers` per mode |
| `GET /eligibility?snap=&student=` | 10 min | programs, best fare, one-line message, signup_url, phone |
| `GET /arrivals?stop_id=` | 20s | CTA Bus Tracker; `{available:false}` without `CTA_BUS_KEY` |
| `GET /pantry/:id/availability` | 30s | RPC `pantry_availability`: inventory rows (not expired), next 14 days of slots with `remaining`, `staff_updated_at`; plus `feedam` status (cached 10 min, attribution "Directory published by Feed America (feedam.org)") when the pantry has a `feedam_id`, else `null` |
| `GET /route?from_lat&from_lng&to_lat&to_lng&rider&depart_at&n` | 30s | Transitous itineraries + CTA trip cost for the rider; 502 `upstream_unavailable` with `fallback` links when routing is down |

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

# Pantry inventory + visit slots (id from /nearby)
curl "$B/pantry/ab79ab95-d3c3-48ab-925b-4b4534e3ef3f/availability"

# Transit route: Madison & Pulaski -> Madison & Western, priced for an Access (SNAP) rider
curl "$B/route?from_lat=41.8807&from_lng=-87.7262&to_lat=41.8819&to_lng=-87.6868&rider=reduced_access"
# ...leaving at a given time, 2 options
curl "$B/route?from_lat=41.8807&from_lng=-87.7262&to_lat=41.8819&to_lng=-87.6868&rider=full&depart_at=2026-10-16T09:30:00-05:00&n=2"
```

### `/route`

Calls Transitous (`https://api.transitous.org/api/v1/plan`, community MOTIS, no key, no SLA) with the
`Farecart/0.1 (hello@farecart.org)` User-Agent and an 8s timeout. `rider` defaults to `full`,
`n` (1-6) to 3, `depart_at` (ISO 8601, offset or `Z`) to now.

MOTIS modes map to `walk | bus | train | other` (`BUS`/`COACH` -> bus; `TRAM`/`SUBWAY`/`RAIL`/`METRO`/...
-> train). Leg polylines are passed through still encoded; the server only decodes them to detect
the precision (7 is the MOTIS default, 5 the classic Google one) by checking the line lands in Chicago.

Trip cost follows the CTA rule in the root README, using the `fares` rows (never hardcoded): the first
transit boarding pays its mode's price; each further boarding within `transfer_window_min` of the
boarding that started the fare costs `transfer_cents`, up to `max_transfers`; after that (or outside the
window) a new fare starts. Walk-only is $0. Legs from agencies other than the Chicago Transit Authority
(Pace, Metra) are not priced and add `"note": "Includes a non-CTA leg; fare not included"`.

```json
{
  "origin": { "lat": 41.8807, "lng": -87.7262 },
  "destination": { "lat": 41.8819, "lng": -87.6868 },
  "rider": "reduced_access",
  "depart_at": null,
  "itineraries": [
    {
      "id": "3f1c0a9b2d7e",
      "duration_s": 1080, "start_time": "2026-10-16T01:32:00Z", "end_time": "2026-10-16T01:50:00Z", "transfers": 0,
      "cost": { "rider_cents": 110, "rider_formatted": "$1.10", "full_cents": 225, "full_formatted": "$2.25", "savings_cents": 115, "boardings": 1 },
      "legs": [
        { "mode": "walk", "route_short_name": null, "route_long_name": null, "headsign": null, "agency_name": null,
          "from": { "name": "START", "lat": 41.8807, "lng": -87.7262, "time": "2026-10-16T01:32:00Z" },
          "to": { "name": "Madison & Pulaski", "lat": 41.880623, "lng": -87.72583, "time": "2026-10-16T01:36:00Z" },
          "duration_s": 240, "route_color": null, "intermediate_stop_count": 0,
          "polyline": { "points": "wb}x}Wviyfhs@…", "precision": 7 } },
        { "mode": "bus", "route_short_name": "20", "route_long_name": "Madison", "headsign": "Michigan",
          "agency_name": "Chicago Transit Authority",
          "from": { "name": "Madison & Pulaski", "lat": 41.880623, "lng": -87.72583, "time": "2026-10-16T01:36:00Z" },
          "to": { "name": "Madison & Western", "lat": 41.881107, "lng": -87.68608, "time": "2026-10-16T01:47:00Z" },
          "duration_s": 660, "route_color": "414145", "intermediate_stop_count": 13,
          "polyline": { "points": "k|{x}Wvbrfhs@…", "precision": 7 } },
        { "mode": "walk", "…": "…" }
      ]
    }
  ],
  "fallback": {
    "apple": "maps://?daddr=41.8819%2C-87.6868&dirflg=r&saddr=41.8807%2C-87.7262",
    "google": "https://www.google.com/maps/dir/?api=1&destination=41.8819%2C-87.6868&travelmode=transit&origin=41.8807%2C-87.7262"
  }
}
```

When Transitous times out, errors, or returns an unexpected body, the response is
`502 {"error":{"code":"upstream_unavailable",...}, "origin", "destination", "rider", "fallback":{apple,google}}`
(`Cache-Control: no-store`) so clients can fall straight through to the Apple/Google deep links.

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
