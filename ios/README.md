# Farecart iOS

**Find food. Get there for less.**

Native SwiftUI app (iOS 26, Liquid Glass) that finds grocery stores, food pantries and giveaways near
an address on Chicago's West Side, opens CTA transit directions, and shows the cheapest fare the user
qualifies for (Access reduced fare for SNAP households, Student fare for K–12).

```
ios/
├── project.yml               XcodeGen spec → Farecart.xcodeproj
├── Config/
│   ├── Debug.xcconfig        SUPABASE_URL, SUPABASE_ANON_KEY, API_BASE_URL, REPORT_PROBLEM_EMAIL
│   └── Release.xcconfig
├── Farecart/                 App target (SwiftUI only, no third-party deps)
│   ├── App/                  FarecartApp, RootTabView (iOS 26 Tab API), AppEnvironment
│   ├── Services/             LocationService, AppleGeocoder, Directions, FareStore
│   ├── Features/
│   │   ├── FindFood/         Map + glass filter chips + results sheet + search tab
│   │   ├── PlaceDetail/      Hero card, facts, CTA / Google Maps buttons, fare line
│   │   ├── Discounts/        Two yes/no questions → program card
│   │   └── About/            Credits, privacy, report a problem
│   ├── Shared/               Badges, pins, banners, type colors
│   └── Resources/            Assets.xcassets, Localizable.xcstrings (en + es), PrivacyInfo.xcprivacy
└── FarecartKit/              Swift package, Foundation only (builds + tests on macOS)
    ├── Sources/FarecartKit/
    │   ├── Models/           Place, Fare, Program, LocationType, GeoPoint, GeocodeResult
    │   ├── Logic/            Eligibility, FareCalculator, OpeningHours, Distance, DirectionsLinks, AppConfig
    │   ├── Networking/       SupabaseClient (PostgREST), RemoteGeocoder, HTTPTransport
    │   └── Data/             FoodDataProviding, MockDataProvider, BundledFallbacks
    └── Tests/FarecartKitTests/
```

## Open in Xcode 26

1. Install XcodeGen once: `brew install xcodegen`
2. Generate the project (already committed, but regenerate after editing `project.yml` or adding files):
   ```sh
   cd ios && xcodegen generate
   ```
3. `open ios/Farecart.xcodeproj`
4. Select the **Farecart** target → *Signing & Capabilities* → pick your **Team**. (Or set
   `DEVELOPMENT_TEAM` in `project.yml` and regenerate.) Bundle id is `org.farecart.app`; change it if
   your team already uses it.
5. Pick an iPhone simulator running iOS 26 (or a device on iOS 26) and press **Run**.

On first launch the map shows the West Side. Tap the location button (asks for *when in use*
permission) or the Search tab to type an address.

## Configuration

`Config/Debug.xcconfig` / `Release.xcconfig` are copied into Info.plist at build time and read by
`AppConfig` at launch:

| Key | Value |
| --- | --- |
| `SUPABASE_URL` | `https://mwirkxfqbomaaoygyfgm.supabase.co` (written as `https:/$()/…` because `//` starts a comment in xcconfig) |
| `SUPABASE_ANON_KEY` | the **publishable/anon** key from `.env.local`. Safe to ship. **Never** put the service role key in `ios/`. |
| `API_BASE_URL` | optional. When set, address lookups call `GET {API_BASE_URL}/geocode?q=…` first and fall back to Apple's MapKit geocoder. Leave empty and the app works standalone. |
| `REPORT_PROBLEM_EMAIL` | address used by "Report a problem with a listing". |

`RemoteGeocoder` accepts `{"lat","lng","label"}`, `{"latitude","longitude","formatted"}`, or any of
those wrapped in `{"results":[…]}`.

Data access goes straight to Supabase PostgREST with `URLSession`:

- `POST rest/v1/rpc/nearby_locations` → `[Place]` (with `distance_m`)
- `GET rest/v1/fares` → `[Fare]`
- `GET rest/v1/programs` → `[Program]`

When `fares`/`programs` cannot be loaded the app shows `BundledFallbacks` (a copy of the seed) and
labels prices "last known".

## FarecartKit tests (no Xcode needed)

```sh
cd ios/FarecartKit
./test.sh          # or: swift test   (inside Xcode / full toolchain)
```

`test.sh` adds `-plugin-path` for the Swift Testing macros, which the Command Line Tools install
outside the default search path. In Xcode, ⌘U on the Farecart scheme runs the same tests.

## Localization

All user-facing strings live in `Farecart/Resources/Localizable.xcstrings` with English keys and
Spanish translations. Text coming from the database (place names, hours, program descriptions) is shown
as stored.

## Previews

Every screen has a `#Preview` using `AppEnvironment.preview()` → `MockDataProvider` with five
fictional West Side listings, so previews work before the `locations` table is seeded.
