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
│   ├── App/                  FarecartApp (locale / theme at the root), RootView (onboarding gate) + RootTabView,
│   │                         AppEnvironment, AppSettings (AppLanguage, AppTheme, LanguageBundle)
│   ├── Services/             LocationService, AppleGeocoder, Directions, FareStore, AccountModel (email + password,
│   │                         Google via hosted OAuth, Sign in with Apple, profile sync, visit claiming, deletion),
│   │                         Keychain, PantryStore, CalendarExport
│   ├── Features/
│   │   ├── Splash/           Animated launch splash (SplashView, ChicagoSkyline), shown once per cold launch
│   │   ├── Onboarding/       Welcome (language) → account → role → client or staff pages → look
│   │   ├── Account/          Sign-in buttons, email sign-up / sign-in sheets, new password, Delete account
│   │   ├── FindFood/         Top search field + suggestions, glass filter chips, map, in-tab results panel
│   │   ├── PlaceDetail/      Compact hero, then Info (address, hours, what to bring) | Directions tabs
│   │   ├── Route/            In-app CTA directions: RouteModel + RouteContent (cost hero, map, steps)
│   │   ├── Pantry/           What's available, Schedule a visit, booking sheet, confirmation, Your visits;
│   │   │   └── Staff/        pantry staff mode (code entry, stock grid, slots, today's bookings)
│   │   ├── Discounts/        Two yes/no questions → program card
│   │   └── Settings/         Account, language, appearance, welcome again, data sources, privacy, help
│   ├── Shared/               Design tokens (spacing / radii / card), badges, pins, banners, type colors
│   ├── Farecart.entitlements Sign in with Apple
│   └── Resources/            Assets.xcassets, Localizable.xcstrings (9 languages), PrivacyInfo.xcprivacy
└── FarecartKit/              Swift package, Foundation only (builds + tests on macOS)
    ├── Sources/FarecartKit/
    │   ├── Models/           Place, Fare, Program, LocationType, GeoPoint, GeocodeResult, AuthSession, Profile
    │   ├── Logic/            Eligibility, FareCalculator, OpeningHours, Distance, DirectionsLinks, AppConfig
    │   ├── Networking/       SupabaseClient (PostgREST + profiles), SupabaseAuthClient (GoTrue), RemoteGeocoder
    │   ├── Pantry/           PantryModels, PantryError, PantryService (+ SupabaseClient RPCs), MockPantryService,
    │   │                     FeedAmericaClient, DeviceID / SecureStore
    │   └── Data/             FoodDataProviding, MockDataProvider, BundledFallbacks
    └── Tests/FarecartKitTests/
```

## Screens

- **Splash** (cold launch only): the static launch screen (`UILaunchScreen` in `project.yml`: the
  `SplashBackground` brand green #32AA59 plus the 120 pt `LaunchLogo` image set, identical in dark mode) is also
  the first frame of `SplashView`, which then animates for about 1.6 s on top of the root while the main UI
  loads underneath: a Chicago skyline (`ChicagoSkyline`, one `Shape` in unit coordinates: Willis, Trump,
  Aon, Two Prudential, Hancock) rises in, a transit line with its stop dot sweeps along its base, the logo
  springs up 12 pt, the tagline fades in, then the whole thing fades and scales out. With Reduce Motion the
  final frame is shown still for 0.8 s and cross-fades. Debug launch arguments: `-farecart-splash-hold`
  freezes the finished frame for screenshots, `-farecart-splash-slow` plays it at quarter speed.
- **Onboarding** (first launch, `@AppStorage("onboardingDone")`): six full-screen pages on either path, with a
  page indicator and Skip:
  1. Welcome + language list → *Continue*.
  2. **Create your account**: *Continue with Google*, *Sign in with Apple*, *Sign up with email* (sheet: Name,
     Email, Password with show/hide and "At least 8 characters.", *Create account*) and *I already have an
     account* (sheet: Email, Password, *Sign in*, *Forgot password?*); small *Continue as guest* below. Already
     signed in: "Signed in as …" and *Continue*.
  3. **How will you use Farecart?**: *I'm looking for food* or *I work at a pantry* (`@AppStorage("userRole")`,
     `client` / `staff`); tapping a card moves on, *Continue* also works once chosen.
  4. Looking for food: **Find food near you** (*Allow location* / *Type an address instead*), then **Ride for
     less?** (the two discount questions with the "You could pay $1.10 instead of $2.25" payoff) → *Continue*.
     Pantry staff: **Enter your pantry's staff code** (validated with `staff_login`; on success "You're set up
     for <pantry>", *Continue*; or *Skip for now*), then **Find food near you**.
  5. **Choose your look**: System / Light / Dark as three map-preview tiles, applied live → *Start using Farecart*.
  A staff user with a staff session starts each launch on Settings → staff screen. Settings → "Show welcome
  again" re-runs it.
- **Find Food**: a glass search field sits on top of the map. Idle, it shows the current origin ("My location"
  or the chosen address); tapping it clears the field, shows "Use my location" + neighborhood shortcuts, and
  as you type, geocoder matches drop down over the map. Choosing one re-centers and reloads. Filter chips sit
  under the field; the draggable results panel is unchanged. If location was already allowed (onboarding), the
  first search starts from the phone's location, otherwise from the West Side.
- **Place detail**: Info and Directions tabs. Each tab's actions ("Directions by CTA"; "Open in Apple Maps" plus
  the Google Maps globe) float 16 pt above the bottom safe area as Liquid Glass controls (`floatingBottomBar`
  in `Shared/Design.swift`: a `GlassEffectContainer` overlay plus a matching bottom content margin), with the
  content scrolling underneath and the footer still readable at the end.
- **Pantry detail** (Info tab, `type == pantry`): a **What's available** card (one chip per posted stock
  category, plenty green / low amber / out grey, the staff note, "Reported 2 hr. ago"; empty state "This pantry
  hasn't posted today's stock. Call ahead." with the phone number; never says guaranteed), the requirements
  line ("Most pantries don't require SNAP or ID." or the listing's `requires_snap` / `requires_id` values) and
  the pantry model ("Client choice: you pick your own items" / "Pre-packed boxes") under *What to bring*, and a
  **Schedule a visit** card: a horizontal day picker, slot chips ("1:00 PM · 13 spots left", disabled when
  full), a booking sheet (party size 1–6, Confirm) and the confirmation screen (big code, when, where, Add to
  Calendar via EventKit write-only access, Directions by CTA → the Directions tab, Cancel visit). With no
  slots: "Walk-ins welcome during open hours" + phone. A pantry you already booked shows a "You're booked" row
  above the picker. Results rows show a small "Book a visit" pill once that pantry's availability has been
  loaded (opening its detail); the list itself makes no extra calls.
- **Your visits**: the next booked visit sits at the top of Find Food's results panel and of Settings (name,
  time, code; tap for the confirmation screen with Directions by CTA). Settings → *Your visits* lists upcoming
  and past/cancelled visits with swipe-to-cancel.
- **Pantry staff mode**: Settings → *I work at a pantry* → 6-character staff code → a screen titled with the
  pantry's name: **Today's stock** grid (tap a tile to cycle plenty → low → out; saved immediately, "Saved"
  flashes; one column at accessibility text sizes), **Visit slots · next 7 days** (delete, "Add a slot": day,
  start, 30/60 min, capacity), **Today's bookings** (time, party size, code, *Arrived* button) and *Sign out of
  staff mode*. The code is kept in the Keychain; every staff call re-validates it server-side.
- **Discounts**: unchanged; the answers are shared with onboarding through `DiscountsKeys`.
- **Settings**: Your visits, Account (signed out: the same buttons as onboarding; signed in: "Signed in as …",
  email, "Signed in with Google / Apple / email", Sign out, Delete account), Pantry staff (+ *Switch to pantry
  staff* / *Switch to looking for food*),
  Language, Appearance (System / Light / Dark), Show welcome again, then the former About content (data
  sources incl. Feed America, privacy, help, version).

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

On first launch the welcome screens run (see Screens). Afterwards the map starts from your location when
allowed, otherwise the West Side; use the search field on top of the map to type an address.

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

### Pantry inventory and visit scheduling

Contract: root `README.md`, "Pantry inventory and visit scheduling" (migration 0007). `PantryService`
(FarecartKit, `Pantry/PantryService.swift`) wraps the ten SECURITY DEFINER functions as `POST rest/v1/rpc/…`:

| Method | RPC |
| --- | --- |
| `availability(locationID:)` | `pantry_availability` → `PantryAvailability` (current inventory, next 14 days of slots with `remaining`, `staff_updated_at`) |
| `bookVisit(slotID:deviceID:partySize:userID:accessToken:)` | `book_visit` → `PantryVisit` (code, cancel token, times, pantry) |
| `cancelVisit(visitID:cancelToken:accessToken:)` | `cancel_visit` |
| `myVisits(deviceID:accessToken:)` | `my_visits` → `[PantryVisit]` |
| `accountVisits(accessToken:)` | `my_account_visits` (migration 0009, signed in only) |
| `claimDeviceVisits(deviceID:accessToken:)` | `claim_device_visits` → number claimed |
| `staffLogin(code:)` | `staff_login` → `StaffSession` (the code is kept client-side) |
| `staffSetInventory` / `staffUpsertSlot` / `staffDeleteSlot` / `staffBookings` / `staffMarkArrived` | the matching `staff_*` functions |

Every method throws `PantryError`: PostgREST's `{"code":"P0001","message":"slot_full"}` becomes
`.slotFull`, `.slotPast`, `.alreadyBooked`, `.badCode`, `.slotNotFound`, `.visitNotFound`, `.alreadyArrived`,
`.visitCancelled`, `.capacityBelowBooked`, `.badTimes`; other messages are `.server(message)`; transport and
decoding failures are `.network`. `PantryError.userMessage` (app) has the localized copy. Timestamps are
parsed by `PostgresTimestamp` (every spelling PostgREST and Postgres use, six fractional digits, `+00`) and sent
as `yyyy-MM-ddTHH:mm:ssZ`. Decoding is tolerant: a row with an unknown category or a malformed slot is dropped,
not the whole payload (`Lossy<T>`).

- **Device id**: `DeviceID.current(store:)` generates a UUID once and keeps it in the Keychain through the
  `SecureStore` protocol (`Keychain` conforms; `InMemorySecureStore` for tests/previews). It is sent as
  `p_device_id`. Signed in, `PantryStore.accessTokenProvider` (installed by `AccountModel`) adds the user's JWT
  as `Authorization: Bearer`, so `book_visit` stamps `user_id` from `auth.uid()`. After every sign-in
  `accountDidChange()` claims this phone's guest visits, and the list becomes `my_visits` + `my_account_visits`
  merged by id (`VisitMerge`); sign-out and deletion reload it as device-only.
- **Feed America**: `FeedAmericaClient` (actor) fetches `GET https://feedam.org/api/resources/{feedam_id}/status`
  with `User-Agent: Farecart/0.1 (hello@farecart.org)`, caches each id for 10 minutes and never throws. Today the
  endpoint returns `hours_status`, `confidence`, `days_since_verified`, `phone_*` (no stock); the decoder also
  accepts inventory-like arrays or flat `{"produce":"low"}` objects and turns them into `source == "feedam"` rows.
  `PantryAvailability.merging(feedAmerica:)` adds those rows only for categories the staff have not posted.
- **`Place`** gained `pantryModel` (`client_choice` / `pre_packed` / `both`, unknown → `nil`), `requiresSNAP`
  (default `false`), `requiresID` (`nil` = unknown) and `feedamID`, all tolerant of missing or null columns.
- **App side**: `PantryStore` (`AppEnvironment.pantry`) caches availability per place for the session (so the
  results pill costs nothing), keeps this phone's visits (`my_visits` once per launch, survives the view that
  started it), and persists the `StaffSession` in the Keychain. `MockPantryService` (demo slots and stock for
  the two mock pantries, staff codes `DEMO01` / `DEMO02`) backs previews and tests.
