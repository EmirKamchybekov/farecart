import { Hono } from 'hono';
import { z } from 'zod';
import { ApiError, fetchJson } from '../lib/http.js';
import { sbRpc, sbSelect, type PantryAvailability } from '../lib/supabase.js';

/**
 * Feed America directory (feedam.org, CC BY 4.0). We only read the per-resource
 * status endpoint for pantries linked by `locations.feedam_id`; the rate limit
 * is 10k requests/day/IP, so responses are cached for 10 minutes.
 */
export const FEEDAM_ATTRIBUTION = 'Directory published by Feed America (feedam.org)';
export const FEEDAM_USER_AGENT = 'Farecart/0.1 (hello@farecart.org)';

type FeedamStatus = {
  id: number;
  phone_valid?: boolean | null;
  phone_formatted?: string | null;
  hours_status?: string | null;
  days_since_verified?: number | null;
  confidence?: string | null;
};

const Params = z.object({ id: z.uuid() });
const STATUS_TTL_MS = 10 * 60 * 1000;
const statusCache = new Map<number, { at: number; value: FeedamStatus | null }>();

type LocationStub = { id: string; name: string; type: string; feedam_id: number | null };

async function feedamStatus(feedamId: number): Promise<FeedamStatus | null> {
  const hit = statusCache.get(feedamId);
  if (hit && Date.now() - hit.at < STATUS_TTL_MS) return hit.value;
  const value = await fetchFeedamStatus(feedamId);
  statusCache.set(feedamId, { at: Date.now(), value });
  return value;
}

async function fetchFeedamStatus(feedamId: number): Promise<FeedamStatus | null> {
  try {
    const s = await fetchJson<FeedamStatus>(`https://feedam.org/api/resources/${feedamId}/status`, 'Feed America', {
      headers: { 'User-Agent': FEEDAM_USER_AGENT, Accept: 'application/json' },
      timeoutMs: 4000,
    });
    return s && typeof s === 'object' && s.id === feedamId ? s : null;
  } catch {
    return null; // Feed America is a bonus signal; never fail the pantry page over it
  }
}

export const pantry = new Hono().get('/:id/availability', async (c) => {
  const parsed = Params.safeParse(c.req.param());
  if (!parsed.success) throw new ApiError(400, 'bad_request', 'id must be a location uuid');
  const { id } = parsed.data;

  const [loc] = await sbSelect<LocationStub>('locations', { select: 'id,name,type,feedam_id', id: `eq.${id}`, limit: '1' });
  if (!loc) throw new ApiError(404, 'not_found', `No location ${id}`);

  const [availability, status] = await Promise.all([
    sbRpc<PantryAvailability>('pantry_availability', { p_location_id: id }),
    loc.feedam_id ? feedamStatus(loc.feedam_id) : Promise.resolve(null),
  ]);

  const feedam = status
    ? {
        id: status.id,
        hours_status: status.hours_status ?? null,
        confidence: status.confidence ?? null,
        days_since_verified: status.days_since_verified ?? null,
        phone_valid: status.phone_valid ?? null,
        source: 'feedam' as const,
        attribution: FEEDAM_ATTRIBUTION,
        url: `https://feedam.org/resource/${status.id}`,
      }
    : null;

  // Slots change with every booking: keep the edge cache short. Feed America is cached 10 min above.
  c.header('Cache-Control', 'public, max-age=30, s-maxage=30');
  return c.json({
    location: { id: loc.id, name: loc.name, type: loc.type, feedam_id: loc.feedam_id },
    inventory: availability.inventory,
    slots: availability.slots,
    staff_updated_at: availability.staff_updated_at,
    feedam,
  });
});
