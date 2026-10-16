#!/usr/bin/env node
// Farecart: import Chicago food pantries from the Feed America directory
// (feedam.org, CC BY 4.0; attribution "Directory published by Feed America
// (feedam.org)"). Writes
//   data/locations_feedam.csv   new rows (source_kind=feedam), same columns as
//                               locations_citywide.csv + pantry_model,
//                               requires_snap, requires_id, feedam_id
//   data/feedam_matches.csv     Feed America ids for rows we already have
//                               (curated or citywide), keyed by (name,address)
// seed.mjs loads both after the citywide tier.
//
// API use: /api/resources/bulk?state=IL&type=... (5 pages, ≤1000 rows each)
// to enumerate, then /api/resources/{id} for each Chicago row to get the
// fields the bulk export leaves out (requirements_text, requires_id,
// income_limit_fpl, languages, services). Raw responses are cached in
// data/raw/feedam/ (gitignored, untrusted: parsed as data only). Rate: ≤2
// requests/s with a Farecart User-Agent; the daily cap is 10,000/IP and a
// full run uses ~260.
//
// Usage: node data/feedam.mjs [--no-fetch] [--refresh] [--no-geocode]
//   --no-fetch   use data/raw/feedam/ only (no network)
//   --refresh    re-download details even if cached

import { readFileSync, writeFileSync, existsSync, mkdirSync } from 'node:fs';
import { resolve } from 'node:path';
import { here, sleep, inChicago, parseCSV, toCSV, normAddress, similarName, haversineM, loadCommunityAreas } from './common.mjs';

const RAW = resolve(here, 'raw', 'feedam');
const OUT_CSV = resolve(here, 'locations_feedam.csv');
const MATCH_CSV = resolve(here, 'feedam_matches.csv');
const GEOCODE_CACHE = resolve(here, 'raw', 'geocode_cache.json');
const args = new Set(process.argv.slice(2));
const FETCH = !args.has('--no-fetch');
const REFRESH = args.has('--refresh');
const GEOCODE = !args.has('--no-geocode');

const API = 'https://feedam.org/api';
const UA = 'Farecart/0.1 (hello@farecart.org)';
const TYPES = ['food_pantry', 'soup_kitchen', 'food_bank', 'mobile_pantry'];
const MIN_INTERVAL_MS = 550;           // ≤2 req/s
const DAILY_BUDGET = 9000;             // stay under feedam.org's 10k/day/IP
const ATTRIBUTION = 'Directory published by Feed America (feedam.org), CC BY 4.0';
const COLUMNS = ['name','type','address','neighborhood','lat','lng','hours_text','accepts_ebt','requirements','languages','phone','website','source_url','notes','source_kind','pantry_model','requires_snap','requires_id','feedam_id'];
const RETRIEVED = new Date().toISOString().slice(0, 10);

mkdirSync(resolve(RAW, 'detail'), { recursive: true });

// ---------- polite fetch ----------
let lastAt = 0, requests = 0;
async function getJSON(path) {
  if (!FETCH) throw new Error(`--no-fetch but ${path} is not cached`);
  if (++requests > DAILY_BUDGET) throw new Error('daily request budget reached');
  const wait = lastAt + MIN_INTERVAL_MS - Date.now();
  if (wait > 0) await sleep(wait);
  lastAt = Date.now();
  const res = await fetch(`${API}${path}`, { headers: { 'User-Agent': UA, Accept: 'application/json' } });
  if (res.status === 429) { console.warn('  429 from feedam.org, backing off 30 s'); await sleep(30_000); return getJSON(path); }
  if (!res.ok) throw new Error(`feedam ${path} -> ${res.status}`);
  return res.json();
}
function cached(file) { return existsSync(file) ? JSON.parse(readFileSync(file, 'utf8')) : null; }

// ---------- 1. enumerate Illinois rows of the four types ----------
const bulk = [];
for (const t of TYPES) {
  const file = resolve(RAW, `bulk_il_${t}.json`);
  let rows = REFRESH ? null : cached(file);
  if (!rows) {
    rows = [];
    for (let page = 1; page <= 20; page++) {
      const j = await getJSON(`/resources/bulk?state=IL&type=${t}&limit=1000&page=${page}`);
      const r = j.resources || [];
      rows.push(...r);
      if (r.length < 1000) break;
    }
    writeFileSync(file, JSON.stringify(rows));
  }
  bulk.push(...rows);
}
const chicago = bulk.filter(r => TYPES.includes(r.resource_type) && /^chicago$/i.test((r.city || '').trim()) && +r.lat && +r.lng && inChicago(+r.lat, +r.lng));
console.log(`Feed America: ${bulk.length} Illinois rows of types ${TYPES.join('/')}, ${chicago.length} in Chicago`);

