// Smoke tests: hit every route on a running server.
//   BASE_URL=http://localhost:3000 node test/smoke.mjs   -> test an already-running server
//   node test/smoke.mjs                                  -> spawns `tsx src/dev.ts` on a free port, tests, stops it
import { spawn } from 'node:child_process';
import { setTimeout as sleep } from 'node:timers/promises';
import { fileURLToPath } from 'node:url';
import { dirname, resolve } from 'node:path';

const root = resolve(dirname(fileURLToPath(import.meta.url)), '..');
let base = process.env.BASE_URL?.replace(/\/+$/, '');
let child;

if (!base) {
  const port = 3000 + Math.floor(Math.random() * 2000);
  base = `http://127.0.0.1:${port}`;
  child = spawn(process.execPath, [resolve(root, 'node_modules/tsx/dist/cli.mjs'), 'src/dev.ts'], {
    cwd: root,
    env: { ...process.env, PORT: String(port) },
    stdio: ['ignore', 'pipe', 'inherit'],
  });
  child.stdout.on('data', (d) => process.stderr.write(`[server] ${d}`));
  const deadline = Date.now() + 20_000;
  let up = false;
  while (Date.now() < deadline) {
    try {
      const r = await fetch(`${base}/health`);
      if (r.ok) { up = true; break; }
    } catch {}
    await sleep(250);
  }
  if (!up) { child.kill(); console.error('server did not start'); process.exit(1); }
}

let failures = 0;
const trunc = (s, n = 320) => (s.length > n ? s.slice(0, n) + '…' : s);

async function check(name, path, expect) {
  const url = `${base}${path}`;
  let status, body, headers;
  try {
    const res = await fetch(url);
    status = res.status;
    headers = res.headers;
    const text = await res.text();
    try { body = JSON.parse(text); } catch { body = text; }
  } catch (err) {
    failures++;
    console.log(`FAIL ${name}: ${path} -> ${err.message}`);
    return;
  }
  const problems = [];
  if (expect.status !== undefined && status !== expect.status) problems.push(`status ${status} != ${expect.status}`);
  if (headers.get('content-type')?.includes('application/json') !== true) problems.push('not JSON');
  if (expect.cache && !(headers.get('cache-control') ?? '').includes(expect.cache)) problems.push(`cache-control "${headers.get('cache-control')}" lacks ${expect.cache}`);
  if (expect.cors && headers.get('access-control-allow-origin') !== '*') problems.push('missing CORS header');
  if (expect.body) {
    try { const msg = expect.body(body); if (msg) problems.push(msg); } catch (e) { problems.push(`assert threw: ${e.message}`); }
  }
  const ok = problems.length === 0;
  if (!ok) failures++;
  console.log(`${ok ? 'PASS' : 'FAIL'} ${name}: GET ${path} -> ${status}${ok ? '' : '  [' + problems.join('; ') + ']'}`);
  console.log(`     ${trunc(JSON.stringify(body))}`);
}

const near = 'lat=41.8807&lng=-87.7262';

