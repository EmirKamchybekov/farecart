# Farecart developer notes

Technical reference for contributors. The project overview is in the [README](../README.md).

## Supabase schema and queries

- Tables: `locations`, `giveaway_events`, `fares`, `programs`, `profiles`. Row Level Security: public read on the first four, owner-only on `profiles`.
- `location_type` enum: `grocery | pantry | giveaway`. `source_kind`: `curated | usda_snap | osm | gcfd | plentiful | other`.
- `nearby_locations(p_lat, p_lng, p_types location_type[] default null, p_limit int default 25, p_radius_m int default 8000)` returns rows with `distance_m`, `source_kind`, `logo_url`.
- Example: `POST {SUPABASE_URL}/rest/v1/rpc/nearby_locations` with header `apikey: <publishable key>` and body `{"p_lat":41.8807,"p_lng":-87.7262}`.
- `fares` rows carry `price_cents`, `transfer_cents`, `transfer_window_min`, `max_transfers`, `signup_url`, `source_url`.

## Transit routing

`GET https://api.transitous.org/api/v1/plan?fromPlace=LAT,LNG&toPlace=LAT,LNG&numItineraries=3` with a descriptive `User-Agent`. Itineraries contain legs with `mode` (WALK, BUS, SUBWAY, RAIL, TRAM), stops with times, `routeShortName`, `routeColor`, `agencyName`, and `legGeometry.points` as a Google-encoded polyline (precision 7, with a precision 5 fallback checked against the Chicago bounding box). CTA rail arrives as SUBWAY or RAIL with agency "Chicago Transit Authority". On any failure the app falls back to Apple Maps and Google Maps transit deep links.

## Conventions

- Swift 6, SwiftUI only, strict concurrency, no third-party iOS dependencies. TypeScript strict, ESM, Node 24.
- Secrets only through `.env.local` and xcconfig files. Nothing secret is committed.
- Every location row must have a `source_url`. `verified_on` stays empty until a human confirms it.
- Fares, programs and transfer rules are data, never constants in code.

## Pantry inventory and visit scheduling

Goal: cut pantry lines and wait times. Pantries post what they have and open visit slots; people book a slot and see what's available before they travel.

### Tables
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
