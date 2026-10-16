import { Hono } from 'hono';
import { z } from 'zod';
import { optionalEnv } from '../env.js';
import { ApiError, fetchJson, parseQuery } from '../lib/http.js';

const Query = z.object({
  stop_id: z.string().trim().regex(/^\d{1,10}$/, 'stop_id must be a numeric CTA bus stop id'),
  route: z.string().trim().regex(/^[A-Za-z0-9]{1,5}$/).optional(),
});

type CtaPrediction = {
  tmstmp: string; // "20261015 19:50"
  typ: 'A' | 'D';
  stpnm: string;
  stpid: string;
  vid: string;
  dstp?: number;
  rt: string;
  rtdir: string;
  des: string;
  prdtm: string; // "20261015 19:55"
  dly: boolean;
  prdctdn: string; // minutes, "DUE" or "DLY"
};

type CtaResponse = {
  'bustime-response': {
    prd?: CtaPrediction[];
    error?: Array<{ msg: string; stpid?: string; rt?: string }>;
  };
};

/** "20261015 19:55" (America/Chicago wall clock) -> "2026-10-15T19:55:00" */
function ctaLocalIso(ts: string): string | null {
  const m = /^(\d{4})(\d{2})(\d{2}) (\d{2}):(\d{2})$/.exec(ts);
  return m ? `${m[1]}-${m[2]}-${m[3]}T${m[4]}:${m[5]}:00` : null;
}

function countdown(s: string): number | null {
  if (s === 'DUE') return 0;
  const n = Number(s);
  return Number.isFinite(n) ? n : null;
}

export const arrivals = new Hono().get('/', async (c) => {
  const { stop_id, route } = parseQuery(c, Query);
  const key = optionalEnv('CTA_BUS_KEY');
  c.header('Cache-Control', 'public, max-age=20, s-maxage=20');

  if (!key) {
    return c.json({ available: false, reason: 'CTA_BUS_KEY not configured', stop_id, predictions: [] });
  }

  const url = new URL('http://www.ctabustracker.com/bustime/api/v3/getpredictions');
  url.searchParams.set('key', key);
  url.searchParams.set('stpid', stop_id);
  if (route) url.searchParams.set('rt', route);
  url.searchParams.set('format', 'json');

  const data = await fetchJson<CtaResponse>(url, 'CTA Bus Tracker', { timeoutMs: 6000 });
  const body = data['bustime-response'];
  const errors = body.error ?? [];
  const fatal = errors.find((e) => /api access key|invalid key|transaction limit/i.test(e.msg));
  if (fatal) {
    throw new ApiError(502, 'cta_error', fatal.msg);
  }

  const predictions = (body.prd ?? []).map((p) => ({
    route: p.rt,
    direction: p.rtdir,
    destination: p.des,
    vehicle_id: p.vid,
    type: p.typ === 'D' ? 'departure' : 'arrival',
    minutes: countdown(p.prdctdn),
    predicted_time_local: ctaLocalIso(p.prdtm),
    is_delayed: p.dly,
    distance_to_stop_ft: p.dstp ?? null,
  }));

  return c.json({
    available: true,
    stop_id,
    stop_name: body.prd?.[0]?.stpnm ?? null,
    timezone: 'America/Chicago',
    generated_at: new Date().toISOString(),
    notice: errors.map((e) => e.msg).join('; ') || null,
    predictions,
  });
});