await check('index', '/', { status: 200, cors: true, body: (b) => (Array.isArray(b.routes) && b.routes.length >= 8 && b.routes.some((r) => r.path === '/route') ? '' : 'routes list missing /route') });
await check('health', '/health', { status: 200, body: (b) => (b.ok === true ? '' : 'ok!=true') });
await check('health deep', '/health?deep=1', { status: 200, body: (b) => (b.supabase?.ok === true ? '' : 'supabase ping failed') });
await check('nearby', `/nearby?${near}&types=grocery,pantry&limit=25&radius_m=8000`, {
  status: 200, cors: true,
  body: (b) => {
    if (!Array.isArray(b.locations)) return 'locations not array';
    if (b.count !== b.locations.length) return 'count mismatch';
    for (const l of b.locations) {
      if (typeof l.distance_miles !== 'number' || !l.directions?.apple?.startsWith('maps://') || !l.directions?.google?.includes('travelmode=transit')) return 'row shape wrong';
    }
    return '';
  },
});
await check('nearby default types', `/nearby?${near}`, { status: 200, body: (b) => (b.types?.length === 3 ? '' : 'default types') });
await check('nearby bad lat', '/nearby?lat=abc&lng=-87.7', { status: 400, body: (b) => (b.error?.code === 'bad_request' && b.error?.details?.length ? '' : 'error shape') });
await check('nearby bad type', `/nearby?${near}&types=bar`, { status: 400, body: (b) => (b.error?.code === 'bad_request' ? '' : 'error shape') });
await check('geocode neighborhood', '/geocode?q=Austin', { status: 200, cors: true, body: (b) => (b.source === 'neighborhood' && b.label.includes('Austin') ? '' : 'expected neighborhood hit') });
await check('geocode alias', '/geocode?q=little%20village,%20chicago', { status: 200, body: (b) => (b.source === 'neighborhood' && b.label.startsWith('South Lawndale') ? '' : 'alias miss') });
await check('geocode census', '/geocode?q=4000%20W%20Madison%20St', { status: 200, body: (b) => (b.source === 'census' && Math.abs(b.lat - 41.8808) < 0.01 && Math.abs(b.lng + 87.7257) < 0.01 ? '' : `unexpected ${b.source} ${b.lat},${b.lng}`) });
await check('geocode nominatim fallback', '/geocode?q=Garfield%20Park%20Conservatory', { status: 200, body: (b) => (['census', 'nominatim'].includes(b.source) && b.lat > 41.6 && b.lat < 42.05 ? '' : 'no chicago hit') });
await check('geocode not found', '/geocode?q=zzzzqqqq%20nowhere%20street', { status: 404, body: (b) => (b.error?.code === 'not_found' ? '' : 'error shape') });
await check('geocode too short', '/geocode?q=a', { status: 400 });
await check('fares full', '/fares', { status: 200, cache: 'max-age=600', cors: true, body: (b) => (b.rider === 'full' && b.bus.price_cents === 225 && b.train.price_cents === 250 && b.bus.savings_cents === 0 && b.bus.transfer_cents === 0 && b.bus.transfer_window_min === 120 && b.bus.max_transfers === 2 && b.transfer_rules?.max_transfers === 2 ? '' : 'full fare values / transfer rules') });
await check('fares reduced_access', '/fares?rider=reduced_access', { status: 200, cache: 'max-age=600', body: (b) => (b.bus.price_cents === 110 && b.bus.formatted === '$1.10' && b.bus.savings_cents === 115 && b.train.price_cents === 125 ? '' : 'access fare values') });
await check('fares student', '/fares?rider=student', { status: 200, body: (b) => (b.bus.price_cents === 75 && b.train.price_cents === 75 ? '' : 'student fare values') });
await check('fares bad rider', '/fares?rider=vip', { status: 400 });
await check('eligibility snap', '/eligibility?snap=true&student=false', { status: 200, cache: 'max-age=600', body: (b) => (b.eligible && b.best.program_key === 'access' && b.best.bus.price_cents === 110 && b.message.includes('$1.10 instead of $2.25') && b.signup_url && b.phone ? '' : 'access eligibility') });
await check('eligibility student', '/eligibility?snap=false&student=true', { status: 200, body: (b) => (b.best.program_key === 'student' && b.best.bus.price_cents === 75 && b.message.includes('$0.75') ? '' : 'student eligibility') });
await check('eligibility both', '/eligibility?snap=true&student=true', { status: 200, body: (b) => (b.programs.length === 2 && b.best.program_key === 'student' && b.message.includes('$1.10') ? '' : 'both programs') });
await check('eligibility none', '/eligibility?snap=false&student=false', { status: 200, body: (b) => (b.eligible === false && b.best.bus.price_cents === 225 && /SNAP/.test(b.note) ? '' : 'none case') });
await check('eligibility bad', '/eligibility?snap=maybe', { status: 400 });
await check('arrivals', '/arrivals?stop_id=1234', { status: 200, body: (b) => (typeof b.available === 'boolean' && (b.available || b.reason === 'CTA_BUS_KEY not configured') ? '' : 'stub shape') });
await check('arrivals bad', '/arrivals?stop_id=abc', { status: 400 });
// ---- /route: live Transitous. Madison & Pulaski -> Madison & Western (CTA bus 20 corridor).
const trip = 'from_lat=41.8807&from_lng=-87.7262&to_lat=41.8819&to_lng=-87.6868';
const legLine = (l) => l.mode === 'walk'
  ? `walk ${Math.round(l.duration_s / 60)}m -> ${l.to.name}`
  : `${l.mode} ${l.route_short_name ?? '?'} (${l.agency_name ?? 'n/a'}) ${l.from.name} -> ${l.to.name}, ${l.intermediate_stop_count} stops, ${Math.round(l.duration_s / 60)}m, polyline p${l.polyline?.precision}`;