// ---------- 2. detail for each Chicago row ----------
const details = [];
for (const r of chicago) {
  const file = resolve(RAW, 'detail', `${r.id}.json`);
  let d = REFRESH ? null : cached(file);
  if (!d) {
    const j = await getJSON(`/resources/${r.id}`);
    d = j.resource || j;
    writeFileSync(file, JSON.stringify(d));
  }
  details.push({ ...r, ...d });
}
console.log(`Details: ${details.length} rows (${requests} API requests this run)`);

// ---------- 3. geocode rows whose coordinates are not trustworthy ----------
// 211-sourced rows carry coordinates rounded to a ~0.005° grid (…14/…64),
// hundreds of metres off; re-geocode those with the Census geocoder (cached).
const cache = cached(GEOCODE_CACHE) || {};
async function census(address) {
  if (address in cache) return cache[address];
  if (!GEOCODE) return null;
  const u = new URL('https://geocoding.geo.census.gov/geocoder/locations/onelineaddress');
  u.searchParams.set('address', address); u.searchParams.set('benchmark', 'Public_AR_Current'); u.searchParams.set('format', 'json');
  let r = null;
  try {
    const m = (await (await fetch(u, { headers: { 'User-Agent': UA } })).json())?.result?.addressMatches?.[0];
    if (m && inChicago(m.coordinates.y, m.coordinates.x)) r = { lat: m.coordinates.y, lng: m.coordinates.x, matched: m.matchedAddress, provider: 'census' };
  } catch (e) { console.warn(`  census error: ${e.message}`); }
  cache[address] = r; writeFileSync(GEOCODE_CACHE, JSON.stringify(cache, null, 1));
  await sleep(300);
  return r;
}
const quantized = v => /\.\d{2}(14|64)$/.test(String(v));
let regeocoded = 0, geocodeFailed = 0;
for (const r of details) {
  if (!(r.data_source === '211' || quantized(r.lat) || quantized(r.lng))) continue;
  const g = await census(fullAddress(r));
  if (g) { r.lat = g.lat; r.lng = g.lng; r._geocoded = true; regeocoded++; } else { r._badCoords = true; geocodeFailed++; }
}
console.log(`Re-geocoded ${regeocoded} row(s) with gridded 211 coordinates; ${geocodeFailed} could not be geocoded (dropped)`);

