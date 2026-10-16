// Per-place logo URLs for Farecart. A Google "s2" favicon for a known chain's
// domain, else for the place's own website host, else null.
//
// The chain table was checked on 2026-10-15 by downloading each favicon at
// sz=128 and comparing it with the generic globe the service returns for an
// unknown domain (HTTP 404, 726 bytes, 16x16). Chains whose icon was the globe
// or too small/blurry to be shown at 52 pt were left out so the app falls back
// to the category tile: Costco (16 px), Salvation Army (16 px), Green City
// Market (32 px), Devon Market (32 px), La Chiquita (32 px), Meijer (wrong
// icon), Carniceria La Hacienda / Cremeria La Ordena / Supermercado El Guero
// (no favicon). Dollar General, Walgreens and CVS are excluded on purpose.

export const FAVICON_SIZE = 128;

/** Chain name prefix (lower-case, punctuation stripped) → domain. Longer keys win. */
export const CHAINS = [
  ['jewel osco', 'jewelosco.com'],
  ['jewel', 'jewelosco.com'],
  ['aldi', 'aldi.us'],
  ['marianos', 'marianos.com'],
  ['petes fresh market', 'petesfresh.com'],
  ['petes market', 'petesfresh.com'],
  ['petes produce', 'petesfresh.com'],
  ['target', 'target.com'],
  ['walmart', 'walmart.com'],
  ['food 4 less', 'food4less.com'],
  ['food4less', 'food4less.com'],
  ['cermak fresh market', 'cermakfreshmarket.com'],
  ['cermak produce', 'cermakproduce.com'],
  ['tonys fresh market', 'tonysfreshmarket.com'],
  ['tonys finer foods', 'tonysfreshmarket.com'],
  ['tonys', 'tonysfreshmarket.com'],
  ['whole foods', 'wholefoodsmarket.com'],
  ['trader joes', 'traderjoes.com'],
  ['save a lot', 'savealot.com'],
  ['save-a-lot', 'savealot.com'],
  ['sams club', 'samsclub.com'],
  ['fresh thyme', 'freshthyme.com'],
  ['amazon fresh', 'amazon.com'],
  ['amazon grocery', 'amazon.com'],
  ['go grocer', 'gogrocerchicago.com'],
  ['potash markets', 'potashmarkets.com'],
  ['potash', 'potashmarkets.com'],
  ['forty acres fresh market', 'fortyacresfreshmarket.com'],
  ['fairplay', 'fairplayfoods.com'],
  ['morelia supermarket', 'moreliasupermarket.com'],
  ['morelia', 'moreliasupermarket.com'],
  ['carnicerias jimenez', 'jimenezfoods.com'],
  ['carniceria jimenez', 'jimenezfoods.com'],
  ['greater chicago food depository', 'chicagosfoodbank.org'],
  ['catholic charities', 'catholiccharities.net'],
  ['ymca', 'ymcachicago.org'],
].sort((a, b) => b[0].length - a[0].length);

/** Names that must never get a logo, even via their website. */
export const EXCLUDED = ['dollar general', 'walgreens', 'cvs'];

/** Chains that were tried and dropped (see header); their website host is not used either. */
const DROPPED_HOSTS = new Set([
  'costco.com', 'salvationarmy.org', 'greencitymarket.org', 'devonmarket.com',
  'foodmarketlachiquita.com', 'meijer.com', 'gogrocer.com', 'carniceriasjimenez.com',
  'carnicerialahacienda.com', 'cremerialaordena.com', 'supermercadoselguero.com',
]);

export function normalizeName(name) {
  return String(name || '')
    .toLowerCase()
    .replace(/[’'`´.]/g, '')
    .replace(/[^a-z0-9]+/g, ' ')
    .trim();
}

/** Domain for a chain name, or undefined when the name is not a known chain. */
export function chainDomain(name) {
  const n = normalizeName(name);
  if (!n) return undefined;
  if (EXCLUDED.some(x => n === x || n.startsWith(x + ' '))) return null;
  for (const [prefix, domain] of CHAINS) {
    if (n === prefix || n.startsWith(prefix + ' ')) return domain;
  }
  return undefined;
}

/** Registrable-ish host of a website URL: strips scheme, "www." and locator subdomains. */
export function websiteHost(website) {
  if (!website) return null;
  let host;
  try {
    host = new URL(/^https?:\/\//i.test(website) ? website : `https://${website}`).hostname.toLowerCase();
  } catch {
    return null;
  }
  host = host.replace(/^www\./, '');
  // "local.jewelosco.com", "stores.aldi.us", "locations.traderjoes.com" → apex domain.
  const parts = host.split('.');
  if (parts.length > 2 && !/^(co|com|org|net)$/.test(parts[parts.length - 2])) host = parts.slice(-2).join('.');
  if (!host.includes('.') || /^(facebook|instagram|twitter|x|linktr|google|goo|bit|yelp|foursquare)\./.test(host)) return null;
  if (DROPPED_HOSTS.has(host)) return null;
  return host;
}

export function faviconURL(host) {
  return `https://www.google.com/s2/favicons?domain=${encodeURIComponent(host)}&sz=${FAVICON_SIZE}`;
}

/**
 * Logo URL for a place: (a) known chain → its domain, (b) website host, (c) null.
 * Names in EXCLUDED always get null.
 */
export function logoURL(name, website) {
  const chain = chainDomain(name);
  if (chain === null) return null;
  const host = chain ?? websiteHost(website);
  return host ? faviconURL(host) : null;
}

/** The generic globe the favicon service returns for an unknown domain. */
export const GENERIC_FAVICON = { status: 404, bytes: 726 };

/**
 * True when the favicon URL serves a real icon: HTTP 200, not the generic
 * globe, and (for PNG) at least `minPixels` wide. Used by seed.mjs so a bad
 * website-derived logo never reaches the database.
 */
export async function faviconIsReal(url, { minPixels = 48, fetchImpl = fetch } = {}) {
  let res;
  try {
    res = await fetchImpl(url, { redirect: 'follow', headers: { 'User-Agent': 'Farecart-seed/1.0' } });
  } catch {
    return false;
  }
  if (res.status !== 200) return false;
  const buf = new Uint8Array(await res.arrayBuffer());
  if (buf.length === GENERIC_FAVICON.bytes) return false;
  // PNG: IHDR width is bytes 16..19 big-endian.
  if (buf.length > 24 && buf[0] === 0x89 && buf[1] === 0x50 && buf[2] === 0x4e && buf[3] === 0x47) {
    const width = (buf[16] << 24) | (buf[17] << 16) | (buf[18] << 8) | buf[19];
    return width >= minPixels;
  }
  return buf.length > 300; // JPEG/ICO/other: the service only re-encodes large sources this way
}
