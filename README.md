# Farecart — Find food. Get there for less. (West Side Chicago)

Monorepo:
- `supabase/migrations/` — Postgres + PostGIS schema (already applied to the live project)
- `api/` — Hono on Vercel Functions (TypeScript). Thin API over Supabase + Census geocoder + CTA proxy
- `ios/` — native SwiftUI app, iOS 26, Liquid Glass design
- `data/` — hand-researched locations CSV + seed script

## Live Supabase project
- Ref: `mwirkxfqbomaaoygyfgm`, URL: `https://mwirkxfqbomaaoygyfgm.supabase.co`
- Keys live in `.env.local` (gitignored): `SUPABASE_URL`, `SUPABASE_ANON_KEY` (publishable, safe in clients), `SUPABASE_SERVICE_ROLE_KEY` (server only, never ship in the app)
- Tables: `locations`, `giveaway_events`, `fares`, `programs`. RLS: public read, service role write.
- RPC: `nearby_locations(p_lat, p_lng, p_types location_type[] default null, p_limit int default 25, p_radius_m int default 8000)` returns rows with `distance_m`.
- `location_type` enum: `grocery | pantry | giveaway`
- Example: `POST {SUPABASE_URL}/rest/v1/rpc/nearby_locations` header `apikey: <anon>` body `{"p_lat":41.8807,"p_lng":-87.7262}`

## Product (keep it dead simple, no login)
1. Enter an address / neighborhood, or use current location.
2. Map + list of nearest grocery stores, pantries, giveaways with distance, hours, EBT/requirements.
3. Each place: "Directions by CTA" button → Apple Maps transit (`maps://?daddr=lat,lng&dirflg=r`) and Google Maps transit (`https://www.google.com/maps/dir/?api=1&destination=lat,lng&travelmode=transit`). Show estimated fare: full vs the discount the user qualifies for.
4. Discounts: two questions — "Does anyone in your household get SNAP?" and "Are you a K–12 student?" → which program, price, and a Sign up link. Data comes from `programs` + `fares` tables.

## Fare facts (Oct 2026, in `fares` table — read from data, never hardcode)
- CTA full: bus $2.25, train $2.50
- Access reduced (SNAP households, starts Oct 1 2026): bus $1.10, train $1.25 — apply at https://getaccess.org
- Student (K–12, school days): $0.75 — Ventra Student Card

## Conventions
- TypeScript strict, ESM, Node 24. Swift 6, SwiftUI only, no third-party iOS deps unless essential.
- Secrets only via env / xcconfig; nothing secret committed.
- Every location row must carry `source_url`; `verified_on` stays NULL until a human confirms by phone or visit.
