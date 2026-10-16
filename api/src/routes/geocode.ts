import { Hono } from 'hono';
import { z } from 'zod';
import { optionalEnv } from '../env.js';
import { ApiError, fetchJson, parseQuery } from '../lib/http.js';
import { CHICAGO_BBOX, inChicago, lookupNeighborhood, mentionsCity } from '../lib/neighborhoods.js';

const Query = z.object({
  q: z.string().trim().min(2, 'q must be at least 2 characters').max(200),
});

export type GeocodeResult = {
  query: string;
  lat: number;
  lng: number;
  label: string;
  source: 'neighborhood' | 'census' | 'nominatim';
};

const round6 = (n: number) => Math.round(n * 1e6) / 1e6;

function chicagoize(q: string): string {
  return mentionsCity(q) ? q : `${q}, Chicago, IL`;
}

type CensusResponse = {
  result?: {
    addressMatches?: Array<{ matchedAddress?: string; coordinates?: { x: number; y: number } }>;
  };
};

async function census(q: string): Promise<GeocodeResult | undefined> {
  const url = new URL('https://geocoding.geo.census.gov/geocoder/locations/onelineaddress');
  url.searchParams.set('address', chicagoize(q));
  url.searchParams.set('benchmark', 'Public_AR_Current');
  url.searchParams.set('format', 'json');
  const data = await fetchJson<CensusResponse>(url, 'Census Geocoder', { timeoutMs: 7000 });
  for (const m of data.result?.addressMatches ?? []) {
    const lat = m.coordinates?.y;
    const lng = m.coordinates?.x;
    if (typeof lat === 'number' && typeof lng === 'number' && inChicago(lat, lng)) {
      return { query: q, lat: round6(lat), lng: round6(lng), label: m.matchedAddress ?? q, source: 'census' };
    }
  }
  return undefined;
}

type NominatimHit = { lat: string; lon: string; display_name?: string; name?: string };

async function nominatim(q: string): Promise<GeocodeResult | undefined> {
  const url = new URL('https://nominatim.openstreetmap.org/search');
  url.searchParams.set('q', chicagoize(q));
  url.searchParams.set('format', 'jsonv2');
  url.searchParams.set('limit', '1');
  url.searchParams.set('countrycodes', 'us');
  // viewbox is left,top,right,bottom (lng,lat); bounded=1 restricts results to it.
  url.searchParams.set('viewbox', `${CHICAGO_BBOX.west},${CHICAGO_BBOX.north},${CHICAGO_BBOX.east},${CHICAGO_BBOX.south}`);
  url.searchParams.set('bounded', '1');
  const hits = await fetchJson<NominatimHit[]>(url, 'Nominatim', {
    timeoutMs: 7000,
    headers: {
      'User-Agent': optionalEnv('NOMINATIM_USER_AGENT') ?? 'FreshRoute-API/0.1 (Chicago West Side food access; non-commercial)',
      'Accept-Language': 'en-US',
    },
  });
  const hit = hits[0];
  if (!hit) return undefined;
  const lat = Number(hit.lat);
  const lng = Number(hit.lon);
  if (!Number.isFinite(lat) || !Number.isFinite(lng) || !inChicago(lat, lng)) return undefined;
  return { query: q, lat: round6(lat), lng: round6(lng), label: hit.display_name ?? hit.name ?? q, source: 'nominatim' };
}

export const geocode = new Hono().get('/', async (c) => {
  const { q } = parseQuery(c, Query);

  const hood = lookupNeighborhood(q);
  if (hood) {
    c.header('Cache-Control', 'public, max-age=86400, s-maxage=86400');
    const result: GeocodeResult = { query: q, lat: hood.lat, lng: hood.lng, label: `${hood.name}, Chicago, IL`, source: 'neighborhood' };
    return c.json(result);
  }

  // Census first (authoritative for street addresses); Nominatim for POIs / fuzzy input.
  let result: GeocodeResult | undefined;
  let censusError: string | undefined;
  try {
    result = await census(q);
  } catch (err) {
    censusError = err instanceof Error ? err.message : String(err);
  }
  if (!result) {
    try {
      result = await nominatim(q);
    } catch (err) {
      if (censusError) {
        throw new ApiError(502, 'geocoders_unavailable', 'Both geocoders failed', {
          census: censusError,
          nominatim: err instanceof Error ? err.message : String(err),
        });
      }
      throw err;
    }
  }
  if (!result) {
    throw new ApiError(404, 'not_found', `Could not find "${q}" in Chicago. Try a street address or a neighborhood name.`);
  }
  c.header('Cache-Control', 'public, max-age=3600, s-maxage=3600');
  return c.json(result);
});
