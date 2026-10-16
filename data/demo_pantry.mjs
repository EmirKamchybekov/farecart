#!/usr/bin/env node
// Farecart DEMO data for pantry inventory + visit scheduling (migration 0007).
// Creates, for ~12 curated West Side pantries:
//   - pantry_slots for the next 14 days (30-minute slots inside each pantry's
//     hours_text where it can be parsed, else weekday mornings 9-11am),
//     capacity 8-15, created_by='demo'
//   - pantry_inventory rows across 5-7 categories, mixed levels, source='demo'
//   - pantry_staff_codes (6 chars), written to data/demo_staff_codes.csv
// Everything here is demo data, not reports from the pantries. Idempotent: slots
// that already exist for the same (location, starts_at) are left alone (bookings
// survive), inventory is upserted, staff codes are reused from the CSV.
//
// Usage:  node data/demo_pantry.mjs              create / refresh
//         node data/demo_pantry.mjs --rotate     new staff codes (rewrites demo_staff_codes.csv)
//         node data/demo_pantry.mjs --reset      delete unbooked demo slots first, then recreate
//         node data/demo_pantry.mjs --dry-run    print the plan, write nothing

import { readFileSync, writeFileSync, existsSync } from 'node:fs';
import { resolve } from 'node:path';
import { randomInt } from 'node:crypto';
import { here, loadEnv, makeRest, parseCSV, toCSV, zonedToDate, dateParts } from './common.mjs';

const CODES_CSV = resolve(here, 'demo_staff_codes.csv');
const args = new Set(process.argv.slice(2));
const DRY_RUN = args.has('--dry-run');
const ROTATE = args.has('--rotate');
const RESET = args.has('--reset');

// Curated pantries (data/locations.csv names) that get demo slots + inventory.
const DEMO_PANTRIES = [
  'Legler Regional Library Food Pantry',
  'Keystone Baptist Church Food Pantry',
  'Above and Beyond Free Food Pantry',
  'Breakthrough Fresh Market Food Pantry',
  'Marillac St. Vincent Family Services Food Pantry',
  'Midwest Corps Community Center (Salvation Army) Food Pantry',
  'Harmony Community Cares Food Pantry',
  'St. Martin de Porres Food Pantry (St. Simon of Cyrene Parish)',
  'Circle Urban Ministries Food Pantry',
  'The Ark Church Food Pantry',
  'Mission of Our Lady of the Angels Food Pantry',
  'Pan de Vida Food Pantry (New Life Centers)',
];
const CATEGORIES = ['produce','dairy','protein','canned','bread','baby','water','other'];
const LEVELS = ['plenty','plenty','low','low','out'];
const NOTES = {
  produce: ['apples, onions, potatoes', 'greens and carrots', 'mixed fruit boxes'],
  dairy: ['milk and eggs', 'eggs only today', 'yogurt and cheese'],
  protein: ['frozen chicken', 'canned tuna and beans', 'ground turkey, limited'],
  canned: ['soup, vegetables, beans', 'pasta and sauce', ''],
  bread: ['sandwich bread and tortillas', 'bakery donations', ''],
  baby: ['formula, size 3-4 diapers', 'wipes only', 'no formula this week'],
  water: ['bottled water cases', '', ''],
  other: ['rice, cereal, oil', 'pet food', 'toiletries'],
};
const DAYS = ['Sun','Mon','Tue','Wed','Thu','Fri','Sat'];
const DAY_RE = '(Sunday|Monday|Tuesday|Wednesday|Thursday|Friday|Saturday|Sun|Mon|Tue|Wed|Thu|Fri|Sat)';
const dayIndex = s => DAYS.findIndex(d => d.toLowerCase() === s.slice(0, 3).toLowerCase());
const SLOT_MIN = 30;
const HORIZON_DAYS = 14;
const CODE_ALPHABET = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';

// ---------- deterministic pseudo-random per pantry so re-runs agree ----------
function hash(s) { let h = 2166136261; for (const c of s) { h ^= c.charCodeAt(0); h = Math.imul(h, 16777619) >>> 0; } return h; }
const pick = (arr, seed) => arr[hash(seed) % arr.length];
const between = (lo, hi, seed) => lo + (hash(seed) % (hi - lo + 1));
const newCode = () => Array.from({ length: 6 }, () => CODE_ALPHABET[randomInt(CODE_ALPHABET.length)]).join('');

