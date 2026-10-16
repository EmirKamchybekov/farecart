#!/usr/bin/env node
// Farecart: build data/locations_citywide.csv from bulk, citable sources.
//
// Inputs (all under data/raw/, which is gitignored and treated as untrusted data):
//   usda_snap_chicago.json          USDA FNS SNAP Retailer Locator, City=Chicago, State=IL (ArcGIS feature service)
//   osm_chicago.json                Overpass export: food banks / soup kitchens / supermarkets inside Chicago (relation 122604)
//   plentiful_list.json + plentiful_details/*.html   directory.plentiful.org Chicago listings (+ per-location pages)
//   foodpantries_list.json          foodpantries.org/ci/il-chicago schema.org entries
//   chicago_community_areas.geojson City of Chicago community areas (for `neighborhood`)
//   geocode_cache.json              written by this script; Census/Nominatim results, so re-runs don't re-geocode
//
// Output: data/locations_citywide.csv — same columns as locations.csv plus `source_kind`.
// The 44 curated rows in locations.csv are never written here; anything that collides with
// them (same normalized address+type, or within 60 m with a similar name) is dropped.
//
// Usage: node data/build_citywide.mjs [--no-geocode]
// See data/fetch_raw.sh for how the raw files are downloaded.

import { readFileSync, writeFileSync, existsSync, readdirSync } from 'node:fs';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
const RAW = resolve(here, 'raw');
const CURATED_CSV = resolve(here, 'locations.csv');
const OUT_CSV = resolve(here, 'locations_citywide.csv');
const CACHE = resolve(RAW, 'geocode_cache.json');
const GEOCODE = !process.argv.includes('--no-geocode');

const COLUMNS = ['name','type','address','neighborhood','lat','lng','hours_text','accepts_ebt','requirements','languages','phone','website','source_url','notes','source_kind'];
const CHICAGO = { latMin: 41.64, latMax: 42.03, lngMin: -87.95, lngMax: -87.52 };
const UA = 'Farecart-seed/1.0 (food access app; contact via repo)';
const RETRIEVED = '2026-10-15';

const USDA_DATASET_URL = 'https://usda-snap-retailers-usda-fns.hub.arcgis.com/datasets/8b260f9a10b0459aa441ad8588c2251c';
const OSM_ATTRIB = '© OpenStreetMap contributors (ODbL)';

