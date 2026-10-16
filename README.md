<p align="center"><img src="docs/logo.png" width="140" alt="Farecart logo"></p>

# Farecart

**Find food. Get there for less.**

Farecart is a native iOS app for Chicagoans who need affordable food and a cheap way to reach it. Enter an address or use your location, see the nearest grocery stores, food pantries and free giveaways on a map, and get CTA directions with the exact fare you'd pay, including the half-price Access fare that SNAP households now qualify for and often don't know about.

Built for Chicago's West Side first, where the last full grocery store closed in July 2026, and now covering all 77 community areas.

<p align="center">
  <img src="docs/screenshots/find-food.png" width="180" alt="Find Food map with store logos">
  <img src="docs/screenshots/place-info.png" width="180" alt="Place info tab">
  <img src="docs/screenshots/place-directions.png" width="180" alt="CTA directions with trip cost">
  <img src="docs/screenshots/discounts.png" width="180" alt="Discounts receipt">
</p>
<p align="center">
  <img src="docs/screenshots/onboarding.png" width="180" alt="Onboarding language picker">
  <img src="docs/screenshots/settings.png" width="180" alt="Settings">
  <img src="docs/screenshots/find-food-dark.png" width="180" alt="Dark mode">
  <img src="docs/screenshots/find-food-arabic.png" width="180" alt="Arabic right-to-left layout">
</p>

## What it does

- **Find food nearby.** 820 locations across Chicago: 626 grocery stores that take Link/EBT (from the USDA SNAP retailer list), 190 food pantries and recurring giveaways. Sorted by distance, filtered by type, with hours, phone, what to bring, and store logos.
- **Directions by CTA, in the app.** Real bus and train itineraries drawn on the map with step-by-step instructions, three departure options, and the cost of the trip under CTA's transfer rules.
- **Know your discount.** Two yes/no questions tell you whether you qualify for the Access reduced fare (SNAP households, $1.10 bus instead of $2.25) or the student fare ($0.75), and how to sign up.
- **For everyone.** Nine languages with instant switching and right-to-left support, light and dark themes, Dynamic Type, VoiceOver labels, and no account required.

## How it works

```
iOS app (SwiftUI, iOS 26)
  ├─ Supabase (Postgres + PostGIS)   nearest-location query, fares, programs, profiles
  ├─ Transitous (MOTIS)              CTA transit routing, free, no key
  ├─ Apple MapKit                    map, geocoding, Apple place cards
  └─ Google favicon service          store logos
```

The app talks to Supabase directly over PostgREST. Fare prices and transfer rules live in the database, so a CTA fare change is a row update, not an app release.

### Trip cost

Cost of a trip equals the fare of the first boarding. Up to two more rides within two hours are free transfers. A fourth boarding, or one outside the window, starts a new fare. Walking-only trips cost nothing, and legs on Pace or Metra are flagged rather than guessed. The rule reads the `fares` table and is unit-tested for every rider type.

## Repository layout

| Path | What's there |
|---|---|
| `ios/` | The app. `Farecart/` is the SwiftUI target, `FarecartKit/` is a Foundation-only Swift package with models, fare math, routing client and tests. |
| `data/` | Location dataset: a hand-researched West Side CSV, a citywide CSV built from USDA, Plentiful and OpenStreetMap, and the idempotent seed script. |
| `supabase/migrations/` | Schema: PostGIS locations, fares, programs, profiles, and the `nearby_locations` function. |
| `api/` | Optional Hono API on Vercel mirroring the app's logic (nearby, geocode, fares, eligibility, transit route) for a future web client. Not required by the app. |
| `docs/` | Screenshots. |

## Getting started

### Requirements

- Xcode 26 or newer (iOS 26 SDK, Liquid Glass APIs)
- Node 24 for the data and API scripts
- A Supabase project (free tier is fine)

### Run the app

1. Clone the repo and open `ios/Farecart.xcodeproj`.
2. Put your Supabase URL and publishable key in `ios/Config/Debug.xcconfig`. The publishable key is safe to ship. Never put the service role key anywhere in `ios/`.
3. Choose a simulator or your iPhone, set your signing team, and press Run.

