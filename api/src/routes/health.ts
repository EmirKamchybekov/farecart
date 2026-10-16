import { Hono } from 'hono';
import { z } from 'zod';
import { optionalEnv } from '../env.js';
import { parseQuery } from '../lib/http.js';
import { sbSelect } from '../lib/supabase.js';

const Query = z.object({
  deep: z.enum(['1', 'true']).optional(),
});

export const health = new Hono().get('/', async (c) => {
  const { deep } = parseQuery(c, Query);
  const body: Record<string, unknown> = {
    ok: true,
    service: 'farecart-api',
    time: new Date().toISOString(),
    env: {
      supabase_url: Boolean(optionalEnv('SUPABASE_URL')),
      supabase_anon_key: Boolean(optionalEnv('SUPABASE_ANON_KEY')),
      cta_bus_key: Boolean(optionalEnv('CTA_BUS_KEY')),
    },
  };
  if (deep) {
    const started = Date.now();
    try {
      await sbSelect('fares', { select: 'id', limit: '1' });
      body.supabase = { ok: true, latency_ms: Date.now() - started };
    } catch (err) {
      body.ok = false;
      body.supabase = { ok: false, error: err instanceof Error ? err.message : String(err) };
    }
  }
  c.header('Cache-Control', 'no-store');
  return c.json(body, body.ok ? 200 : 503);
});