// ---------- field mapping ----------
function fullAddress(r) {
  let street = String(r.address || '').replace(/\s+/g, ' ').replace(/\.(?=\s|$)/g, '').replace(/(\d)(?=[A-Z][a-z])/, '$1 ').trim();
  street = street.replace(/,?\s*chicago,?\s*(il|illinois)?\.?\s*(6\d{4})?\s*$/i, '').replace(/,\s*$/, '').trim();
  return `${street}, Chicago, IL ${(r.zip || '').trim()}`.trim();
}
// "1234 w jackson" — house number + street name without the suffix, for the near-match rule
const streetKey = address => normAddress(address).replace(/\s+(st|ave|blvd|rd|dr|pl|ct|pkwy|ln|ter|hwy)$/, '');
const SMALL = new Set(['of','and','the','de','la','for','at','in','on']);
const tidyName = n => String(n).replace(/\s+/g, ' ').trim().split(' ').map((w, i) => /^[a-z]/.test(w) && (i === 0 || !SMALL.has(w)) ? cap(w) : w).join(' ');
const DAY = { mon: 'Mon', tue: 'Tue', tues: 'Tue', wed: 'Wed', thu: 'Thu', thur: 'Thu', thurs: 'Thu', fri: 'Fri', sat: 'Sat', sun: 'Sun', monday: 'Mon', tuesday: 'Tue', wednesday: 'Wed', thursday: 'Thu', friday: 'Fri', saturday: 'Sat', sunday: 'Sun', daily: 'Daily', weekdays: 'Mon-Fri' };
function dayLabel(k) {
  return k.toLowerCase().split(/\s*[-–]\s*/).map(p => DAY[p.trim()] || p.trim()).join('-');
}
function tidyTime(s) { return String(s).replace(/\s*(?:to|–|-)\s*/gi, '-').replace(/(\d)\s+(am|pm)/gi, '$1$2').replace(/:00(am|pm)/gi, '$1').replace(/\s+/g, ' ').trim(); }
function hoursText(hours_json) {
  if (!hours_json) return '';
  let h; try { h = typeof hours_json === 'string' ? JSON.parse(hours_json) : hours_json; } catch { return ''; }
  if (!h || typeof h !== 'object') return '';
  if (Array.isArray(h)) return '';
  const parts = [];
  for (const [k, v] of Object.entries(h)) {
    if (!v || typeof v !== 'string' || /closed/i.test(v) || !/\d\s*(am|pm|:)/i.test(v)) continue;
    parts.push(`${dayLabel(k)} ${tidyTime(v)}`);
  }
  return parts.join('; ');
}
function jsonList(v) { if (!v) return []; try { const a = typeof v === 'string' ? JSON.parse(v) : v; return Array.isArray(a) ? a.map(String) : []; } catch { return []; } }
const cap = s => s.charAt(0).toUpperCase() + s.slice(1);
function phone(p) { const d = String(p || '').replace(/\D/g, ''); return /^1?\d{10}$/.test(d) ? d.slice(-10).replace(/(\d{3})(\d{3})(\d{4})/, '$1-$2-$3') : ''; }
const DIRECTORY_HOSTS = /ampleharvest\.org|foodpantries\.org|plentiful\.org|feedam\.org|211/i;
function website(w) { return w && /^https?:\/\//.test(w) && !DIRECTORY_HOSTS.test(w) ? w : ''; }
function requirementsOf(r) {
  const out = [];
  if (r.requirements_text) {
    const t = String(r.requirements_text).replace(/\s+/g, ' ').trim();
    // short area names ("West Side", "Englewood") are service areas, not requirements
    out.push(/^[A-Za-z .'-]{3,30}$/.test(t) && !/\b(id|proof|appointment|referral|income|resident|register|bring|open|all|anyone|no)\b/i.test(t) ? `Service area: ${t}` : t);
  }
  if (r.requires_id === 1 || r.requires_id === true) out.push('ID required');
  if (r.requires_id === 0 || r.requires_id === false) out.push('No ID required');
  if (r.requires_residency === 1 || r.requires_residency === true) out.push('Residency requirement (ask which zips)');
  if (r.income_limit_fpl) out.push(`Income limit: ${r.income_limit_fpl}% of the federal poverty level`);
  if (r.requires_appointment === 1 || r.requires_appointment === true) out.push('Appointment required');
  // accepts_walkins is 1 on nearly every record (a default, not a verified fact): not copied
  return [...new Set(out)].join('; ').slice(0, 400);
}
const KIND = { food_pantry: 'food pantry', soup_kitchen: 'soup kitchen (hot meals)', food_bank: 'food bank', mobile_pantry: 'mobile pantry' };
function toRow(r) {
  const services = jsonList(r.services_offered_json).filter(s => s && s.length < 40).slice(0, 8);
  let notes = `${KIND[r.resource_type]} listed by Feed America (feedam.org, CC BY 4.0; record source: ${r.data_source || 'unknown'}` +
    `${r.last_verified_date ? `, last verified ${String(r.last_verified_date).slice(0, 10)}` : ''}; retrieved ${RETRIEVED}).`;
  notes = cap(notes);
  if (services.length) notes += ` Services: ${services.join(', ')}.`;
  if (r._geocoded) notes += ' Coordinates geocoded by Farecart from the listed address.';
  if (r.organization && r.organization.toLowerCase() !== String(r.name).toLowerCase()) notes += ` Run by ${r.organization}.`;
  const requires_id = r.requires_id === 1 || r.requires_id === true ? 'true' : r.requires_id === 0 || r.requires_id === false ? 'false' : '';
  return {
    name: tidyName(r.name),
    type: 'pantry',
    address: fullAddress(r),
    neighborhood: '',
    lat: (+r.lat).toFixed(6), lng: (+r.lng).toFixed(6),
    hours_text: hoursText(r.hours_json),
    accepts_ebt: '',
    requirements: requirementsOf(r),
    languages: jsonList(r.languages_offered).map(l => cap(l.toLowerCase())).filter(l => l && l !== 'English').join(';'),
    phone: phone(r.phone),
    website: website(r.website),
    source_url: `https://feedam.org/resource/${r.id}`,
    notes,
    source_kind: 'feedam',
    pantry_model: '',
    requires_snap: '',
    requires_id,
    feedam_id: String(r.id),
  };
}

// ---------- 4. dedupe against what we already have ----------
const ours = [
  ...parseCSV(readFileSync(resolve(here, 'locations.csv'), 'utf8')).map(r => ({ ...r, source_kind: 'curated' })),
  ...(existsSync(resolve(here, 'locations_citywide.csv')) ? parseCSV(readFileSync(resolve(here, 'locations_citywide.csv'), 'utf8')) : []),
].map(r => ({ ...r, lat: +r.lat, lng: +r.lng }));
const byAddr = new Map();
for (const o of ours) { const k = normAddress(o.address); if (!byAddr.has(k)) byAddr.set(k, []); byAddr.get(k).push(o); }
const pantries = ours.filter(o => o.type === 'pantry' || o.type === 'giveaway');

const matches = [], fresh = [];
const matchedOurs = new Set(), seenFeedam = new Set();
const stats = { by_type: {}, matched_by: {}, matched_source_kind: {}, dropped: {} };
const bump = (o, k) => { o[k] = (o[k] || 0) + 1; };
const areaOf = loadCommunityAreas();

// rows with hours and a verification first, so the best Feed America record wins a match
details.sort((a, b) => (b.hours_json ? 1 : 0) - (a.hours_json ? 1 : 0) || (b.verification_status === 'verified') - (a.verification_status === 'verified') || a.id - b.id);

for (const r of details) {
  bump(stats.by_type, r.resource_type);
  if (r._badCoords) { bump(stats.dropped, 'no usable coordinates'); continue; }
  if (r.is_active === 0 || r.is_active === false) { bump(stats.dropped, 'inactive'); continue; }
  const row = toRow(r);
  const k = normAddress(row.address);
  // 1) exact normalised address against any of our pantry/giveaway rows
  let hit = (byAddr.get(k) || []).find(o => o.type !== 'grocery');
  let how = hit ? 'address' : null;
  // 2) within 60 m with a similar name
  if (!hit) {
    hit = pantries.filter(o => o.lat && o.lng && haversineM(o, { lat: +row.lat, lng: +row.lng }) <= 60 && similarName(o.name, row.name))
      .sort((a, b) => haversineM(a, row) - haversineM(b, row))[0];
    how = hit ? 'distance+name' : null;
  }
  // 3) same house number + street name (suffix differs: "Jackson Ave" vs "Jackson Blvd") with a similar name
  if (!hit) {
    const sk = streetKey(row.address);
    hit = pantries.find(o => streetKey(o.address) === sk && similarName(o.name, row.name));
    how = hit ? 'street+name' : null;
  }
  if (hit) {
    const ok = `${hit.name}|${hit.address}`;
    if (matchedOurs.has(ok)) { bump(stats.dropped, 'second Feed America record for an already-matched row'); continue; }
    matchedOurs.add(ok);
    matches.push({ name: hit.name, address: hit.address, source_kind: hit.source_kind, feedam_id: row.feedam_id, feedam_name: row.name, feedam_address: row.address, matched_by: how, requires_id: row.requires_id });
    bump(stats.matched_by, how); bump(stats.matched_source_kind, hit.source_kind);
    continue;
  }
  // new row: also dedupe Feed America against itself
  // (Feed America aggregates several directories, so the same pantry often appears twice a door apart: 150 m here)
  const dupNew = fresh.find(f => normAddress(f.address) === k
    || (haversineM({ lat: +f.lat, lng: +f.lng }, { lat: +row.lat, lng: +row.lng }) <= 150 && similarName(f.name, row.name))
    || (streetKey(f.address) === streetKey(row.address) && similarName(f.name, row.name)));
  if (dupNew) { bump(stats.dropped, 'duplicate of another Feed America row'); continue; }
  const area = areaOf ? areaOf(+row.lat, +row.lng) : null;
  if (areaOf && !area) { bump(stats.dropped, 'outside Chicago community areas'); continue; }
  row.neighborhood = area ? area.name : '';
  fresh.push(row);
  seenFeedam.add(r.id);
}

fresh.sort((a, b) => a.name.localeCompare(b.name));
writeFileSync(OUT_CSV, toCSV(COLUMNS, fresh));
matches.sort((a, b) => a.name.localeCompare(b.name));
writeFileSync(MATCH_CSV, toCSV(['name','address','source_kind','feedam_id','feedam_name','feedam_address','matched_by','requires_id'], matches));

const freshByType = {};
for (const r of details) if (seenFeedam.has(r.id)) bump(freshByType, r.resource_type);
console.log(`\nChicago rows by Feed America resource_type:`, stats.by_type);
console.log(`Matched existing rows: ${matches.length}`, stats.matched_by, 'by our source_kind:', stats.matched_source_kind);
console.log(`New rows: ${fresh.length}`, freshByType, `(${fresh.filter(r => r.hours_text).length} with hours, ${fresh.filter(r => r.requirements).length} with requirements, ${fresh.filter(r => r.requires_id).length} with requires_id)`);
console.log('Dropped:', stats.dropped);
console.log(`Wrote ${OUT_CSV} and ${MATCH_CSV}. ${ATTRIBUTION}.`);
