#!/usr/bin/env node
// Farecart data seed: reads data/locations.csv (curated, hand-researched tier),
// data/locations_citywide.csv (bulk tier built by data/build_citywide.mjs) and
// data/giveaway_events.csv; geocodes rows missing lat/lng (US Census Geocoder,
// fallback Nominatim), writes coordinates back into the CSV they came from, and
// upserts into Supabase via PostgREST.
// Idempotent: upserts on unique (name, address) for locations and
// unique (location_id, title, starts_at) for giveaway_events. Curated rows win:
// a citywide row with the same (name, address) as a curated row is skipped
// before the upsert, so bulk data never overwrites hand-researched data.
//
// Usage:  node data/seed.mjs            (from repo root; or run from anywhere)
//         node data/seed.mjs --dry-run  (geocode + validate, no DB writes)
//         node data/seed.mjs --no-geocode
//         node data/seed.mjs --curated-only   (skip locations_citywide.csv)

import { readFileSync, writeFileSync, existsSync } from 'node:fs';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
const LOCATIONS_CSV = resolve(here, 'locations.csv');
const CITYWIDE_CSV = resolve(here, 'locations_citywide.csv');
const EVENTS_CSV = resolve(here, 'giveaway_events.csv');
const ENV_FILE = resolve(here, '..', '.env.local');

const args = new Set(process.argv.slice(2));
const DRY_RUN = args.has('--dry-run');
const GEOCODE = !args.has('--no-geocode');
const CURATED_ONLY = args.has('--curated-only');

const COLUMNS = ['name','type','address','neighborhood','lat','lng','hours_text','accepts_ebt','requirements','languages','phone','website','source_url','notes'];
const CITYWIDE_COLUMNS = [...COLUMNS, 'source_kind'];
const SOURCE_KINDS = ['curated','usda_snap','osm','gcfd','plentiful','other'];
const EVENT_COLUMNS = ['location_name','title','starts_at','ends_at','details','source_url'];
const CHICAGO = { latMin: 41.64, latMax: 42.03, lngMin: -87.95, lngMax: -87.52 };
const UA = 'Farecart-seed/1.0 (food access app; contact via repo)';