- **Calendar**: `CalendarExport.add` asks for write-only calendar access
  (`NSCalendarsWriteOnlyAccessUsageDescription`) and saves a one-hour-alarm event with the code in its notes.

Demo data: ~12 curated West Side pantries have slots and inventory (`source = demo`); their staff codes are in
`data/demo_staff_codes.csv` (demo only).

## FarecartKit tests (no Xcode needed)

```sh
cd ios/FarecartKit
./test.sh          # or: swift test   (inside Xcode / full toolchain)
```

`test.sh` adds `-plugin-path` for the Swift Testing macros, which the Command Line Tools install
outside the default search path. In Xcode, ⌘U on the Farecart scheme runs the same tests.

## In-app transit routing

The **Directions** tab of a place embeds `RouteContent` (loaded the first time the tab is shown): `TransitRouter` asks Transitous
(`GET /api/v1/plan`, see the root README) for up to three itineraries from the Find Food origin to the
place, and `TripFareCalculator` prices each one from the `fares` rows (`price_cents`, `transfer_cents`,
`transfer_window_min`, `max_transfers`) for the rider's best program. Non-CTA legs (Pace, Metra) are
flagged "fare not included". If Transitous fails or finds nothing the screen falls back to the
"Open in Apple Maps" / "Open in Google Maps" buttons.

