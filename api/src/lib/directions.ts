/** Transit deep links for a destination. Matches the README conventions. */
export type Directions = { apple: string; google: string };

export function transitDirections(lat: number, lng: number, name?: string): Directions {
  const dest = `${lat},${lng}`;
  const apple = new URL('maps://');
  apple.searchParams.set('daddr', dest);
  apple.searchParams.set('dirflg', 'r');
  if (name) apple.searchParams.set('q', name);

  const google = new URL('https://www.google.com/maps/dir/');
  google.searchParams.set('api', '1');
  google.searchParams.set('destination', dest);
  google.searchParams.set('travelmode', 'transit');

  return { apple: apple.toString(), google: google.toString() };
}

export function metersToMiles(m: number): number {
  return Math.round((m / 1609.344) * 10) / 10;
}