// ---------- env ----------
function loadEnv(file) {
  const env = { ...process.env };
  if (existsSync(file)) {
    for (const line of readFileSync(file, 'utf8').split('\n')) {
      const m = line.match(/^\s*([A-Z0-9_]+)\s*=\s*(.*)\s*$/);
      if (m && !(m[1] in process.env)) env[m[1]] = m[2].replace(/^["']|["']$/g, '');
    }
  }
  return env;
}
const env = loadEnv(ENV_FILE);
const SUPABASE_URL = env.SUPABASE_URL;
const SERVICE_KEY = env.SUPABASE_SERVICE_ROLE_KEY;
if (!DRY_RUN && (!SUPABASE_URL || !SERVICE_KEY)) {
  console.error('Missing SUPABASE_URL / SUPABASE_SERVICE_ROLE_KEY in ../.env.local');
  process.exit(1);
}

// ---------- CSV ----------
function parseCSV(text) {
  const rows = [];
  let row = [], field = '', inQ = false;
  for (let i = 0; i < text.length; i++) {
    const c = text[i];
    if (inQ) {
      if (c === '"') {
        if (text[i + 1] === '"') { field += '"'; i++; } else inQ = false;
      } else field += c;
    } else if (c === '"') inQ = true;
    else if (c === ',') { row.push(field); field = ''; }
    else if (c === '\n' || c === '\r') {
      if (c === '\r' && text[i + 1] === '\n') i++;
      row.push(field); field = '';
      if (row.some(f => f !== '')) rows.push(row);
      row = [];
    } else field += c;
  }
  if (field !== '' || row.length) { row.push(field); if (row.some(f => f !== '')) rows.push(row); }
  if (!rows.length) return [];
  const header = rows[0].map(h => h.trim());
  return rows.slice(1).map((r, idx) => {
    const o = {};
    header.forEach((h, i) => { o[h] = (r[i] ?? '').trim(); });
    o.__line = idx + 2;
    return o;
  });
}
function csvField(v) {
  const s = v == null ? '' : String(v);
  return /[",\n\r]/.test(s) ? '"' + s.replace(/"/g, '""') + '"' : s;
}
function toCSV(columns, rows) {
  return [columns.join(','), ...rows.map(r => columns.map(c => csvField(r[c])).join(','))].join('\n') + '\n';
}

// ---------- geocoding ----------
const sleep = ms => new Promise(r => setTimeout(r, ms));

async function censusGeocode(address) {
  const u = new URL('https://geocoding.geo.census.gov/geocoder/locations/onelineaddress');
  u.searchParams.set('address', address);
  u.searchParams.set('benchmark', 'Public_AR_Current');
  u.searchParams.set('format', 'json');
  const res = await fetch(u, { headers: { 'User-Agent': UA } });
  if (!res.ok) throw new Error(`census ${res.status}`);
  const j = await res.json();
  const m = j?.result?.addressMatches?.[0];
  if (!m) return null;
  return { lat: m.coordinates.y, lng: m.coordinates.x, matched: m.matchedAddress, provider: 'census' };
}

async function nominatimGeocode(address) {
  const u = new URL('https://nominatim.openstreetmap.org/search');
  u.searchParams.set('q', address);
  u.searchParams.set('format', 'jsonv2');
  u.searchParams.set('limit', '1');
  u.searchParams.set('countrycodes', 'us');
  const res = await fetch(u, { headers: { 'User-Agent': UA } });
  if (!res.ok) throw new Error(`nominatim ${res.status}`);
  const j = await res.json();
  if (!j?.[0]) return null;
  return { lat: +j[0].lat, lng: +j[0].lon, matched: j[0].display_name, provider: 'nominatim' };
}

function inChicago(lat, lng) {
  return lat >= CHICAGO.latMin && lat <= CHICAGO.latMax && lng >= CHICAGO.lngMin && lng <= CHICAGO.lngMax;
}

// Street number and (first word of) street name must appear in the matched address.
function streetAgrees(address, matched) {
  if (!matched) return true;
  const a = address.toUpperCase(), m = matched.toUpperCase();
  const num = a.match(/^\s*(\d+)/)?.[1];
  const nameWord = a.replace(/^\s*\d+[A-Z]?\s+/, '').match(/^(?:[NSEW]\.?\s+)?([A-Z0-9']+)/)?.[1];
  if (num && !new RegExp(`\\b${num}\\b`).test(m)) return false;
  if (nameWord && nameWord.length > 2 && !m.includes(nameWord)) return false;
  return true;
}

async function geocode(address) {
  let r = null;
  try { r = await censusGeocode(address); } catch (e) { console.warn(`  census error: ${e.message}`); }
  if (r && inChicago(r.lat, r.lng) && streetAgrees(address, r.matched)) return r;
  if (r) console.warn(`  census match rejected (${r.matched})`);
  await sleep(1100); // Nominatim usage policy: max 1 req/s
  try { r = await nominatimGeocode(address); } catch (e) { console.warn(`  nominatim error: ${e.message}`); }
  if (r && inChicago(r.lat, r.lng) && streetAgrees(address, r.matched)) return r;
  if (r) console.warn(`  nominatim match rejected (${r.matched})`);
  return null;
}

// ---------- validation ----------
function parseBool(v) {
  if (v === '' || v == null) return null;
  const s = String(v).toLowerCase();
  if (['true','t','yes','y','1'].includes(s)) return true;
  if (['false','f','no','n','0'].includes(s)) return false;
  throw new Error(`bad boolean "${v}"`);
}

function validateLocation(r) {
  const errs = [];
  if (!r.name) errs.push('name required');
  if (!['grocery','pantry','giveaway'].includes(r.type)) errs.push(`bad type "${r.type}"`);
  if (!r.address) errs.push('address required');
  if (!r.source_url || !/^https?:\/\//.test(r.source_url)) errs.push('source_url required');
  if (r.verified_on) errs.push('verified_on must be blank (humans verify)');
  if (!SOURCE_KINDS.includes(r.source_kind)) errs.push(`bad source_kind "${r.source_kind}"`);
  if (r.lat && r.lng && !inChicago(+r.lat, +r.lng)) errs.push(`coords out of Chicago bbox (${r.lat},${r.lng})`);
  return errs;
}

// ---------- PostgREST ----------
async function rest(path, { method = 'GET', body, prefer } = {}) {
  const headers = {
    apikey: SERVICE_KEY,
    Authorization: `Bearer ${SERVICE_KEY}`,
    'Content-Type': 'application/json',
    Accept: 'application/json',
  };
  if (prefer) headers.Prefer = prefer;
  const res = await fetch(`${SUPABASE_URL}/rest/v1/${path}`, { method, headers, body: body ? JSON.stringify(body) : undefined });
  const text = await res.text();
  if (!res.ok) throw new Error(`${method} ${path} -> ${res.status} ${text}`);
  return text ? JSON.parse(text) : null;
}

// ---------- main ----------
async function main() {
  // Curated tier first; every row there is source_kind=curated.
  const curated = parseCSV(readFileSync(LOCATIONS_CSV, 'utf8')).map(r => ({ ...r, source_kind: 'curated', __file: 'curated' }));
  // Citywide bulk tier second; carries its own source_kind column.
  const citywide = (!CURATED_ONLY && existsSync(CITYWIDE_CSV))
    ? parseCSV(readFileSync(CITYWIDE_CSV, 'utf8')).map(r => ({ ...r, source_kind: r.source_kind || 'other', __file: 'citywide' }))
    : [];
  const events = existsSync(EVENTS_CSV) ? parseCSV(readFileSync(EVENTS_CSV, 'utf8')) : [];
  console.log(`Read ${curated.length} curated + ${citywide.length} citywide locations, ${events.length} giveaway events`);

  // Duplicate key check: curated must be unique; citywide rows that collide with
  // a curated (name,address) are dropped so they never overwrite the curated tier.
  const seen = new Set();
  for (const r of curated) {
    const k = `${r.name}|${r.address}`;
    if (seen.has(k)) throw new Error(`duplicate (name,address) in locations.csv line ${r.__line}: ${k}`);
    seen.add(k);
  }
  const locations = [...curated];
  let shadowed = 0;
  for (const r of citywide) {
    const k = `${r.name}|${r.address}`;
    if (seen.has(k)) { shadowed++; continue; }
    seen.add(k);
    locations.push(r);
  }
  if (shadowed) console.log(`Skipped ${shadowed} citywide row(s) that duplicate a curated or earlier citywide (name,address)`);

  // Geocode missing coordinates
  const changed = { curated: false, citywide: false };
  for (const r of locations) {
    if (r.lat && r.lng) continue;
    if (!GEOCODE) continue;
    console.log(`Geocoding: ${r.name} — ${r.address}`);
    const g = await geocode(r.address);
    if (!g) { console.warn(`  !! no geocode for ${r.__file} line ${r.__line}`); continue; }
    r.lat = g.lat.toFixed(6); r.lng = g.lng.toFixed(6);
    console.log(`  -> ${r.lat},${r.lng} (${g.provider}: ${g.matched})`);
    changed[r.__file] = true;
    await sleep(250);
  }
  if (changed.curated) {
    writeFileSync(LOCATIONS_CSV, toCSV(COLUMNS, curated));
    console.log(`Wrote coordinates back to ${LOCATIONS_CSV}`);
  }
  if (changed.citywide) {
    writeFileSync(CITYWIDE_CSV, toCSV(CITYWIDE_COLUMNS, citywide));
    console.log(`Wrote coordinates back to ${CITYWIDE_CSV}`);
  }

  // Validate
  let bad = 0;
  const ready = [];
  for (const r of locations) {
    const errs = validateLocation(r);
    if (!r.lat || !r.lng) errs.push('missing lat/lng');
    if (errs.length) { bad++; console.error(`${r.__file} line ${r.__line} (${r.name}): ${errs.join('; ')}`); continue; }
    ready.push(r);
  }
  if (bad) console.error(`${bad} row(s) skipped due to validation errors`);

  const payload = ready.map(r => ({
    name: r.name,
    type: r.type,
    address: r.address,
    neighborhood: r.neighborhood || null,
    lat: +r.lat,
    lng: +r.lng,
    hours_text: r.hours_text || null,
    accepts_ebt: parseBool(r.accepts_ebt),
    requirements: r.requirements || null,
    languages: r.languages ? r.languages.split(/[;|]/).map(s => s.trim()).filter(Boolean) : [],
    phone: r.phone || null,
    website: r.website || null,
    source_url: r.source_url,
    notes: r.notes || null,
    source_kind: r.source_kind,
    verified_on: null,
    is_active: true,
  }));

  if (DRY_RUN) {
    console.log(`DRY RUN: would upsert ${payload.length} locations`);
    console.log(JSON.stringify(payload.slice(0, 2), null, 2));
    return;
  }

  // Upsert locations in chunks
  const idByKey = new Map();
  for (let i = 0; i < payload.length; i += 100) {
    const chunk = payload.slice(i, i + 100);
    const out = await rest('locations?on_conflict=name,address&select=id,name,address', {
      method: 'POST', body: chunk, prefer: 'resolution=merge-duplicates,return=representation',
    });
    for (const o of out) idByKey.set(`${o.name}|${o.address}`, o.id);
  }
  console.log(`Upserted ${idByKey.size} locations`);

  // Giveaway events (linked by name to curated rows)
  const nameToId = new Map();
  for (const r of ready) if (!nameToId.has(r.name)) nameToId.set(r.name, idByKey.get(`${r.name}|${r.address}`));
  const evPayload = [];
  for (const e of events) {
    const location_id = nameToId.get(e.location_name);
    if (!location_id) { console.error(`event line ${e.__line}: unknown location_name "${e.location_name}"`); continue; }
    if (!e.title || !e.starts_at) { console.error(`event line ${e.__line}: title and starts_at required`); continue; }
    evPayload.push({
      location_id,
      title: e.title,
      starts_at: new Date(e.starts_at).toISOString(),
      ends_at: e.ends_at ? new Date(e.ends_at).toISOString() : null,
      details: e.details || null,
      source_url: e.source_url || null,
    });
  }
  if (evPayload.length) {
    const out = await rest('giveaway_events?on_conflict=location_id,title,starts_at&select=id', {
      method: 'POST', body: evPayload, prefer: 'resolution=merge-duplicates,return=representation',
    });
    console.log(`Upserted ${out.length} giveaway events`);
  } else console.log('No giveaway events to upsert');

  // Summary by type and source_kind
  const counts = {};
  for (const p of payload) {
    counts[p.type] = (counts[p.type] || 0) + 1;
    const k = `${p.type}/${p.source_kind}`;
    counts[k] = (counts[k] || 0) + 1;
  }
  console.log('Counts by type and type/source_kind:', counts);
}

main().catch(e => { console.error(e); process.exit(1); });