// ---------- small helpers ----------
const sleep = ms => new Promise(r => setTimeout(r, ms));
const inChicago = (lat, lng) => lat >= CHICAGO.latMin && lat <= CHICAGO.latMax && lng >= CHICAGO.lngMin && lng <= CHICAGO.lngMax;
function haversineM(a, b) {
  const R = 6371000, toR = d => d * Math.PI / 180;
  const dLat = toR(b.lat - a.lat), dLng = toR(b.lng - a.lng);
  const s = Math.sin(dLat / 2) ** 2 + Math.cos(toR(a.lat)) * Math.cos(toR(b.lat)) * Math.sin(dLng / 2) ** 2;
  return 2 * R * Math.asin(Math.sqrt(s));
}
function titleCase(s) {
  return s.toLowerCase().replace(/(^|[\s\-/("'])([a-z])/g, (m, p, c) => p + c.toUpperCase())
    .replace(/\b(Of|And|De|La|El|Y|Del|Los|Las)\b/g, w => w.toLowerCase())
    .replace(/^([a-z])/, c => c.toUpperCase())
    .replace(/\bMckinley\b/g, 'McKinley');
}
const isAllCaps = s => /[A-Z]/.test(s) && s === s.toUpperCase();
function tidyCase(s) { return isAllCaps(s) ? titleCase(s) : s.replace(/'S\b/g, "'s"); }

// Strip trailing store numbers / corporate suffixes from USDA names.
function cleanStoreName(raw) {
  let n = String(raw || '').replace(/\s+/g, ' ').trim();
  n = n.replace(/\s*(,|\.)?\s*\b(inc|inc\.|llc|l\.l\.c\.|corp|corp\.|corporation|ltd|ltd\.|co\.|company|nfp|dba:?)\s*$/i, '').trim();
  for (let i = 0; i < 4; i++) {
    const before = n;
    n = n.replace(/\s+(#\s*\d{1,10}|no\.?\s*\d{1,10}|t\d{3,6}|[a-z]{1,3}\d{1,6}|\d{1,10}|[a-z]{2,3}\d{1,4})\s*$/i, '').trim();
    n = n.replace(/\s*(,|\.)?\s*\b(inc|inc\.|llc|corp|corp\.|corporation|ltd|ltd\.|co\.|company|nfp)\s*$/i, '').trim();
    if (n === before || n.split(' ').length < 1) break;
  }
  n = tidyCase(n);
  // chain normalisation
  if (/^jewel(\s*food\s*store|\s*-?\s*osco)?$/i.test(n)) n = 'Jewel-Osco';
  if (/^aldi$/i.test(n)) n = 'ALDI';
  if (/^target(\s+store)?$/i.test(n)) n = 'Target';
  if (/^food for less$/i.test(n)) n = 'Food 4 Less';
  if (/^food 4 less midwest$/i.test(n)) n = 'Food 4 Less';
  if (/^mariano's fresh market$/i.test(n)) n = "Mariano's";
  if (/^walmart supercenter$/i.test(n)) n = 'Walmart Supercenter';
  if (/^h ?mart chicago$/i.test(n)) n = 'H Mart';
  if (/^cermak fresh markt$/i.test(n)) n = 'Cermak Fresh Market';
  return n || String(raw).trim();
}

const STREET_ABBR = { street: 'st', avenue: 'ave', av: 'ave', boulevard: 'blvd', road: 'rd', drive: 'dr', place: 'pl', court: 'ct', parkway: 'pkwy', lane: 'ln', terrace: 'ter', highway: 'hwy', north: 'n', south: 's', east: 'e', west: 'w', 'n.': 'n', 's.': 's', 'e.': 'e', 'w.': 'w', 'st.': 'st', 'ave.': 'ave', 'blvd.': 'blvd', 'rd.': 'rd', 'dr.': 'dr', saint: 'st', martin: 'martin' };
// Normalised street-address key: "1234 w madison st"
function normAddress(address) {
  let a = String(address || '').toLowerCase();
  a = a.split(/,\s*chicago\b/)[0].split(/\bchicago\b/)[0];
  a = a.replace(/\b(suite|ste|unit|apt|fl|floor|rm|room)\.?\s*[#\w-]+/g, ' ').replace(/#\s*\w+/g, ' ');
  a = a.replace(/[.,]/g, ' ').replace(/[^a-z0-9\s]/g, ' ');
  const toks = a.split(/\s+/).filter(Boolean).map(t => STREET_ABBR[t] || t);
  // drop ordinal suffixes: 63rd -> 63
  return toks.map(t => t.replace(/^(\d+)(st|nd|rd|th)$/, '$1')).join(' ').trim();
}
const STOP = new Set(['the','of','and','a','at','in','food','pantry','foods','market','store','inc','church','parish','center','community','program','ministry','ministries','chicago','mission','services','st','saint']);
function nameTokens(n) { return new Set(String(n).toLowerCase().replace(/[^a-z0-9\s]/g, ' ').split(/\s+/).filter(t => t && !STOP.has(t) && t.length > 1)); }
function similarName(a, b) {
  const A = nameTokens(a), B = nameTokens(b);
  if (!A.size || !B.size) return String(a).toLowerCase().trim() === String(b).toLowerCase().trim();
  let inter = 0; for (const t of A) if (B.has(t)) inter++;
  const j = inter / (A.size + B.size - inter);
  return j >= 0.5 || inter >= Math.min(A.size, B.size) && inter >= 1 && Math.min(A.size, B.size) <= 2 && inter === Math.min(A.size, B.size);
}

// ---------- CSV ----------
function parseCSV(text) {
  const rows = []; let row = [], field = '', inQ = false;
  for (let i = 0; i < text.length; i++) {
    const c = text[i];
    if (inQ) { if (c === '"') { if (text[i + 1] === '"') { field += '"'; i++; } else inQ = false; } else field += c; }
    else if (c === '"') inQ = true;
    else if (c === ',') { row.push(field); field = ''; }
    else if (c === '\n' || c === '\r') { if (c === '\r' && text[i + 1] === '\n') i++; row.push(field); field = ''; if (row.some(f => f !== '')) rows.push(row); row = []; }
    else field += c;
  }
  if (field !== '' || row.length) { row.push(field); if (row.some(f => f !== '')) rows.push(row); }
  const header = rows[0].map(h => h.trim());
  return rows.slice(1).map(r => { const o = {}; header.forEach((h, i) => { o[h] = (r[i] ?? '').trim(); }); return o; });
}
const csvField = v => { const s = v == null ? '' : String(v); return /[",\n\r]/.test(s) ? '"' + s.replace(/"/g, '""') + '"' : s; };
const toCSV = (cols, rows) => [cols.join(','), ...rows.map(r => cols.map(c => csvField(r[c])).join(','))].join('\n') + '\n';

// ---------- community areas ----------
const SIDES = {
  'Far North': [1,2,3,4,9,10,11,12,13,14,76,77],
  'North': [5,6,7,21,22],
  'Northwest': [15,16,17,18,19,20],
  'Central': [8,32,33],
  'West': [23,24,25,26,27,28,29,30,31],
  'South': [34,35,36,37,38,39,40,41,42,43,60,69],
  'Southwest': [56,57,58,59,61,62,63,64,65,66,67,68],
  'Far Southwest': [70,71,72,73,74,75],
  'Far Southeast': [44,45,46,47,48,49,50,51,52,53,54,55],
};
const sideOfArea = {}; for (const [s, nums] of Object.entries(SIDES)) for (const n of nums) sideOfArea[n] = s;
let areas = [];
if (existsSync(resolve(RAW, 'chicago_community_areas.geojson'))) {
  const gj = JSON.parse(readFileSync(resolve(RAW, 'chicago_community_areas.geojson'), 'utf8'));
  areas = gj.features.map(f => ({ name: titleCase(f.properties.community), num: +f.properties.area_numbe, polys: f.geometry.type === 'Polygon' ? [f.geometry.coordinates] : f.geometry.coordinates }));
}
function pointInRing(x, y, ring) {
  let inside = false;
  for (let i = 0, j = ring.length - 1; i < ring.length; j = i++) {
    const xi = ring[i][0], yi = ring[i][1], xj = ring[j][0], yj = ring[j][1];
    if ((yi > y) !== (yj > y) && x < (xj - xi) * (y - yi) / (yj - yi) + xi) inside = !inside;
  }
  return inside;
}
function communityArea(lat, lng) {
  for (const a of areas) for (const poly of a.polys) {
    if (pointInRing(lng, lat, poly[0]) && !poly.slice(1).some(h => pointInRing(lng, lat, h))) return a;
  }
  return null;
}

// ---------- geocoding (same rules as seed.mjs) ----------
const cache = existsSync(CACHE) ? JSON.parse(readFileSync(CACHE, 'utf8')) : {};
function streetAgrees(address, matched) {
  if (!matched) return true;
  const a = address.toUpperCase(), m = matched.toUpperCase();
  const num = a.match(/^\s*(\d+)/)?.[1];
  const nameWord = a.replace(/^\s*\d+[A-Z]?\s+/, '').match(/^(?:[NSEW]\.?\s+)?([A-Z0-9']+)/)?.[1];
  if (num && !new RegExp(`\\b${num}\\b`).test(m)) return false;
  if (nameWord && nameWord.length > 2 && !m.includes(nameWord)) return false;
  return true;
}
async function censusGeocode(address) {
  const u = new URL('https://geocoding.geo.census.gov/geocoder/locations/onelineaddress');
  u.searchParams.set('address', address); u.searchParams.set('benchmark', 'Public_AR_Current'); u.searchParams.set('format', 'json');
  const res = await fetch(u, { headers: { 'User-Agent': UA } });
  if (!res.ok) throw new Error(`census ${res.status}`);
  const m = (await res.json())?.result?.addressMatches?.[0];
  return m ? { lat: m.coordinates.y, lng: m.coordinates.x, matched: m.matchedAddress, provider: 'census' } : null;
}
async function nominatimGeocode(address) {
  const u = new URL('https://nominatim.openstreetmap.org/search');
  u.searchParams.set('q', address); u.searchParams.set('format', 'jsonv2'); u.searchParams.set('limit', '1'); u.searchParams.set('countrycodes', 'us');
  const res = await fetch(u, { headers: { 'User-Agent': UA } });
  if (!res.ok) throw new Error(`nominatim ${res.status}`);
  const j = await res.json();
  return j?.[0] ? { lat: +j[0].lat, lng: +j[0].lon, matched: j[0].display_name, provider: 'nominatim' } : null;
}
async function geocode(address) {
  if (address in cache) return cache[address];
  if (!GEOCODE) return null;
  let r = null;
  try { r = await censusGeocode(address); } catch (e) { console.warn(`  census error: ${e.message}`); }
  if (!(r && inChicago(r.lat, r.lng) && streetAgrees(address, r.matched))) {
    if (r) console.warn(`  census match rejected (${r.matched})`);
    await sleep(1100);
    try { r = await nominatimGeocode(address); } catch (e) { console.warn(`  nominatim error: ${e.message}`); }
    if (!(r && inChicago(r.lat, r.lng) && streetAgrees(address, r.matched))) { if (r) console.warn(`  nominatim match rejected (${r.matched})`); r = null; }
  }
  cache[address] = r; writeFileSync(CACHE, JSON.stringify(cache, null, 1));
  await sleep(1100);
  return r;
}

// ---------- OSM opening_hours -> readable ----------
function osmHours(s) {
  if (!s) return '';
  if (/^\d/.test(s)) s = 'Daily ' + s;
  return s.replace(/\bMo\b/g, 'Mon').replace(/\bTu\b/g, 'Tue').replace(/\bWe\b/g, 'Wed').replace(/\bTh\b/g, 'Thu').replace(/\bFr\b/g, 'Fri').replace(/\bSa\b/g, 'Sat').replace(/\bSu\b/g, 'Sun').replace(/\bPH\b/g, 'holidays').replace(/;\s*/g, '; ');
}
function osmAddress(t) {
  if (!t['addr:housenumber'] || !t['addr:street']) return null;
  return `${t['addr:housenumber']} ${t['addr:street']}, Chicago, IL${t['addr:postcode'] ? ' ' + t['addr:postcode'] : ''}`;
}
const osmUrl = e => `https://www.openstreetmap.org/${e.type}/${e.id}`;

// ================= sources =================
const out = [];       // candidate rows (before dedupe)
const stats = { usda: {}, osm: {}, plentiful: {}, foodpantries: {}, dropped: {} };
const bump = (o, k) => { o[k] = (o[k] || 0) + 1; };

// ---- 1. USDA SNAP retailers -> grocery ----
const EXCLUDE_NAME = /\b(gas|bp|shell|citgo|mobil|marathon|amoco|exxon|sunoco|liquor|liquors|spirits|wine|dollar|pharmacy|walgreens|cvs|7-?eleven|circle k|cellular|wireless|tobacco|smoke|vape|cigar|currency|check cash|phone|mini ?mart|quick ?mart|quick ?stop)\b/i;
const SPECIALTY_OK = /\b(bakery|bakehouse|panaderia|poultry|chicken|seafood|fish|fisheries|pescaderia|meat|carniceria|packing|butcher|produce|market|naan|injera|ham|naranjo|tapatia|wild fork|harvest|live)\b/i;
const USDA_TYPES = ['Supermarket', 'Super Store', 'Grocery Store', 'Farmers and Markets', 'Specialty Store'];
{
  const usda = JSON.parse(readFileSync(resolve(RAW, 'usda_snap_chicago.json'), 'utf8'));
  const seenAddr = new Map();
  const feats = usda.features.map(f => f.attributes)
    .filter(a => /^chicago$/i.test((a.City || '').trim()) && a.State === 'IL')
    .sort((a, b) => USDA_TYPES.indexOf(a.Store_Type) - USDA_TYPES.indexOf(b.Store_Type));
  for (const a of feats) {
    const t = a.Store_Type;
    if (!USDA_TYPES.includes(t)) { bump(stats.usda, `skip type:${t}`); continue; }
    const rawName = (a.Store_Name || '').trim();
    if (EXCLUDE_NAME.test(rawName)) { bump(stats.usda, 'skip excluded-name'); continue; }
    if (t === 'Specialty Store' && !SPECIALTY_OK.test(rawName)) { bump(stats.usda, 'skip specialty-nonfood'); continue; }
    const lat = +a.Latitude, lng = +a.Longitude;
    if (!inChicago(lat, lng)) { bump(stats.usda, 'skip out-of-bbox'); continue; }
    const street = tidyCase((a.Store_Street_Address || '').replace(/\s+/g, ' ').trim());
    if (!street) { bump(stats.usda, 'skip no-address'); continue; }
    const address = `${street}, Chicago, IL ${(a.Zip_Code || '').trim()}`.trim();
    const key = normAddress(address);
    if (seenAddr.has(key)) { bump(stats.usda, 'skip dup-address'); continue; }
    seenAddr.set(key, true);
    const name = cleanStoreName(rawName);
    let notes = `Listed by USDA as a SNAP-authorized ${t === 'Farmers and Markets' ? 'farmers market / farm stand' : t.toLowerCase()} (SNAP Retailer Locator data, retrieved ${RETRIEVED}).`;
    if (t === 'Farmers and Markets') notes += ' Farmers markets are usually seasonal; check the market schedule before going.';
    if (a.Incentive_Program) notes += ` Incentive program: ${a.Incentive_Program}.`;
    out.push({ name, type: 'grocery', address, lat, lng, hours_text: '', accepts_ebt: 'true', requirements: '', languages: '', phone: '', website: '', source_url: USDA_DATASET_URL, notes, source_kind: 'usda_snap', _usdaType: t });
    bump(stats.usda, `kept:${t}`);
  }
}

// ---- 2. OSM: supermarkets (hours enrichment) + food banks / soup kitchens (pantries) ----
{
  const osm = JSON.parse(readFileSync(resolve(RAW, 'osm_chicago.json'), 'utf8')).elements
    .map(e => ({ ...e, lat: e.lat ?? e.center?.lat, lng: e.lon ?? e.center?.lon, tags: e.tags || {} }))
    .filter(e => e.lat && e.lng);
  const shops = osm.filter(e => e.tags.shop === 'supermarket' || e.tags.shop === 'greengrocer');
  let enriched = 0;
  for (const r of out.filter(r => r.source_kind === 'usda_snap')) {
    const near = shops.filter(s => haversineM(r, s) <= 80 && (similarName(r.name, s.tags.name || '') || similarName(r.name, s.tags.brand || '')));
    const s = near.sort((a, b) => haversineM(r, a) - haversineM(r, b))[0];
    if (!s) continue;
    const h = osmHours(s.tags.opening_hours);
    if (h) { r.hours_text = h; r.notes += ` Hours from OpenStreetMap ${osmUrl(s)} (${OSM_ATTRIB}).`; enriched++; }
    if (!r.website && s.tags.website) r.website = s.tags.website;
    if (!r.phone && s.tags.phone) r.phone = s.tags.phone;
  }
  stats.osm['usda rows enriched with hours'] = enriched;
  const banks = osm.filter(e => e.tags.social_facility === 'food_bank' || e.tags.social_facility === 'soup_kitchen' || e.tags.amenity === 'food_bank');
  for (const e of banks) {
    const name = (e.tags.name || '').trim();
    if (!name) { bump(stats.osm, 'pantry skip no-name'); continue; }
    if (/greater chicago food depository/i.test(name)) { bump(stats.osm, 'pantry skip GCFD warehouse'); continue; }
    const address = osmAddress(e.tags);
    if (!address) { bump(stats.osm, 'pantry skip no-address'); continue; }
    if (!inChicago(e.lat, e.lng)) { bump(stats.osm, 'pantry skip out-of-bbox'); continue; }
    const kind = e.tags.social_facility === 'soup_kitchen' ? 'soup kitchen' : 'food bank / pantry';
    // "WIC Food Center" / "WIC Grocery" are WIC-voucher grocery stores, not pantries
    const isWic = /\bWIC\b/i.test(name);
    out.push({ name, type: isWic ? 'grocery' : 'pantry', address, lat: e.lat, lng: e.lng, hours_text: osmHours(e.tags.opening_hours), accepts_ebt: '', requirements: '', languages: '', phone: e.tags.phone || e.tags['contact:phone'] || '', website: e.tags.website || e.tags['contact:website'] || '', source_url: osmUrl(e),
      notes: isWic ? `WIC grocery store tagged in OpenStreetMap (${OSM_ATTRIB}); WIC vouchers accepted, SNAP/EBT not confirmed.` : `Tagged as a ${kind} in OpenStreetMap (${OSM_ATTRIB}); hours and requirements not verified.`, source_kind: 'osm' });
    bump(stats.osm, 'pantry kept');
  }
}

// ---- 3. Plentiful directory -> pantry ----
{
  const list = JSON.parse(readFileSync(resolve(RAW, 'plentiful_list.json'), 'utf8'));
  const dir = resolve(RAW, 'plentiful_details');
  const have = existsSync(dir) ? new Set(readdirSync(dir)) : new Set();
  const DAYS = { Monday: 'Mon', Tuesday: 'Tue', Wednesday: 'Wed', Thursday: 'Thu', Friday: 'Fri', Saturday: 'Sat', Sunday: 'Sun' };
  const fmtTime = t => { const [h, m] = t.split(':').map(Number); const ap = h >= 12 ? 'pm' : 'am'; const hh = h % 12 || 12; return m ? `${hh}:${String(m).padStart(2, '0')}${ap}` : `${hh}${ap}`; };
  for (const it of list) {
    if (!it.url) continue;
    const slug = it.url.split('/').pop();
    const f = resolve(dir, slug + '.html');
    let ld = null, freq = '';
    if (have.has(slug + '.html')) {
      const html = readFileSync(f, 'utf8');
      const m = html.match(/<script type="application\/ld\+json">([\s\S]*?)<\/script>/);
      try { ld = m && JSON.parse(m[1]); } catch { ld = null; }
      freq = html.match(/class="schedule-freq">([^<]*)</)?.[1]?.trim() || '';
    }
    const name = (ld?.name || it.name || '').replace(/\s+/g, ' ').trim();
    const street = (ld?.address?.streetAddress || it.address?.split(',')[0] || '').replace(/\s+/g, ' ').trim();
    const city = (ld?.address?.addressLocality || (it.address || '').split(',')[1] || '').trim();
    const zip = (ld?.address?.postalCode || (it.address || '').match(/\b(6\d{4})\b/)?.[1] || '').trim();
    if (!name || !street) { bump(stats.plentiful, 'skip no-name/address'); continue; }
    if (!/^chicago$/i.test(city)) { bump(stats.plentiful, `skip city:${city}`); continue; }
    const address = `${street}, Chicago, IL ${zip}`.trim();
    let lat = +ld?.geo?.latitude, lng = +ld?.geo?.longitude;
    if (!(lat && lng && inChicago(lat, lng))) { lat = lng = null; }
    let hours = '';
    const spec = ld?.openingHoursSpecification || [];
    if (spec.length) {
      hours = [...new Set(spec.map(s => `${(Array.isArray(s.dayOfWeek) ? s.dayOfWeek : [s.dayOfWeek]).map(d => DAYS[d] || d).join('/')} ${fmtTime(s.opens)}-${fmtTime(s.closes)}`))].join('; ');
      if (freq && !/^every week$/i.test(freq)) hours = `${freq}: ${hours}`;
    }
    const desc = (ld?.description || '').replace(/\s+/g, ' ').trim();
    const generic = new RegExp(`^${name.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')} food service location$`, 'i');
    const useful = desc && !generic.test(desc);
    const requirements = useful && /\b(id|identification|proof|zip|appointment|referral|resident|registration|register|bring|ticket|once|per month|per week)\b/i.test(desc) ? desc.slice(0, 300) : '';
    const org = (ld?.parentOrganization?.name || it.org || '').trim();
    let notes = `Listed in the Plentiful food pantry directory${ld?.dateModified ? ` (updated ${ld.dateModified})` : ''}; many Plentiful pantries let you reserve a visit in the Plentiful app.`;
    if (org && org.toLowerCase() !== name.toLowerCase()) notes += ` Run by ${org}.`;
    if (useful && !requirements) notes += ` ${desc.slice(0, 200)}`;
    const phone = (ld?.telephone || it.phone || '').replace(/[^\d]/g, '').replace(/^1?(\d{3})(\d{3})(\d{4})$/, '$1-$2-$3');
    out.push({ name, type: 'pantry', address, lat, lng, hours_text: hours, accepts_ebt: '', requirements, languages: '', phone, website: '', source_url: it.url, notes, source_kind: 'plentiful' });
    bump(stats.plentiful, 'kept');
  }
}

// ---- 4. foodpantries.org -> pantry (source_kind other) ----
{
  const list = JSON.parse(readFileSync(resolve(RAW, 'foodpantries_list.json'), 'utf8'));
  for (const it of list) {
    const name = (it.name || '').replace(/\s+/g, ' ').trim();
    const street = (it.street || '').replace(/\s+/g, ' ').replace(/\.(?=\s)/g, '').trim();
    if (!name || !street || !/^chicago$/i.test((it.city || '').trim())) { bump(stats.foodpantries, 'skip'); continue; }
    const address = `${street}, Chicago, IL ${(it.zip || '').trim()}`.trim();
    const desc = (it.description || '').replace(/\s+/g, ' ').trim();
    out.push({ name, type: 'pantry', address, lat: null, lng: null, hours_text: '', accepts_ebt: '', requirements: '', languages: '', phone: (it.phone || '').replace(/[^\d]/g, '').replace(/^1?(\d{3})(\d{3})(\d{4})$/, '$1-$2-$3'), website: '', source_url: it.url, notes: `Listed on foodpantries.org (third-party directory; hours in its description are not verified).${desc ? ' ' + desc.slice(0, 220) : ''}`, source_kind: 'other' });
    bump(stats.foodpantries, 'kept');
  }
}

// ================= dedupe =================
const curated = parseCSV(readFileSync(CURATED_CSV, 'utf8')).map(r => ({ ...r, lat: +r.lat, lng: +r.lng }));
const PRIORITY = { curated: 0, plentiful: 1, osm: 2, usda_snap: 3, gcfd: 4, other: 5 };
out.sort((a, b) => PRIORITY[a.source_kind] - PRIORITY[b.source_kind]);

// geocode rows missing coordinates first so distance checks work
for (const r of out) {
  if (r.lat && r.lng) continue;
  const cached = r.address in cache;
  if (!cached) console.log(`Geocoding: ${r.name} — ${r.address}`);
  const g = await geocode(r.address);
  if (!g) { if (!cached) console.warn('  !! no geocode'); continue; }
  r.lat = g.lat; r.lng = g.lng;
  if (!cached) console.log(`  -> ${g.lat.toFixed(6)},${g.lng.toFixed(6)} (${g.provider})`);
}

const kept = [];
const keyOf = r => `${r.type}|${normAddress(r.address)}`;
const accepted = [...curated.map(r => ({ ...r, source_kind: 'curated' }))];
const keys = new Set(accepted.map(keyOf));
for (const r of out) {
  if (!r.lat || !r.lng) { bump(stats.dropped, `${r.source_kind}: no coordinates`); continue; }
  if (!inChicago(r.lat, r.lng)) { bump(stats.dropped, `${r.source_kind}: out of bbox`); continue; }
  const k = keyOf(r);
  if (keys.has(k)) { bump(stats.dropped, `${r.source_kind}: same address as earlier row`); continue; }
  const dup = accepted.find(a => a.type === r.type && haversineM(a, r) <= 60 && similarName(a.name, r.name));
  if (dup) { bump(stats.dropped, `${r.source_kind}: within 60 m of similar-name ${dup.source_kind} row`); continue; }
  const nameKey = `${r.name}|${r.address}`;
  if (accepted.some(a => `${a.name}|${a.address}` === nameKey)) { bump(stats.dropped, `${r.source_kind}: duplicate (name,address)`); continue; }
  keys.add(k); accepted.push(r); kept.push(r);
}

// neighborhood from community area
const sideCounts = {};
for (const r of kept) {
  const a = communityArea(r.lat, r.lng);
  r.neighborhood = a ? a.name : '';
  const side = a ? sideOfArea[a.num] : 'outside city limits';
  bump(sideCounts, side);
  if (!a) bump(stats.dropped, `${r.source_kind}: NOTE in bbox but outside community areas (kept)`);
}
// rows in the bbox but outside the city polygon are not Chicago — drop them
const final = kept.filter(r => r.neighborhood);
stats.dropped['outside Chicago community areas (dropped)'] = kept.length - final.length;

final.sort((a, b) => a.type.localeCompare(b.type) || a.source_kind.localeCompare(b.source_kind) || a.name.localeCompare(b.name));
const rows = final.map(r => ({ ...r, lat: (+r.lat).toFixed(6), lng: (+r.lng).toFixed(6) }));
writeFileSync(OUT_CSV, toCSV(COLUMNS, rows));

const byType = {}, byKind = {};
for (const r of final) { bump(byType, r.type); bump(byKind, r.source_kind); }
console.log('\nUSDA:', stats.usda);
console.log('OSM:', stats.osm);
console.log('Plentiful:', stats.plentiful);
console.log('foodpantries.org:', stats.foodpantries);
console.log('Dropped:', stats.dropped);
console.log('By side (kept rows):', sideCounts);
console.log(`Wrote ${rows.length} rows to ${OUT_CSV}`, byType, byKind);