// ---------- hours_text -> weekly rules ----------
// "1st & 3rd Sat 10am-12pm; Mon-Fri 12pm-3pm; Wed 2:30pm-5:30pm" ->
// [{days:[6], weeks:[1,3], start:600, end:720}, {days:[1..5], weeks:null, ...}, ...]
function toMin(h, m, ap) { h = +h % 12; if (ap.toLowerCase() === 'pm') h += 12; return h * 60 + (+(m || 0)); }
export function parseHours(text) {
  const rules = [];
  for (let seg of String(text || '').split(';')) {
    seg = seg.replace(/\([^)]*\)/g, ' ').trim();
    if (!seg || /\bmeals?\b/i.test(seg)) continue;               // hot-meal times are not pantry slots
    const t = seg.match(/(\d{1,2})(?::(\d{2}))?\s*(am|pm)\s*(?:-|–|to)\s*(\d{1,2})(?::(\d{2}))?\s*(am|pm)/i);
    if (!t) continue;
    const start = toMin(t[1], t[2], t[3]), end = toMin(t[4], t[5], t[6]);
    if (end <= start) continue;
    const head = seg.slice(0, t.index);
    const weeks = [...head.matchAll(/\b([1-5])(?:st|nd|rd|th)\b/g)].map(m => +m[1]);
    const expanded = head.replace(new RegExp(`\\b${DAY_RE}\\s*(?:-|–|to)\\s*${DAY_RE}\\b`, 'gi'), (m, a, b) => {
      const i = dayIndex(a), j = dayIndex(b);
      const out = []; for (let k = i; ; k = (k + 1) % 7) { out.push(DAYS[k]); if (k === j) break; }
      return out.join(' ');
    });
    const days = [...new Set([...expanded.matchAll(new RegExp(`\\b${DAY_RE}\\b`, 'gi'))].map(m => dayIndex(m[1])))];
    if (!days.length) continue;
    rules.push({ days, weeks: weeks.length ? weeks : null, start, end });
  }
  return rules;
}
const FALLBACK_RULES = [{ days: [1, 2, 3, 4, 5], weeks: null, start: 9 * 60, end: 11 * 60 }];

function slotsFor(name, rules, now) {
  const out = [];
  const today = dateParts(now);
  for (let i = 0; i <= HORIZON_DAYS; i++) {
    const day = dateParts(new Date(Date.UTC(today.y, today.m - 1, today.d + i, 12)));
    const weekOfMonth = Math.ceil(day.d / 7);
    for (const r of rules) {
      if (!r.days.includes(day.dow)) continue;
      if (r.weeks && !r.weeks.includes(weekOfMonth)) continue;
      for (let m = r.start; m + SLOT_MIN <= r.end; m += SLOT_MIN) {
        const starts = zonedToDate(day.y, day.m, day.d, Math.floor(m / 60), m % 60);
        const ends = zonedToDate(day.y, day.m, day.d, Math.floor((m + SLOT_MIN) / 60), (m + SLOT_MIN) % 60);
        if (ends <= now) continue;
        out.push({ starts_at: starts.toISOString(), ends_at: ends.toISOString(), capacity: between(8, 15, `${name}|${starts.toISOString()}`), notes: null, created_by: 'demo' });
      }
    }
  }
  return out;
}

function inventoryFor(name) {
  const n = between(5, 7, name + '|ncat');
  const order = [...CATEGORIES].sort((a, b) => hash(name + a) - hash(name + b)).slice(0, n);
  return order.map(category => {
    const level = pick(LEVELS, `${name}|${category}|level`);
    const note = level === 'out' ? null : (pick(NOTES[category], `${name}|${category}|note`) || null);
    return { category, level, note, source: 'demo' };
  });
}

