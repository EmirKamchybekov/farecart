// Shared helpers for the data scripts (feedam.mjs, demo_pantry.mjs).
// seed.mjs and build_citywide.mjs keep their own copies on purpose: they
// predate this file and are run on their own.
import { readFileSync, existsSync } from 'node:fs';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

export const here = dirname(fileURLToPath(import.meta.url));
export const ENV_FILE = resolve(here, '..', '.env.local');
export const CHICAGO = { latMin: 41.64, latMax: 42.03, lngMin: -87.95, lngMax: -87.52 };
export const sleep = ms => new Promise(r => setTimeout(r, ms));
export const inChicago = (lat, lng) => lat >= CHICAGO.latMin && lat <= CHICAGO.latMax && lng >= CHICAGO.lngMin && lng <= CHICAGO.lngMax;

// ---------- env ----------
export function loadEnv(file = ENV_FILE) {
  const env = { ...process.env };
  if (existsSync(file)) {
    for (const line of readFileSync(file, 'utf8').split('\n')) {
      const m = line.match(/^\s*([A-Z0-9_]+)\s*=\s*(.*)\s*$/);
      if (m && !(m[1] in process.env)) env[m[1]] = m[2].replace(/^["']|["']$/g, '');
    }
  }
  return env;
}

// ---------- CSV ----------
export function parseCSV(text) {
  const rows = [];
  let row = [], field = '', inQ = false;
  for (let i = 0; i < text.length; i++) {
    const c = text[i];
    if (inQ) {
      if (c === '"') { if (text[i + 1] === '"') { field += '"'; i++; } else inQ = false; } else field += c;
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
export const csvField = v => { const s = v == null ? '' : String(v); return /[",\n\r]/.test(s) ? '"' + s.replace(/"/g, '""') + '"' : s; };
export const toCSV = (cols, rows) => [cols.join(','), ...rows.map(r => cols.map(c => csvField(r[c])).join(','))].join('\n') + '\n';

// ---------- geometry / matching (same rules as build_citywide.mjs) ----------
export function haversineM(a, b) {
  const R = 6371000, toR = d => d * Math.PI / 180;
  const dLat = toR(b.lat - a.lat), dLng = toR(b.lng - a.lng);
  const s = Math.sin(dLat / 2) ** 2 + Math.cos(toR(a.lat)) * Math.cos(toR(b.lat)) * Math.sin(dLng / 2) ** 2;
  return 2 * R * Math.asin(Math.sqrt(s));
}
const STREET_ABBR = { street: 'st', avenue: 'ave', av: 'ave', boulevard: 'blvd', road: 'rd', drive: 'dr', place: 'pl', court: 'ct', parkway: 'pkwy', lane: 'ln', terrace: 'ter', highway: 'hwy', north: 'n', south: 's', east: 'e', west: 'w', 'n.': 'n', 's.': 's', 'e.': 'e', 'w.': 'w', 'st.': 'st', 'ave.': 'ave', 'blvd.': 'blvd', 'rd.': 'rd', 'dr.': 'dr', saint: 'st' };
/** Normalised street-address key: "1234 w madison st" */
export function normAddress(address) {
  let a = String(address || '').toLowerCase();
  a = a.split(/,\s*chicago\b/)[0].split(/\bchicago\b/)[0];
  a = a.replace(/\b(suite|ste|unit|apt|fl|floor|rm|room)\.?\s*[#\w-]+/g, ' ').replace(/#\s*\w+/g, ' ');
  a = a.replace(/[.,]/g, ' ').replace(/[^a-z0-9\s]/g, ' ');
  const toks = a.split(/\s+/).filter(Boolean).map(t => STREET_ABBR[t] || t);
  return toks.map(t => t.replace(/^(\d+)(st|nd|rd|th)$/, '$1')).join(' ').trim();
}
const STOP = new Set(['the','of','and','a','at','in','food','pantry','foods','market','store','inc','church','parish','center','community','program','ministry','ministries','chicago','mission','services','st','saint','fresh']);
const nameTokens = n => new Set(String(n).toLowerCase().replace(/[^a-z0-9\s]/g, ' ').split(/\s+/).filter(t => t && !STOP.has(t) && t.length > 1));
export function similarName(a, b) {
  const A = nameTokens(a), B = nameTokens(b);
  if (!A.size || !B.size) return String(a).toLowerCase().trim() === String(b).toLowerCase().trim();
  let inter = 0; for (const t of A) if (B.has(t)) inter++;
  const j = inter / (A.size + B.size - inter);
  return j >= 0.5 || (inter >= 1 && Math.min(A.size, B.size) <= 2 && inter === Math.min(A.size, B.size));
}

// ---------- community areas (data/raw/chicago_community_areas.geojson) ----------
function titleCase(s) {
  return s.toLowerCase().replace(/(^|[\s\-/("'])([a-z])/g, (m, p, c) => p + c.toUpperCase())
    .replace(/\b(Of|And|De|La|El|Y|Del|Los|Las)\b/g, w => w.toLowerCase()).replace(/^([a-z])/, c => c.toUpperCase())
    .replace(/\bMckinley\b/g, 'McKinley');
}
function pointInRing(x, y, ring) {
  let inside = false;
  for (let i = 0, j = ring.length - 1; i < ring.length; j = i++) {
    const xi = ring[i][0], yi = ring[i][1], xj = ring[j][0], yj = ring[j][1];
    if ((yi > y) !== (yj > y) && x < (xj - xi) * (y - yi) / (yj - yi) + xi) inside = !inside;
  }
  return inside;
}
export function loadCommunityAreas(file = resolve(here, 'raw', 'chicago_community_areas.geojson')) {
  if (!existsSync(file)) return null;
  const gj = JSON.parse(readFileSync(file, 'utf8'));
  const areas = gj.features.map(f => ({ name: titleCase(f.properties.community), num: +f.properties.area_numbe, polys: f.geometry.type === 'Polygon' ? [f.geometry.coordinates] : f.geometry.coordinates }));
  return (lat, lng) => {
    for (const a of areas) for (const poly of a.polys) {
      if (pointInRing(lng, lat, poly[0]) && !poly.slice(1).some(h => pointInRing(lng, lat, h))) return a;
    }
    return null;
  };
}

// ---------- PostgREST with the service role key ----------
export function makeRest(env) {
  const url = env.SUPABASE_URL, key = env.SUPABASE_SERVICE_ROLE_KEY;
  if (!url || !key) throw new Error('Missing SUPABASE_URL / SUPABASE_SERVICE_ROLE_KEY in ../.env.local');
  return async function rest(path, { method = 'GET', body, prefer } = {}) {
    const headers = { apikey: key, Authorization: `Bearer ${key}`, 'Content-Type': 'application/json', Accept: 'application/json' };
    if (prefer) headers.Prefer = prefer;
    const res = await fetch(`${url}/rest/v1/${path}`, { method, headers, body: body ? JSON.stringify(body) : undefined });
    const text = await res.text();
    if (!res.ok) throw new Error(`${method} ${path} -> ${res.status} ${text}`);
    return text ? JSON.parse(text) : null;
  };
}

// ---------- time zone ----------
export const CHICAGO_TZ = 'America/Chicago';
function tzParts(date, tz) {
  const f = new Intl.DateTimeFormat('en-US', { timeZone: tz, hourCycle: 'h23', year: 'numeric', month: '2-digit', day: '2-digit', hour: '2-digit', minute: '2-digit', second: '2-digit', weekday: 'short' });
  const o = {};
  for (const p of f.formatToParts(date)) o[p.type] = p.value;
  return { y: +o.year, m: +o.month, d: +o.day, hh: +o.hour % 24, mm: +o.minute, ss: +o.second, weekday: o.weekday };
}
function tzOffsetMs(date, tz) {
  const p = tzParts(date, tz);
  return Date.UTC(p.y, p.m - 1, p.d, p.hh, p.mm, p.ss) - date.getTime();
}
/** Local wall-clock time in `tz` -> Date (UTC instant). DST-safe for the hours pantries keep. */
export function zonedToDate(y, m, d, hh, mm, tz = CHICAGO_TZ) {
  const guess = Date.UTC(y, m - 1, d, hh, mm);
  let off = tzOffsetMs(new Date(guess), tz);
  let utc = guess - off;
  const off2 = tzOffsetMs(new Date(utc), tz);
  if (off2 !== off) utc = guess - off2;
  return new Date(utc);
}
/** Calendar date (y, m, d, weekday 0=Sun) of an instant in `tz`. */
export function dateParts(date, tz = CHICAGO_TZ) {
  const p = tzParts(date, tz);
  return { y: p.y, m: p.m, d: p.d, dow: ['Sun','Mon','Tue','Wed','Thu','Fri','Sat'].indexOf(p.weekday) };
}
