# FreshRoute data: West Side food locations

Hand-researched (web, Oct 2026) list of places on Chicago's West Side where a
West Garfield Park family can get food, plus the script that loads it into
Supabase. **Nothing here has been phone-verified yet** — `verified_on` is blank
on every row on purpose. See the checklist at the bottom.

## Files

| File | What |
|---|---|
| `locations.csv` | Source of truth. 44 rows: 15 `grocery`, 25 `pantry`, 4 `giveaway`. Columns: `name,type,address,neighborhood,lat,lng,hours_text,accepts_ebt,requirements,languages,phone,website,source_url,notes`. `languages` is `;`-separated. |
| `giveaway_events.csv` | Dated one-off events linked to a location by exact `location_name`. Columns: `location_name,title,starts_at,ends_at,details,source_url` (ISO 8601 with offset). |
| `seed.mjs` | Reads both CSVs, geocodes any row missing `lat`/`lng`, writes the coordinates back into `locations.csv`, validates, and upserts into Supabase via PostgREST. |
| `0002_locations_unique.sql` | Adds `unique (name, address)` on `locations` and `unique (location_id, title, starts_at)` on `giveaway_events` so the upsert is idempotent. Same file lives in `../supabase/migrations/`. Already applied to the live project. |

## Coverage

West Garfield Park, East Garfield Park, Austin, North Lawndale, Humboldt Park,
Near West Side, plus Oak Park (Green Line / #20 Madison), Little Village
(Pink Line / #52 Kedzie / #53 Pulaski), West Town (#66 Chicago / #70 Division)
and Cicero (Pink Line Cicero / #54 Cicero). Every row's `notes` names the
nearest CTA rail stop or bus.

Deliberately excluded (closed): ALDI 3835 W Madison St; Save A Lot at Pulaski &
Congress (420 S Pulaski Rd); Walmart Neighborhood Market 2551 W Cermak Rd (now a
Tony's). Not included because no open-status or schedule could be confirmed:
Leamington Foods (5467 W Madison), Food Market La Chiquita, New Mount Pilgrim MBC
pantry, Garfield Park Rite to Wellness distributions, GCFD Producemobile stops,
Rush "Food is Medicine" (referral only), Top Box Foods (no West Side pickup).

## Sources used

- Chain store locators: [petesfresh.com/stores](https://www.petesfresh.com/stores),
  [local.jewelosco.com](https://local.jewelosco.com/il/chicago.html),
  [cermakfreshmarket.com/locations](https://www.cermakfreshmarket.com/locations),
  [locations.tonysfreshmarket.com](https://locations.tonysfreshmarket.com/),
  [marianos.com](https://www.marianos.com/), [fortyacresfreshmarket.com](https://www.fortyacresfreshmarket.com/grocery-store/).
  ALDI, Food 4 Less and Walmart locators block automated fetching, so those three
  rows cite third-party listings and are flagged `UNSURE` in `notes`.
- Pantries: Greater Chicago Food Depository partner list as reproduced by
  [Borderless Magazine's free-food guide](https://borderlessmag.org/2025/11/24/chicago-free-food-pantry-groceries-hot-meals-cook-county-snap-inflation/)
  (published 2025-11-24, updated 2026-01-28; chicagosfoodbank.org itself returns
  403 to scripts), GCFD's Vivery listing pages (`sites.vivery.com/...`),
  [Plentiful directory](https://directory.plentiful.org/illinois/chicago),
  [Catholic Charities food pantries](https://www.catholiccharities.net/get-help/program/food-pantries/),
  and the pantries' own sites (Chicago Public Library, Breakthrough, Marillac,
  A Safe Haven, Nourishing Hope, Beyond Hunger, Mission OLA).
- Giveaways: [YMCA of Metro Chicago](https://ymcachicago.org/news-events/transforming-lives,-one-meal-at-a-time),
  Catholic Charities, [The Love Fridge](https://www.thelovefridge.com/find-a-fridge).
- Geocoding: US Census Geocoder (`geocoding.geo.census.gov`, benchmark
  `Public_AR_Current`), fallback Nominatim with a User-Agent. All 44 rows
  resolved via Census. The script rejects any match outside lat 41.64–42.03 /
  lng -87.95 to -87.52 or whose street number/name disagree with the address.

## Re-running

```sh
# from repo root; needs SUPABASE_URL and SUPABASE_SERVICE_ROLE_KEY in ../.env.local
node data/seed.mjs             # geocode missing coords, write back, upsert
node data/seed.mjs --dry-run   # geocode + validate only, no DB writes
node data/seed.mjs --no-geocode
```

Idempotent: re-running updates rows in place (`Prefer: resolution=merge-duplicates`
on `(name, address)`). Renaming a place or changing its address creates a new
row; deactivate the old one in the DB (`is_active = false`) rather than deleting
so history is kept. To add a place: append a row with `lat,lng` blank and a real
`source_url`, run the script, and commit the CSV with the coordinates it wrote.

Quick check after seeding (Madison & Pulaski):

```sh
curl -s -X POST "$SUPABASE_URL/rest/v1/rpc/nearby_locations" \
  -H "apikey: $SUPABASE_ANON_KEY" -H "Content-Type: application/json" \
  -d '{"p_lat":41.8807,"p_lng":-87.7262}'
```

## Human verification checklist

For each row, call the number in `phone` (or visit) and confirm. Then fill
`verified_on` (YYYY-MM-DD) and `verified_by` in the database — the CSV
intentionally has no `verified_on` column, so verification lives in Supabase.

1. Still open / still running the program?
2. Hours exactly as in `hours_text` (ask about holiday weeks).
3. Pantries: ID / proof of address / zip restrictions / how often you can come /
   appointment needed / what to bring (bags, cart).
4. Groceries: Link/EBT accepted at the register? WIC?
5. Languages spoken at the counter.
6. Correct entrance (several church pantries use a side or basement door).
7. Anything to fix in `notes`.

Rows most in need of a call (flagged `UNSURE` in `notes`):

- ALDI 5629 W Fillmore, Food 4 Less 4821 W North, Walmart 4650 W North — hours from third-party listings.
- Pete's Fresh Market (all three) — official page lists addresses but no hours/phones.
- Forty Acres Fresh Market — EBT acceptance not stated on its site.
- Greater Holy Temple COGIC — two sources disagree on Friday hours.
- United for Better Living, Greater Garfield MBC, Healing Temple, LeMoyne Street, William V. Banks (no phone found) — single-source hours.
- Pan de Vida — 2701 vs 2657 S Lawndale.
- El Mercadito — languages inferred, not sourced.
- McCormick YMCA mobile pantry — schedule from search snippets only.
- Blessed Maria Gabriella — Catholic Charities page shows two time blocks.

Useful numbers: Greater Chicago Food Depository 773-247-3663; Catholic Charities
312-655-7700; Chicago DFSS / 311 for city resources.
