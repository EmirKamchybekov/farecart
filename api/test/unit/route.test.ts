// GET /route end to end against the captured Transitous fixture, with fetch() stubbed
// for both Supabase (fares) and Transitous. Also covers the 502 + fallback path.
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { after, before, describe, it } from 'node:test';
import app from '../../src/app.js';
import { TRANSITOUS_USER_AGENT } from '../../src/lib/transitous.js';
import { FARES } from './fares.fixture.js';

const fixtureText = readFileSync(new URL('../fixtures/transitous-plan.json', import.meta.url), 'utf8');
const realFetch = globalThis.fetch;
let transitousMode: 'ok' | 'timeout' | 'http500' | 'garbage' = 'ok';
let lastTransitousRequest: { url: URL; userAgent: string | null } | null = null;

// Test bodies are loosely typed on purpose: we assert the wire shape, not the TS type.
// eslint-disable-next-line @typescript-eslint/no-explicit-any
const bodyOf = (res: Response): Promise<any> => res.json();

const json = (body: unknown, status = 200) =>
  new Response(typeof body === 'string' ? body : JSON.stringify(body), { status, headers: { 'content-type': 'application/json' } });

before(() => {
  process.env.SUPABASE_URL = 'https://stub.supabase.co';
  process.env.SUPABASE_ANON_KEY = 'stub-anon';
  globalThis.fetch = (async (input: string | URL | Request, init?: RequestInit) => {
    const url = new URL(typeof input === 'string' ? input : input instanceof URL ? input.href : input.url);
    if (url.hostname.endsWith('supabase.co') && url.pathname === '/rest/v1/fares') return json(FARES);
    if (url.hostname === 'api.transitous.org') {
      lastTransitousRequest = { url, userAgent: new Headers(init?.headers).get('user-agent') };
      switch (transitousMode) {
        case 'ok': return json(fixtureText);
        case 'http500': return json({ error: 'boom' }, 500);
        case 'garbage': return json({ hello: 'world' });
        case 'timeout': {
          const err = new Error('The operation was aborted due to timeout');
          err.name = 'TimeoutError';
          throw err;
        }
      }
    }
    throw new Error(`unexpected fetch ${url}`);
  }) as typeof fetch;
});
after(() => { globalThis.fetch = realFetch; });

const PATH = '/route?from_lat=41.8807&from_lng=-87.7262&to_lat=41.8819&to_lng=-87.6868';

describe('GET /route', () => {
  it('maps the fixture into itineraries with legs and CTA cost (rider=full)', async () => {
    transitousMode = 'ok';
    const res = await app.request(`${PATH}&rider=full`);
    assert.equal(res.status, 200);
    assert.equal(res.headers.get('cache-control'), 'public, max-age=30, s-maxage=30');
    assert.equal(lastTransitousRequest?.userAgent, TRANSITOUS_USER_AGENT);
    assert.equal(lastTransitousRequest?.url.searchParams.get('fromPlace'), '41.8807,-87.7262');
    assert.equal(lastTransitousRequest?.url.searchParams.get('numItineraries'), '3');
    assert.equal(lastTransitousRequest?.url.searchParams.has('time'), false);

    const body = await bodyOf(res);
    assert.deepEqual(body.origin, { lat: 41.8807, lng: -87.7262 });
    assert.deepEqual(body.destination, { lat: 41.8819, lng: -87.6868 });
    assert.equal(body.rider, 'full');
    assert.equal(body.itineraries.length, 3);
    assert.ok(body.fallback.apple.startsWith('maps://') && body.fallback.apple.includes('saddr='));
    assert.ok(body.fallback.google.includes('travelmode=transit') && body.fallback.google.includes('origin='));

    const it = body.itineraries[0];
    assert.match(it.id, /^[0-9a-f]{12}$/);
    assert.equal(it.duration_s, 1080);
    assert.equal(it.transfers, 0);
    assert.deepEqual(it.legs.map((l: { mode: string }) => l.mode), ['walk', 'bus', 'walk']);
    const bus = it.legs[1];
    assert.equal(bus.route_short_name, '20');
    assert.equal(bus.route_long_name, 'Madison');
    assert.equal(bus.headsign, 'Michigan');
    assert.equal(bus.agency_name, 'Chicago Transit Authority');
    assert.equal(bus.from.name, 'Madison & Pulaski');
    assert.equal(bus.to.name, 'Madison & Western');
    assert.equal(bus.from.time, '2026-10-16T01:27:00Z');
    assert.equal(bus.duration_s, 660);
    assert.equal(bus.route_color, '414145');
    assert.equal(bus.intermediate_stop_count, 13);
    assert.equal(bus.polyline.precision, 7);
    assert.equal(typeof bus.polyline.points, 'string');
    assert.deepEqual(it.cost, {
      rider_cents: 225, rider_formatted: '$2.25', full_cents: 225, full_formatted: '$2.25', savings_cents: 0, boardings: 1,
    });
  });

  it('prices the same trip for rider=reduced_access and student', async () => {
    transitousMode = 'ok';
    const access = await bodyOf(await app.request(`${PATH}&rider=reduced_access`));
    assert.deepEqual(access.itineraries[0].cost, {
      rider_cents: 110, rider_formatted: '$1.10', full_cents: 225, full_formatted: '$2.25', savings_cents: 115, boardings: 1,
    });
    const student = await bodyOf(await app.request(`${PATH}&rider=student`));
    assert.equal(student.itineraries[0].cost.rider_cents, 75);
    assert.equal(student.itineraries[0].cost.savings_cents, 150);
  });

  it('forwards depart_at and n to Transitous', async () => {
    transitousMode = 'ok';
    const res = await app.request(`${PATH}&depart_at=2026-10-16T09:30:00-05:00&n=2`);
    assert.equal(res.status, 200);
    assert.equal(lastTransitousRequest?.url.searchParams.get('time'), '2026-10-16T14:30:00.000Z');
    assert.equal(lastTransitousRequest?.url.searchParams.get('arriveBy'), 'false');
    assert.equal(lastTransitousRequest?.url.searchParams.get('numItineraries'), '2');
    const body = await bodyOf(res);
    assert.equal(body.depart_at, '2026-10-16T14:30:00.000Z');
    assert.equal(body.itineraries.length, 2);
  });

  it('rejects bad parameters with 400 details', async () => {
    for (const bad of ['/route', '/route?from_lat=91&from_lng=0&to_lat=0&to_lng=0', `${PATH}&rider=vip`, `${PATH}&depart_at=tomorrow`, `${PATH}&n=0`]) {
      const res = await app.request(bad);
      assert.equal(res.status, 400, bad);
      const body = await bodyOf(res);
      assert.equal(body.error.code, 'bad_request');
      assert.ok(body.error.details.length > 0);
    }
  });

  for (const mode of ['timeout', 'http500', 'garbage'] as const) {
    it(`returns 502 upstream_unavailable with fallback links when Transitous fails (${mode})`, async () => {
      transitousMode = mode;
      const res = await app.request(`${PATH}&rider=reduced_access`);
      assert.equal(res.status, 502);
      assert.equal(res.headers.get('cache-control'), 'no-store');
      const body = await bodyOf(res);
      assert.equal(body.error.code, 'upstream_unavailable');
      assert.equal(body.rider, 'reduced_access');
      assert.deepEqual(body.destination, { lat: 41.8819, lng: -87.6868 });
      assert.ok(body.fallback.apple.startsWith('maps://?daddr=41.8819%2C-87.6868'));
      assert.ok(body.fallback.google.startsWith('https://www.google.com/maps/dir/?api=1&destination=41.8819%2C-87.6868'));
    });
  }
});
