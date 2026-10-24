#!/usr/bin/env node
// Demo stock for one pantry while recording the app video (source='demo', not a report from the pantry).
// Refreshes reported_at so the app shows it as just posted; rows expire 24h after the last run.
//
// Usage:  node data/video_stock.mjs            post / refresh
//         node data/video_stock.mjs --remove   delete this demo stock

import { loadEnv } from './common.mjs';

const LOCATION_ID = 'fe7b920e-17c2-48e8-af6e-1c13196ad8e5'; // Garfield Park Community Worship Center
const STOCK = [
  { category: 'produce', level: 'plenty', note: 'potatoes, onions, apples' },
  { category: 'canned',  level: 'plenty', note: 'green beans, corn, soup' },
  { category: 'bread',   level: 'plenty', note: 'sandwich bread' },
  { category: 'other',   level: 'plenty', note: 'rice, pasta, cereal' },
  { category: 'protein', level: 'low',    note: 'frozen chicken, limited' },
  { category: 'dairy',   level: 'low',    note: 'milk' },
  { category: 'baby',    level: 'out',    note: '' },
];

const env = loadEnv();
const headers = { apikey: env.SUPABASE_SERVICE_ROLE_KEY, Authorization: `Bearer ${env.SUPABASE_SERVICE_ROLE_KEY}`, 'Content-Type': 'application/json' };
const base = `${env.SUPABASE_URL}/rest/v1/pantry_inventory`;

if (process.argv.includes('--remove')) {
  const r = await fetch(`${base}?location_id=eq.${LOCATION_ID}&source=eq.demo`, { method: 'DELETE', headers });
  console.log(r.ok ? 'Removed demo stock' : `Failed: ${r.status} ${await r.text()}`);
} else {
  const now = new Date();
  const body = STOCK.map(s => ({ ...s, location_id: LOCATION_ID, source: 'demo', reported_at: now.toISOString(),
    expires_at: new Date(now.getTime() + 24 * 3600 * 1000).toISOString() }));
  const r = await fetch(`${base}?on_conflict=location_id,category`, { method: 'POST',
    headers: { ...headers, Prefer: 'resolution=merge-duplicates,return=minimal' }, body: JSON.stringify(body) });
  console.log(r.ok ? `Posted ${body.length} stock rows at ${now.toLocaleString()}` : `Failed: ${r.status} ${await r.text()}`);
}