function routeShape(expectedRider) {
  return (b) => {
    if (b.rider !== expectedRider) return `rider ${b.rider}`;
    if (!Array.isArray(b.itineraries) || b.itineraries.length === 0) return 'no itineraries';
    if (!b.fallback?.apple?.startsWith('maps://') || !b.fallback?.google?.includes('travelmode=transit')) return 'fallback links';
    for (const it of b.itineraries) {
      if (!/^[0-9a-f]{12}$/.test(it.id) || typeof it.duration_s !== 'number' || !Array.isArray(it.legs) || it.legs.length === 0) return 'itinerary shape';
      for (const l of it.legs) {
        if (!['walk', 'bus', 'train', 'other'].includes(l.mode)) return `leg mode ${l.mode}`;
        if (l.polyline && ![5, 7].includes(l.polyline.precision)) return 'polyline precision';
      }
      const c = it.cost;
      if (typeof c?.rider_cents !== 'number' || typeof c.full_cents !== 'number' || c.savings_cents !== Math.max(0, c.full_cents - c.rider_cents)) return 'cost shape';
      if (c.boardings !== it.legs.filter((l) => l.mode !== 'walk').length) return 'boardings count';
      const ctaOnly = it.legs.every((l) => l.mode === 'walk' || /Chicago Transit Authority/.test(l.agency_name ?? ''));
      if (ctaOnly && c.note) return 'unexpected note';
      if (ctaOnly && c.boardings > 0 && c.full_cents < 225) return 'full cost too low';
      if (expectedRider === 'reduced_access' && ctaOnly && c.boardings > 0 && c.rider_cents >= c.full_cents) return 'no discount applied';
      if (expectedRider === 'full' && c.rider_cents !== c.full_cents) return 'full rider should pay full';
    }
    return '';
  };
}
function printRoute(b) {
  if (!Array.isArray(b?.itineraries)) return;
  console.log(`     ${b.itineraries.length} itinerar${b.itineraries.length === 1 ? 'y' : 'ies'} for rider=${b.rider}`);
  b.itineraries.forEach((it, i) => {
    const c = it.cost;
    console.log(`     [${i + 1}] ${it.start_time} -> ${it.end_time}, ${Math.round(it.duration_s / 60)} min, ${it.transfers} transfer(s), ${c.boardings} boarding(s)`);
    for (const l of it.legs) console.log(`         - ${legLine(l)}`);
    console.log(`         cost: ${c.rider_formatted} for ${b.rider} (full ${c.full_formatted}, saves $${(c.savings_cents / 100).toFixed(2)})${c.note ? ' NOTE: ' + c.note : ''}`);
  });
}
for (const rider of ['reduced_access', 'full']) {
  const url = `${base}/route?${trip}&rider=${rider}`;
  let res, body;
  try { res = await fetch(url); body = await res.json(); } catch (err) { failures++; console.log(`FAIL route ${rider}: ${err.message}`); continue; }
  if (res.status === 502 && body.error?.code === 'upstream_unavailable') {
    // Transitous has no SLA: degrade like the clients do, but still require the fallback links.
    const okFallback = body.fallback?.apple?.startsWith('maps://') && body.fallback?.google?.includes('travelmode=transit');
    if (!okFallback) failures++;
    console.log(`${okFallback ? 'WARN' : 'FAIL'} route ${rider}: Transitous unavailable (${body.error.message}); fallback links ${okFallback ? 'present' : 'MISSING'}`);
    continue;
  }
  const problems = [];
  if (res.status !== 200) problems.push(`status ${res.status}`);
  if (!(res.headers.get('cache-control') ?? '').includes('max-age=30')) problems.push(`cache-control "${res.headers.get('cache-control')}"`);
  if (res.headers.get('access-control-allow-origin') !== '*') problems.push('missing CORS header');
  const msg = routeShape(rider)(body);
  if (msg) problems.push(msg);
  if (problems.length) failures++;
  console.log(`${problems.length ? 'FAIL' : 'PASS'} route ${rider}: GET /route?${trip}&rider=${rider} -> ${res.status}${problems.length ? '  [' + problems.join('; ') + ']' : ''}`);
  printRoute(body);
}
await check('route bad params', '/route?from_lat=41.88&from_lng=-87.72', { status: 400, body: (b) => (b.error?.code === 'bad_request' && b.error?.details?.length ? '' : 'error shape') });
await check('route bad rider', `/route?${trip}&rider=vip`, { status: 400 });
await check('route bad depart_at', `/route?${trip}&depart_at=tomorrow`, { status: 400 });

await check('404', '/nope', { status: 404, body: (b) => (b.error?.code === 'not_found' ? '' : 'error shape') });

if (child) child.kill();
console.log(failures ? `\n${failures} check(s) failed` : '\nAll smoke checks passed');
process.exit(failures ? 1 : 0);
