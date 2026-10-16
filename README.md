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