The Swift package tests run without Xcode:

```sh
ios/FarecartKit/test.sh
```

### Set up the database

```sh
# apply migrations in order to your Supabase project
for f in supabase/migrations/*.sql; do psql "$DATABASE_URL" -f "$f"; done

# seed locations (reads SUPABASE_URL and SUPABASE_SERVICE_ROLE_KEY from .env.local)
cd data && node seed.mjs
```

The seed is idempotent. It geocodes missing coordinates with the US Census geocoder, validates every point against the Chicago bounding box, checks store logos, and upserts on `(name, address)`.

### Optional API

```sh
cd api && npm install && npm run dev     # local server
npm test                                  # unit + smoke tests
```

See `api/README.md` for routes and deployment.

## Data and sources

| Source | Used for | License |
|---|---|---|
| Farecart team research | 44 West Side stores, pantries and giveaways, each with a source link | Project |
| USDA SNAP Retailer Locator | Citywide grocery stores that accept Link/EBT | Public domain |
| Plentiful, foodpantries.org | Food pantry listings and hours | Per site |
| OpenStreetMap | Pantries and store hours | ODbL, © OpenStreetMap contributors |
| Chicago Transit Authority | Fares and reduced fare programs | Public |
| Northern Illinois Transit Authority | Access reduced fare program | Public |
| Transitous | Transit routing | Community service, no SLA |

No listing is marked verified until a person confirms it by phone or visit. The app says so on every unverified place. Fare prices were checked against the official CTA fares page on October 15, 2026.

## Sign-in

Accounts are optional and only sync discount answers, language and theme between phones. Sign in with Apple and Google both go through Supabase Auth with no third-party SDK. Sign in with Apple needs a paid Apple Developer team; Google needs an OAuth web client whose redirect URI is `https://<project>.supabase.co/auth/v1/callback`. Setup steps are in `ios/README.md`.

## Roadmap

- Live CTA bus and train arrivals for each step
- Alerts when a pantry adds a giveaway
- Native-speaker review of the seven machine-assisted translations
- In-app account deletion
- Web client on the existing API

## Developer reference

<details>
<summary>Supabase schema and queries</summary>

- Tables: `locations`, `giveaway_events`, `fares`, `programs`, `profiles`. Row Level Security: public read on the first four, owner-only on `profiles`.
- `location_type` enum: `grocery | pantry | giveaway`. `source_kind`: `curated | usda_snap | osm | gcfd | plentiful | other`.
- `nearby_locations(p_lat, p_lng, p_types location_type[] default null, p_limit int default 25, p_radius_m int default 8000)` returns rows with `distance_m`, `source_kind`, `logo_url`.
- Example: `POST {SUPABASE_URL}/rest/v1/rpc/nearby_locations` with header `apikey: <publishable key>` and body `{"p_lat":41.8807,"p_lng":-87.7262}`.
- `fares` rows carry `price_cents`, `transfer_cents`, `transfer_window_min`, `max_transfers`, `signup_url`, `source_url`.

</details>

<details>
<summary>Transit routing contract</summary>

`GET https://api.transitous.org/api/v1/plan?fromPlace=LAT,LNG&toPlace=LAT,LNG&numItineraries=3` with a descriptive `User-Agent`. Itineraries contain legs with `mode` (WALK, BUS, SUBWAY, RAIL, TRAM), stops with times, `routeShortName`, `routeColor`, `agencyName`, and `legGeometry.points` as a Google-encoded polyline (precision 7, with a precision 5 fallback checked against the Chicago bounding box). CTA rail arrives as SUBWAY or RAIL with agency "Chicago Transit Authority". On any failure the app falls back to Apple Maps and Google Maps transit deep links.

</details>

<details>
<summary>Conventions</summary>