async function main() {
  const env = loadEnv();
  const rest = DRY_RUN ? null : makeRest(env);
  const now = new Date();

  // Resolve curated pantry rows from the database (ids are needed for every table).
  const want = new Set(DEMO_PANTRIES);
  let locations;
  if (rest) {
    locations = (await rest(`locations?select=id,name,address,hours_text&source_kind=eq.curated&type=eq.pantry&is_active=eq.true&limit=200`)).filter(l => want.has(l.name));
  } else {
    locations = parseCSV(readFileSync(resolve(here, 'locations.csv'), 'utf8')).filter(r => r.type === 'pantry' && want.has(r.name)).map(r => ({ id: '(dry-run)', ...r }));
  }
  const missing = DEMO_PANTRIES.filter(n => !locations.some(l => l.name === n));
  if (missing.length) console.warn(`Not found in locations (skipped): ${missing.join('; ')}`);

  // Staff codes: reuse from CSV unless --rotate.
  const existingCodes = new Map();
  if (existsSync(CODES_CSV) && !ROTATE) for (const r of parseCSV(readFileSync(CODES_CSV, 'utf8'))) existingCodes.set(`${r.name}|${r.address}`, r);
  const codeRows = [];
  const used = new Set();
  for (const l of locations) {
    const prev = existingCodes.get(`${l.name}|${l.address}`);
    let code = prev?.code;
    while (!code || used.has(code)) code = newCode();
    used.add(code);
    codeRows.push({ name: l.name, address: l.address, code, contact_name: prev?.contact_name || 'Demo staff', contact_phone: prev?.contact_phone || '' });
  }

  let slotsPlanned = 0, slotsInserted = 0, slotsKept = 0, slotsDeleted = 0, invRows = 0, parsed = 0;
  for (const l of locations) {
    const rules = parseHours(l.hours_text);
    if (rules.length) parsed++;
    const slots = slotsFor(l.name, rules.length ? rules : FALLBACK_RULES, now);
    const inv = inventoryFor(l.name);
    slotsPlanned += slots.length; invRows += inv.length;
    console.log(`${l.name}\n  hours: ${l.hours_text || '(none)'} -> ${rules.length ? rules.map(r => `${r.weeks ? r.weeks.join('/') + ' ' : ''}${r.days.map(d => DAYS[d]).join('/')} ${r.start / 60}-${r.end / 60}h`).join(', ') : 'FALLBACK weekday 9-11am'}\n  ${slots.length} slots over ${HORIZON_DAYS} days; inventory: ${inv.map(i => `${i.category}=${i.level}`).join(', ')}`);
    if (DRY_RUN) continue;

    const code = codeRows.find(c => c.name === l.name);
    await rest('pantry_staff_codes?on_conflict=location_id', { method: 'POST', prefer: 'resolution=merge-duplicates,return=minimal',
      body: [{ location_id: l.id, code: code.code, contact_name: code.contact_name, contact_phone: code.contact_phone || null }] });

    if (RESET) {
      const gone = await rest(`pantry_slots?location_id=eq.${l.id}&created_by=eq.demo&booked=eq.0&select=id`, { method: 'DELETE', prefer: 'return=representation' });
      slotsDeleted += gone.length;
    }
    const have = new Set((await rest(`pantry_slots?location_id=eq.${l.id}&starts_at=gte.${encodeURIComponent(now.toISOString())}&select=starts_at&limit=1000`)).map(s => new Date(s.starts_at).toISOString()));
    const fresh = slots.filter(s => !have.has(s.starts_at)).map(s => ({ ...s, location_id: l.id }));
    slotsKept += slots.length - fresh.length;
    if (fresh.length) {
      await rest('pantry_slots', { method: 'POST', prefer: 'return=minimal', body: fresh });
      slotsInserted += fresh.length;
    }

    const reported_at = now.toISOString();
    await rest('pantry_inventory?on_conflict=location_id,category', { method: 'POST', prefer: 'resolution=merge-duplicates,return=minimal',
      body: inv.map(i => ({ ...i, location_id: l.id, reported_at, expires_at: new Date(now.getTime() + 24 * 3600 * 1000).toISOString() })) });
  }

  if (!DRY_RUN) {
    writeFileSync(CODES_CSV, toCSV(['name','address','code','contact_name','contact_phone'], codeRows));
    console.log(`\nWrote ${codeRows.length} demo staff codes to ${CODES_CSV}${ROTATE ? ' (rotated)' : ''}`);
  }
  console.log(`\n${locations.length} pantries (${parsed} with parseable hours), ${slotsPlanned} slots planned` +
    (DRY_RUN ? ' (dry run)' : `: ${slotsInserted} inserted, ${slotsKept} already existed, ${slotsDeleted} deleted (--reset); ${invRows} inventory rows upserted`));
}

main().catch(e => { console.error(e); process.exit(1); });
