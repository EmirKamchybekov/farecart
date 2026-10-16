/**
 * Built-in centroids for West Side Chicago neighborhoods so typing a name resolves instantly
 * without a network call. Approximate community-area centroids (WGS84).
 */
export type Neighborhood = { name: string; lat: number; lng: number; aliases: string[] };

export const NEIGHBORHOODS: Neighborhood[] = [
  { name: 'West Garfield Park', lat: 41.8804, lng: -87.729, aliases: ['west garfield', 'w garfield park'] },
  { name: 'East Garfield Park', lat: 41.8807, lng: -87.7033, aliases: ['east garfield', 'e garfield park', 'garfield park'] },
  { name: 'Austin', lat: 41.8878, lng: -87.7649, aliases: [] },
  { name: 'North Lawndale', lat: 41.86, lng: -87.718, aliases: ['n lawndale', 'lawndale'] },
  { name: 'South Lawndale', lat: 41.8436, lng: -87.7128, aliases: ['s lawndale', 'little village', 'la villita'] },
  { name: 'Humboldt Park', lat: 41.9017, lng: -87.7177, aliases: ['humboldt'] },
  { name: 'Near West Side', lat: 41.8731, lng: -87.6669, aliases: ['west loop', 'medical district', 'illinois medical district', 'little italy', 'tri-taylor'] },
  { name: 'West Town', lat: 41.897, lng: -87.6782, aliases: ['ukrainian village', 'wicker park', 'noble square', 'east village'] },
  { name: 'Logan Square', lat: 41.9231, lng: -87.7093, aliases: ['logan sq'] },
  { name: 'Pilsen', lat: 41.854, lng: -87.665, aliases: ['lower west side', 'heart of chicago'] },
];

function normalize(s: string): string {
  return s
    .toLowerCase()
    .replace(/[^a-z0-9\s/-]/g, ' ')
    .replace(/\b(chicago|il|illinois|usa|united states)\b/g, ' ')
    .replace(/\s+/g, ' ')
    .trim();
}

/** Exact match on a neighborhood name or alias (after stripping "Chicago, IL" etc). */
export function lookupNeighborhood(q: string): Neighborhood | undefined {
  const key = normalize(q);
  if (!key) return undefined;
  // "South Lawndale/Little Village" style input: try each half.
  const parts = key.split('/').map((p) => p.trim()).filter(Boolean);
  for (const n of NEIGHBORHOODS) {
    const names = [normalize(n.name), ...n.aliases.map(normalize)];
    if (parts.some((p) => names.includes(p))) return n;
  }
  return undefined;
}

/** Rough bounding box around the City of Chicago, used to validate geocoder hits. */
export const CHICAGO_BBOX = { south: 41.6, north: 42.05, west: -87.95, east: -87.5 } as const;

export function inChicago(lat: number, lng: number): boolean {
  return lat >= CHICAGO_BBOX.south && lat <= CHICAGO_BBOX.north && lng >= CHICAGO_BBOX.west && lng <= CHICAGO_BBOX.east;
}

/** True if the free-text query already names a city/state/zip. */
export function mentionsCity(q: string): boolean {
  return /\bchicago\b|\billinois\b|,\s*il\b|\bil\s+\d{5}\b|\b606\d{2}\b/i.test(q);
}