- Swift 6, SwiftUI only, strict concurrency, no third-party iOS dependencies. TypeScript strict, ESM, Node 24.
- Secrets only through `.env.local` and xcconfig files. Nothing secret is committed.
- Every location row must have a `source_url`. `verified_on` stays empty until a human confirms it.
- Fares, programs and transfer rules are data, never constants in code.

</details>

## License

Code is released under the MIT License. Data carries the licenses of its sources listed above.

## Pantry inventory and visit scheduling (contract, added 2026-10-15)

Goal: cut pantry lines and wait times. Pantries post what they have and open visit slots; people book a slot and see what's available before they travel.

### Tables (migration 0007, RLS public read; writes only through the functions below)
- `pantry_inventory (id, location_id → locations, category text check in ('produce','dairy','protein','canned','bread','baby','water','other'), level text check in ('plenty','low','out'), note text, reported_at timestamptz, expires_at timestamptz default reported_at + 24h, source text check in ('staff','feedam','demo'))` — one current row per (location_id, category); upsert replaces.
- `pantry_slots (id, location_id, starts_at, ends_at, capacity int, booked int default 0, notes text, created_by text)` — index on (location_id, starts_at). `remaining = capacity - booked`.
- `pantry_visits (id uuid, slot_id → pantry_slots, location_id, device_id text, user_id uuid null, party_size int default 1, status text check in ('booked','cancelled','arrived') default 'booked', confirmation_code text (6 chars, unique), cancel_token uuid, created_at)` — NO public select; readers use `my_visits(p_device_id)`.
- `pantry_staff_codes (location_id primary key, code text unique, contact_name, contact_phone, created_at)` — never readable by anon; validated only inside functions.
- `locations` gets `pantry_model text check in ('client_choice','pre_packed','both', null)`, `requires_snap bool default false`, `requires_id bool null`, `feedam_id int null`.

### Functions (SECURITY DEFINER, callable by anon via PostgREST RPC)
- `pantry_availability(p_location_id uuid)` → inventory rows not expired + next 14 days of slots with `remaining`, + `staff_updated_at`.
- `book_visit(p_slot_id uuid, p_device_id text, p_party_size int default 1, p_user_id uuid default null)` → `{visit_id, confirmation_code, cancel_token, starts_at, ends_at, location_name, address}`; fails with `slot_full`, `slot_past`, `already_booked` (same device + slot). Increments `booked` atomically (row lock).
- `cancel_visit(p_visit_id uuid, p_cancel_token uuid)` → decrements `booked`, sets cancelled.
- `my_visits(p_device_id text)` → upcoming + past 30 days with location name/address/lat/lng, slot times, status, code, cancel_token.
- Staff: `staff_login(p_code text)` → `{location_id, name, address}` or error `bad_code`; `staff_set_inventory(p_code, p_category, p_level, p_note)`; `staff_upsert_slot(p_code, p_slot_id null, p_starts_at, p_ends_at, p_capacity, p_notes)`; `staff_delete_slot(p_code, p_slot_id)`; `staff_bookings(p_code, p_day date)` → visits for that day (party_size, status, code, created_at); `staff_mark_arrived(p_code, p_visit_id)`.
All staff functions re-validate `p_code` against `pantry_staff_codes`.

### Client rules
- Device id: a UUID generated once and kept in Keychain; sent as `p_device_id`. If signed in, also pass `p_user_id`.
- Show inventory as chips with level colour (plenty green, low amber, out grey) and "reported Xh ago"; hide expired rows; never call it guaranteed.
- Pantry rows/detail show "Most pantries don't require SNAP or ID" unless `requires_snap`/`requires_id` say otherwise.
- Feed America (feedam.org, CC BY 4.0, attribution "Directory published by Feed America (feedam.org)"): `GET https://feedam.org/api/resources/{id}/status` for pantries with `feedam_id`; merge non-null status as `source='feedam'` rows on read (client-side, cached 10 min). Rate limit 10k/day/IP.
- Demo data: slots + inventory for ~12 West Side curated pantries, `source='demo'`, staff codes seeded (listed in data/README.md, demo only).