Debug builds accept a launch argument that opens the route screen directly
(Madison & Pulaski → Pete's Fresh Market, Madison & Western), handy for screenshots:

```sh
xcrun simctl launch <udid> org.farecart.app -farecart-open-route            # full fare
xcrun simctl launch <udid> org.farecart.app -farecart-open-route -answers.householdSNAP 1   # Access price
xcrun simctl launch <udid> org.farecart.app -farecart-open-route -farecart-scroll-steps     # step list
```

The place screen can be opened the same way (first result after "Use my location"; `-far` picks the
first result over a mile away so the Directions tab has a bus to show; `-farecart-tab discounts|settings`
starts on that tab). Any `-farecart-…` argument skips onboarding unless it is `-farecart-reset-onboarding`:

```sh
xcrun simctl launch <udid> org.farecart.app -farecart-use-location -farecart-open-place
xcrun simctl launch <udid> org.farecart.app -farecart-use-location -farecart-open-place-far -farecart-open-place-directions
xcrun simctl launch <udid> org.farecart.app -farecart-tab discounts -answers.householdSNAP 1 -answers.hasAnswered 1
xcrun simctl launch <udid> org.farecart.app -farecart-tab settings
xcrun simctl launch <udid> org.farecart.app -farecart-search "Austin"                 # search field focused, suggestions showing
xcrun simctl launch <udid> org.farecart.app -farecart-reset-onboarding                 # welcome screens again
xcrun simctl launch <udid> org.farecart.app -farecart-reset-onboarding -farecart-onboarding-page 2   # pages 0–5
xcrun simctl launch <udid> org.farecart.app -farecart-reset-onboarding -farecart-onboarding-page 3 -farecart-role staff -farecart-staff-sign-out -farecart-onboarding-staff-code A7GBQZ
xcrun simctl launch <udid> org.farecart.app -farecart-reset-onboarding -farecart-onboarding-page 1 -farecart-sign-out -farecart-open-signup -farecart-auth-name "Maria Lopez" -farecart-auth-email you@example.com -farecart-auth-password secret-123 -farecart-auth-submit   # real sign-up
xcrun simctl launch <udid> org.farecart.app -farecart-tab settings -farecart-open-signin -farecart-auth-email you@example.com -farecart-auth-password secret-123 -farecart-auth-submit
xcrun simctl launch <udid> org.farecart.app -farecart-tab settings -farecart-open-delete-account    # add -farecart-confirm-delete-account to delete for real
xcrun simctl launch <udid> org.farecart.app -farecart-tab settings -farecart-language ar -farecart-theme dark
xcrun simctl launch <udid> org.farecart.app -farecart-splash-hold                      # splash frozen at its final frame
xcrun simctl launch <udid> org.farecart.app -farecart-splash-slow                      # splash at quarter speed
```

Pantry screens (set the simulator near the West Side first: `xcrun simctl location <udid> set 41.8807,-87.7262`):

```sh
xcrun simctl launch <udid> org.farecart.app -farecart-use-location -farecart-open-place-named "Legler"                           # pantry Info tab
xcrun simctl launch <udid> org.farecart.app -farecart-use-location -farecart-open-place-named "Legler" -farecart-scroll-bottom    # Schedule a visit card
xcrun simctl launch <udid> org.farecart.app -farecart-use-location -farecart-open-place-named "Legler" -farecart-open-booking     # booking sheet on the first open slot
xcrun simctl launch <udid> org.farecart.app -farecart-use-location -farecart-open-place-named "Legler" -farecart-book-first-slot  # …and confirms it (books for real)
xcrun simctl launch <udid> org.farecart.app -farecart-tab settings -farecart-open-visits                                          # Your visits
xcrun simctl launch <udid> org.farecart.app -farecart-tab settings -farecart-open-visits -farecart-cancel-first-visit             # …and cancels the next one
xcrun simctl launch <udid> org.farecart.app -farecart-tab settings -farecart-staff-code A7GBQZ                                    # staff mode (code from data/demo_staff_codes.csv)
xcrun simctl launch <udid> org.farecart.app -farecart-tab settings -farecart-open-staff -farecart-staff-cycle produce             # tap the Produce tile once
xcrun simctl launch <udid> org.farecart.app -farecart-tab settings -farecart-open-staff -farecart-staff-add-slot                  # Add a slot form
xcrun simctl launch <udid> org.farecart.app -farecart-tab settings -farecart-open-staff -farecart-staff-arrive-first              # tap Arrived on the first booking
xcrun simctl launch <udid> org.farecart.app -farecart-tab settings -farecart-open-staff -farecart-staff-scroll-bottom             # slots + bookings sections
```

`-farecart-open-staff` reuses the staff session kept in the Keychain; `-farecart-staff-code` signs in first.

`-farecart-language <code>` (`system`, `en`, `es`, `pl`, `zh-Hans`, `ar`, `fil`, `ur`, `uk`, `ko`) and
`-farecart-theme <system|light|dark>` write the Settings values, so pass `system` afterwards to reset.
`xcrun simctl privacy <udid> grant location org.farecart.app` pre-answers the location prompt.

`Tests/FarecartKitTests/Fixtures/transitous_plan.json` is a real `/plan` response captured on
2026-10-15 and drives the decoding tests.

## Localization

All user-facing strings live in `Farecart/Resources/Localizable.xcstrings` with English keys and
translations for Spanish, Polish, Simplified Chinese (`zh-Hans`), Arabic, Tagalog (`fil`), Urdu, Ukrainian
and Korean. English and Spanish are reviewed; the other seven were written with machine assistance and are
marked "under review" in Settings. "Link/EBT", "SNAP", "CTA", "Ventra" and "Access" stay untranslated.
Text coming from the database (place names, hours, program descriptions) is shown as stored.

The language picked in the app (`@AppStorage("appLanguage")`, `AppLanguage`) applies instantly, without a
relaunch and without touching the phone's settings:

- `FarecartApp` injects `.environment(\.locale, …)` (and `.layoutDirection = .rightToLeft` for Arabic and
  Urdu) at the root, so every SwiftUI `Text` / `Label` / tab title re-resolves.
- Non-SwiftUI lookups go through `String(localized: "…", bundle: LanguageBundle.current)`;
  `LanguageBundle.current` is the `.lproj` bundle of the chosen language, falling back to `Bundle.main`.
  Use that form for any new `String(localized:)` call.
- "Use phone language" (default) leaves both at the system values.

Adding a string: use it in code, build once, then add the nine localizations to the catalog (Xcode's
editor, or a script like the one used for this batch; the catalog is plain JSON). Plural keys use
`variations.plural` with the CLDR categories of each language (Arabic: zero/one/two/few/many/other,
Polish and Ukrainian: one/few/many/other, Chinese and Korean: other only).

The theme (`@AppStorage("appTheme")`, `AppTheme`) is applied with `.preferredColorScheme` at the root.

## Account (optional)

Email + password, Google or Sign in with Apple through Supabase Auth, no SDK. All end in the same `AuthSession`
(which records `provider`, so Settings says "Signed in with email / Google / Apple"), stored and refreshed the
same way. Every sign-in claims this phone's guest pantry visits for the account (`claim_device_visits`).

Email + password (`SupabaseAuthClient`):

- `signUp(email:password:name:)` → `POST auth/v1/signup` with `data.full_name`. Email autoconfirm is on today, so
  the response is a session; with confirmations on it returns `.confirmationRequired` and the emailed link comes
  back to `farecart://auth-callback?code=…` (PKCE verifier kept in the Keychain), which signs the user in.
- `signIn(email:password:)` → `POST auth/v1/token?grant_type=password`.
- `sendPasswordReset(email:)` → `POST auth/v1/recover` with the same PKCE redirect; the link signs the user in and
  `NewPasswordSheet` asks for a new password (`updatePassword`, `PUT auth/v1/user`).
- Errors become `AuthError` (`invalidCredentials`, `userAlreadyExists`, `weakPassword`, `emailNotConfirmed`,
  `rateLimited`, `invalidEmail`, `signupDisabled`, `other`) and `AccountModel` shows localized copy for each.
- See `docs/DEVELOPER.md` → Accounts: autoconfirm must be turned off once a real SMTP provider is set up.

Delete account (Settings → Account → Delete account): a screen listing what is removed, a destructive button and a
confirmation dialog, then `delete_my_account()` (removes the `auth.users` row; `profiles` cascades, visits keep
their device and lose the user id), then the Keychain session is cleared and the visit list reloads.

Sign in with Apple:

1. `SignInWithAppleButton` (`AuthenticationServices`) with a random nonce; its SHA-256 goes to Apple.
2. `SupabaseAuthClient.signInWithApple` posts `{provider:"apple", id_token, nonce}` to
   `auth/v1/token?grant_type=id_token` with the `apikey` header and gets access + refresh tokens.
3. `AccountModel` stores the `AuthSession` as JSON in the Keychain (`Keychain.swift`, generic password,
   service `org.farecart.app`), refreshes with `grant_type=refresh_token` when the access token is within a
   minute of expiry, and forgets the session on a 4xx refresh.
4. Signed in, the `profiles` row (`household_snap`, `is_student`, `language`, `theme`) is upserted through
   PostgREST with the user's JWT as `Authorization: Bearer` (`Prefer: resolution=merge-duplicates`) whenever
   an answer, the language or the theme changes, and read back on launch to sync a new phone.

Setup on your side (one-time):

- Supabase: the Apple provider is already enabled with client id `org.farecart.app` (Management API
  `PATCH /config/auth` with `external_apple_enabled` + `external_apple_client_id`). Native sign-in uses the
  bundle id; no services id or secret is needed.
- Apple Developer: enable the **Sign in with Apple** capability for the `org.farecart.app` App ID on your
  team (Certificates, Identifiers & Profiles → Identifiers → the App ID → Capabilities), then pick your
  team in Xcode. `Farecart/Farecart.entitlements` (`com.apple.developer.applesignin: [Default]`) is wired in
  `project.yml`. Until the capability exists, a device build will fail to sign with it.
- Simulator: without an iCloud account the Apple sheet errors out; the app shows "Sign in with Apple is not
  available on this device right now" and keeps working without an account. Sign in to iCloud in the
  simulator's Settings to test the full flow.

### Continue with Google (hosted OAuth with PKCE)

No Google SDK. The app opens Supabase's hosted flow in an `ASWebAuthenticationSession` and comes back through
the custom URL scheme `farecart://auth-callback` (`CFBundleURLTypes` in `project.yml`):

1. `PKCE.makeVerifier()` stays in `AccountModel`; `PKCE.challenge(for:)` (base64url SHA-256) goes into
   `SupabaseAuthClient.authorizeURL(provider: "google", redirectTo: "farecart://auth-callback", codeChallenge:)`
   → `{SUPABASE_URL}/auth/v1/authorize?provider=google&redirect_to=…&code_challenge=…&code_challenge_method=s256`.
2. `preflightAuthorize` fetches that URL once first. While the provider has no client id, GoTrue answers HTTP 400
   JSON (`Unsupported provider: missing OAuth client ID`) instead of redirecting, so the app shows "Google sign-in
   isn't set up yet." and never opens the browser. Once configured the response is Google's page and the flow goes on.
3. `ASWebAuthenticationSession(url:callback: .customScheme("farecart"))`, not ephemeral (an existing Google session
   in Safari makes it one tap), presented from the key window. Cancelling the sheet is silent.
4. `OAuthCallback.parse` reads `?code=` (or `#access_token=…&refresh_token=…` if tokens ever come in the fragment,
   or `error=`/`error_description=` for a denied or failed sign-in). `exchangeCode(code:codeVerifier:)` posts
   `{auth_code, code_verifier}` to `auth/v1/token?grant_type=pkce` and returns the same `AuthSession` as Apple;
   it is stored in the Keychain and the profile is upserted exactly like the Apple path.
5. If the callback reaches the app outside the session (Safari, a link), `FarecartApp`'s `.onOpenURL` hands it to
   `AccountModel.handleOpenURL`, which cancels the sheet and finishes the same way.

The Google button is plain SwiftUI (white / dark fill, hairline border, the "G" drawn in `GoogleGMark` with
`Canvas`), so no trademark asset is shipped.

**Setup on your side (one-time), Google Cloud Console:**

1. Open [console.cloud.google.com](https://console.cloud.google.com) → *APIs & Services* → *OAuth consent screen*.
   Pick **External**, app name "Farecart", your support email, and add the scopes `email`, `profile`, `openid`.
   While the app is in *Testing* only the test users you list can sign in; *Publish* it when ready.
2. *APIs & Services* → *Credentials* → **Create credentials → OAuth client ID** → application type
   **Web application** (not iOS: the exchange happens on Supabase's server). Name it "Farecart (Supabase)".
3. Under **Authorized redirect URIs** add exactly
   `https://mwirkxfqbomaaoygyfgm.supabase.co/auth/v1/callback`
   (no trailing slash). Authorized JavaScript origins can stay empty. Save and copy the **Client ID**
   (`…apps.googleusercontent.com`) and **Client secret**.
4. Put them into Supabase, either in the Dashboard → *Authentication* → *Providers* → *Google* (toggle on, paste
   client ID and secret, save), or hand them to the assistant to set through the Management API:
   `PATCH https://api.supabase.com/v1/projects/mwirkxfqbomaaoygyfgm/config/auth` with
   `{"external_google_enabled": true, "external_google_client_id": "…", "external_google_secret": "…"}`.

Already done through the Management API: `external_google_enabled: true` and `uri_allow_list` containing
`farecart://auth-callback` (the redirect Supabase is allowed to send the browser back to). Nothing in the app
changes when the client ID lands; the "isn't set up yet" line simply stops appearing.

## Previews

Every screen has a `#Preview` using `AppEnvironment.preview()` → `MockDataProvider` with five
fictional West Side listings, so previews work before the `locations` table is seeded.
