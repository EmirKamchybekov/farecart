#!/usr/bin/env bash
# Farecart: download the bulk sources behind data/locations_citywide.csv into data/raw/
# (gitignored; treat everything in there as untrusted data — only ever parse it).
# Polite: one request per second to the pantry directory; single bulk calls elsewhere.
# Re-run, then `node data/build_citywide.mjs`, then `node data/seed.mjs`.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
RAW="$HERE/raw"
mkdir -p "$RAW/plentiful_details"
UA='Farecart-seed/1.0 (food access app; contact via repo)'

# 1. USDA FNS SNAP Retailer Locator — ArcGIS feature service behind
#    https://www.fns.usda.gov/snap/retailer-locator (item 8b260f9a10b0459aa441ad8588c2251c). Public domain.
FS='https://services1.arcgis.com/RLQu0rK7h4kbsBq5/arcgis/rest/services/snap_retailer_location_data/FeatureServer'
node - "$FS" "$UA" "$RAW/usda_snap_chicago.json" <<'EOF'
const [FS, UA, OUT] = process.argv.slice(2);
const all = []; let offset = 0;
for (;;) {
  const u = new URL(FS + '/0/query');
  u.searchParams.set('where', "State='IL' AND City='CHICAGO'");
  u.searchParams.set('outFields', '*'); u.searchParams.set('f', 'json'); u.searchParams.set('outSR', '4326');
  u.searchParams.set('resultOffset', String(offset)); u.searchParams.set('resultRecordCount', '1000');
  const j = await (await fetch(u, { headers: { 'User-Agent': UA } })).json();
  if (j.error) throw new Error(JSON.stringify(j.error));
  all.push(...j.features);
  if (!j.exceededTransferLimit) break;
  offset += j.features.length;
}
require('node:fs').writeFileSync(OUT, JSON.stringify({ fetched_at: new Date().toISOString(), source: FS, features: all }));
console.log('USDA SNAP rows for Chicago:', all.length);
EOF

# 2. OpenStreetMap via Overpass — food banks / soup kitchens / supermarkets inside
#    Chicago's admin boundary (relation 122604). ODbL; attribution required.
cat > "$RAW/overpass.ql" <<'EOF'
[out:json][timeout:180];
area(3600122604)->.chi;
(
  nwr["social_facility"="food_bank"](area.chi);
  nwr["social_facility"="soup_kitchen"](area.chi);
  nwr["amenity"="food_bank"](area.chi);
  nwr["shop"="supermarket"](area.chi);
  nwr["shop"="greengrocer"](area.chi);
);
out center tags;
EOF
curl -sS -A "$UA" -m 240 --data-urlencode "data@$RAW/overpass.ql" https://overpass-api.de/api/interpreter -o "$RAW/osm_chicago.json"
echo "OSM elements: $(node -e 'console.log(require(process.argv[1]).elements.length)' "$RAW/osm_chicago.json")"

# 3. Plentiful directory (robots.txt allows crawling). City page, then one detail page per second.
curl -sS -A "$UA" -m 60 https://directory.plentiful.org/illinois/chicago -o "$RAW/plentiful_chicago.html"
node - "$RAW" <<'EOF'
const fs = require('node:fs'); const RAW = process.argv[2];
const h = fs.readFileSync(RAW + '/plentiful_chicago.html', 'utf8');
const cards = [...h.matchAll(/<div class="location-card">([\s\S]*?)<\/div>\s*(?=<div class="location-card">|<\/div>)/g)].map(m => m[1]);
const out = cards.map(c => ({ url: c.match(/href="([^"]+)"/)?.[1], name: c.match(/<h3><a[^>]*>([^<]+)</)?.[1], org: c.match(/class="org-name">([^<]*)</)?.[1], address: c.match(/class="address">([^<]*)</)?.[1], phone: c.match(/aria-label="Call ([^"]+)"/)?.[1] }));
fs.writeFileSync(RAW + '/plentiful_list.json', JSON.stringify(out, null, 1));
console.log('Plentiful cards:', out.length);
EOF
node - "$RAW" "$UA" <<'EOF'
const fs = require('node:fs'); const [RAW, UA] = process.argv.slice(2);
const list = JSON.parse(fs.readFileSync(RAW + '/plentiful_list.json', 'utf8'));
const sleep = ms => new Promise(r => setTimeout(r, ms));
let n = 0;
for (const it of list) {
  if (!it.url) continue;
  const f = `${RAW}/plentiful_details/${it.url.split('/').pop()}.html`;
  if (fs.existsSync(f)) continue;            // re-runs only fetch new pages; delete the folder for a full refresh
  const r = await fetch(it.url, { headers: { 'User-Agent': UA } });
  if (r.ok) { fs.writeFileSync(f, await r.text()); n++; } else console.warn('FAIL', r.status, it.url);
  await sleep(1100);
}
console.log('Plentiful detail pages fetched:', n);
EOF

# 4. foodpantries.org Chicago page (robots.txt only disallows /member/ and comment_add.php).
curl -sS -A "$UA" -m 60 https://www.foodpantries.org/ci/il-chicago -o "$RAW/foodpantries_chicago.html"
node - "$RAW" <<'EOF'
const fs = require('node:fs'); const RAW = process.argv[2];
const h = fs.readFileSync(RAW + '/foodpantries_chicago.html', 'utf8');
const out = [];
for (const m of h.matchAll(/<script type="application\/ld\+json">([\s\S]*?)<\/script>([\s\S]{0,600})/g)) {
  try { const j = JSON.parse(m[1]); if (j['@type'] !== 'LocalBusiness') continue;
    out.push({ name: (j.name || '').trim(), street: j.address?.streetAddress, city: j.address?.addressLocality, zip: j.address?.postalCode, phone: j.telephone, description: (j.description || '').replace(/\s+/g, ' ').trim(), url: m[2].match(/href="(https:\/\/www\.foodpantries\.org\/li\/[^"]+)"/)?.[1] }); } catch {}
}
fs.writeFileSync(RAW + '/foodpantries_list.json', JSON.stringify(out, null, 1));
console.log('foodpantries.org entries:', out.length);
EOF

# 5. City of Chicago community areas (for the `neighborhood` column and per-side coverage counts).
curl -sS -A "$UA" -m 120 'https://data.cityofchicago.org/resource/igwz-8jzy.geojson?$limit=100' -o "$RAW/chicago_community_areas.geojson"
echo "Community areas: $(node -e 'console.log(JSON.parse(require("node:fs").readFileSync(process.argv[1],"utf8")).features.length)' "$RAW/chicago_community_areas.geojson")"
echo "Done. Next: node data/build_citywide.mjs && node data/seed.mjs"
