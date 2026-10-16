/**
 * Google encoded polyline helpers. MOTIS/Transitous encodes leg geometry at precision 7
 * by default (1e-7 degrees) but some builds use the classic precision 5, so we detect
 * which one by decoding and checking that the line lands in Chicago.
 */
export type LatLng = { lat: number; lng: number };
export type PolylinePrecision = 5 | 7;

/** Generous bounding box around the Chicago metro area. */
export const CHICAGO_BBOX = { minLat: 41.3, maxLat: 42.3, minLng: -88.5, maxLng: -87.2 } as const;

export function inChicago(p: LatLng): boolean {
  return (
    p.lat >= CHICAGO_BBOX.minLat &&
    p.lat <= CHICAGO_BBOX.maxLat &&
    p.lng >= CHICAGO_BBOX.minLng &&
    p.lng <= CHICAGO_BBOX.maxLng
  );
}

export function decodePolyline(encoded: string, precision: PolylinePrecision = 7): LatLng[] {
  const factor = 10 ** precision;
  const out: LatLng[] = [];
  let index = 0;
  let lat = 0;
  let lng = 0;

  const next = (): number => {
    let result = 0;
    let shift = 0;
    let byte: number;
    do {
      if (index >= encoded.length) throw new Error('Truncated polyline');
      byte = encoded.charCodeAt(index++) - 63;
      result |= (byte & 0x1f) << shift;
      shift += 5;
    } while (byte >= 0x20);
    return result & 1 ? ~(result >> 1) : result >> 1;
  };

  while (index < encoded.length) {
    lat += next();
    lng += next();
    out.push({ lat: lat / factor, lng: lng / factor });
  }
  return out;
}

export function encodePolyline(points: LatLng[], precision: PolylinePrecision = 7): string {
  const factor = 10 ** precision;
  let out = '';
  let prevLat = 0;
  let prevLng = 0;
  const push = (value: number) => {
    let v = value < 0 ? ~(value << 1) : value << 1;
    while (v >= 0x20) {
      out += String.fromCharCode((0x20 | (v & 0x1f)) + 63);
      v >>= 5;
    }
    out += String.fromCharCode(v + 63);
  };
  for (const p of points) {
    const lat = Math.round(p.lat * factor);
    const lng = Math.round(p.lng * factor);
    push(lat - prevLat);
    push(lng - prevLng);
    prevLat = lat;
    prevLng = lng;
  }
  return out;
}

/**
 * Decide whether an encoded line is precision 7 or 5: try 7 first (MOTIS default) and
 * accept it if the first point lands in Chicago; otherwise try 5; otherwise trust the
 * precision the upstream reported (default 7).
 */
export function detectPrecision(encoded: string, reported?: number | null): PolylinePrecision {
  const fallback: PolylinePrecision = reported === 5 ? 5 : 7;
  if (!encoded) return fallback;
  for (const precision of [7, 5] as const) {
    try {
      const first = decodePolyline(encoded, precision)[0];
      if (first && inChicago(first)) return precision;
    } catch {
      // malformed at this precision; try the other one
    }
  }
  return fallback;
}
