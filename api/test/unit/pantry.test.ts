// GET /pantry/:id/availability with fetch() stubbed for Supabase (locations + pantry_availability RPC)
// and for the Feed America status endpoint.
import assert from 'node:assert/strict';
import { after, before, describe, it } from 'node:test';
import app from '../../src/app.js';
import { FEEDAM_ATTRIBUTION, FEEDAM_USER_AGENT } from '../../src/routes/pantry.js';

const realFetch = globalThis.fetch;
const LOC = 'ab79ab95-d3c3-48ab-925b-4b4534e3ef3f';
const LINKED = '69a04a7c-58b2-4be3-b4df-9e33970359cf';
const FAIL_500 = '11111111-1111-4111-8111-111111111111';
const FAIL_TIMEOUT = '22222222-2222-4222-8222-222222222222';
const FAIL_GARBAGE = '33333333-3333-4333-8333-333333333333';
/** feedam_id -> how the stubbed status endpoint behaves */
const FEEDAM_MODE: Record<number, 'ok' | 'http500' | 'timeout' | 'garbage'> = { 5050: 'ok', 5051: 'http500', 5052: 'timeout', 5053: 'garbage' };
let feedamCalls = 0;
let lastFeedamUserAgent: string | null = null;

// eslint-disable-next-line @typescript-eslint/no-explicit-any
const bodyOf = (res: Response): Promise<any> => res.json();
const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { 'content-type': 'application/json' } });

const AVAILABILITY = {
  location_id: LOC,
  inventory: [
    { id: 'i1', category: 'produce', level: 'plenty', note: 'apples', reported_at: '2026-10-16T03:00:00+00:00', expires_at: '2026-10-17T03:00:00+00:00', source: 'demo' },
    { id: 'i2', category: 'dairy', level: 'out', note: null, reported_at: '2026-10-16T03:00:00+00:00', expires_at: '2026-10-17T03:00:00+00:00', source: 'staff' },
  ],
  slots: [
    { id: 's1', starts_at: '2026-10-18T18:00:00+00:00', ends_at: '2026-10-18T18:30:00+00:00', capacity: 13, booked: 2, remaining: 11, notes: null },
  ],
  staff_updated_at: '2026-10-16T03:39:20+00:00',
};

before(() => {
  process.env.SUPABASE_URL = 'https://stub.supabase.co';
  process.env.SUPABASE_ANON_KEY = 'stub-anon';
  globalThis.fetch = (async (input: string | URL | Request, init?: RequestInit) => {
    const url = new URL(typeof input === 'string' ? input : input instanceof URL ? input.href : input.url);
    if (url.hostname.endsWith('supabase.co')) {
      if (url.pathname === '/rest/v1/locations') {
        const id = url.searchParams.get('id')?.replace('eq.', '');
        if (id === LOC) return json([{ id: LOC, name: 'Legler Regional Library Food Pantry', type: 'pantry', feedam_id: null }]);
        if (id === LINKED) return json([{ id: LINKED, name: 'Keystone Baptist Church Food Pantry', type: 'pantry', feedam_id: 5050 }]);
        if (id === FAIL_500) return json([{ id, name: 'Fails 500', type: 'pantry', feedam_id: 5051 }]);
        if (id === FAIL_TIMEOUT) return json([{ id, name: 'Fails timeout', type: 'pantry', feedam_id: 5052 }]);
        if (id === FAIL_GARBAGE) return json([{ id, name: 'Fails garbage', type: 'pantry', feedam_id: 5053 }]);
        return json([]);
      }
      if (url.pathname === '/rest/v1/rpc/pantry_availability') {
        const args = JSON.parse(String(init?.body));
        return json({ ...AVAILABILITY, location_id: args.p_location_id });
      }
    }
    const status = url.hostname === 'feedam.org' ? url.pathname.match(/^\/api\/resources\/(\d+)\/status$/) : null;
    if (status) {
      const feedamId = Number(status[1]);
      feedamCalls++;
      lastFeedamUserAgent = new Headers(init?.headers).get('user-agent');
      switch (FEEDAM_MODE[feedamId]) {
        case 'ok': return json({ id: feedamId, phone_valid: true, phone_formatted: '(872) 444-8260', hours_status: 'open', days_since_verified: 12, confidence: 'medium' });
        case 'http500': return json({ error: 'boom' }, 500);
        case 'garbage': return json({ hello: 'world' });
        case 'timeout': { const err = new Error('timeout'); err.name = 'TimeoutError'; throw err; }
        default: return json({ error: 'unknown id' }, 404);
      }
    }
    throw new Error(`unexpected fetch ${url}`);
  }) as typeof fetch;
});
after(() => { globalThis.fetch = realFetch; });

describe('GET /pantry/:id/availability', () => {
  it('returns inventory, slots with remaining and staff_updated_at; feedam null when unlinked', async () => {
    const res = await app.request(`/pantry/${LOC}/availability`);
    assert.equal(res.status, 200);
    assert.equal(res.headers.get('cache-control'), 'public, max-age=30, s-maxage=30');
    assert.equal(res.headers.get('access-control-allow-origin'), '*');
    const body = await bodyOf(res);
    assert.deepEqual(body.location, { id: LOC, name: 'Legler Regional Library Food Pantry', type: 'pantry', feedam_id: null });
    assert.equal(body.inventory.length, 2);
    assert.equal(body.inventory[0].level, 'plenty');
    assert.deepEqual(body.slots[0], AVAILABILITY.slots[0]);
    assert.equal(body.staff_updated_at, AVAILABILITY.staff_updated_at);
    assert.equal(body.feedam, null);
  });

  it('merges Feed America status for a linked pantry, with attribution and our User-Agent', async () => {
    feedamCalls = 0;
    const body = await bodyOf(await app.request(`/pantry/${LINKED}/availability`));
    assert.equal(body.location.feedam_id, 5050);
    assert.deepEqual(body.feedam, {
      id: 5050, hours_status: 'open', confidence: 'medium', days_since_verified: 12, phone_valid: true,
      source: 'feedam', attribution: FEEDAM_ATTRIBUTION, url: 'https://feedam.org/resource/5050',
    });
    assert.equal(lastFeedamUserAgent, FEEDAM_USER_AGENT);
    // second call within 10 minutes is served from the in-process cache (rate limit: 10k/day)
    await app.request(`/pantry/${LINKED}/availability`);
    assert.equal(feedamCalls, 1);
  });

  it('404s an unknown location and 400s a non-uuid id', async () => {
    let res = await app.request('/pantry/00000000-0000-4000-8000-000000000000/availability');
    assert.equal(res.status, 404);
    assert.equal((await bodyOf(res)).error.code, 'not_found');
    res = await app.request('/pantry/nope/availability');
    assert.equal(res.status, 400);
    assert.equal((await bodyOf(res)).error.code, 'bad_request');
  });
});

describe('GET /pantry/:id/availability when Feed America fails', () => {
  // Each failure mode uses its own linked location / feedam id so the 10-minute status cache cannot mask it.
  for (const [mode, locId, feedamId] of [['http500', FAIL_500, 5051], ['timeout', FAIL_TIMEOUT, 5052], ['garbage', FAIL_GARBAGE, 5053]] as const) {
    it(`still returns 200 with feedam null (${mode})`, async () => {
      const res = await app.request(`/pantry/${locId}/availability`);
      assert.equal(res.status, 200);
      const body = await bodyOf(res);
      assert.equal(body.location.feedam_id, feedamId);
      assert.equal(body.feedam, null);
      assert.equal(body.slots.length, 1);
    });
  }
});
