import { Hono } from 'hono';
import { z } from 'zod';
import { ApiError, parseQuery, TEN_MINUTES } from '../lib/http.js';
import { findFare, formatCents, price, withSavings } from '../lib/money.js';
import { fetchFares, fetchPrograms, type FareRider, type FareRow, type ProgramRow } from '../lib/supabase.js';

const Bool = z
  .enum(['true', 'false', '1', '0', 'yes', 'no'])
  .default('false')
  .transform((v) => v === 'true' || v === '1' || v === 'yes');

const Query = z.object({ snap: Bool, student: Bool });

/** programs.key -> fares.rider */
const RIDER_FOR_PROGRAM: Record<string, FareRider> = { access: 'reduced_access', student: 'student' };

function programFares(rows: FareRow[], rider: FareRider) {
  return {
    rider,
    bus: withSavings(findFare(rows, 'bus', rider), findFare(rows, 'bus', 'full')),
    train: withSavings(findFare(rows, 'train', rider), findFare(rows, 'train', 'full')),
  };
}

export const eligibility = new Hono().get('/', async (c) => {
  const { snap, student } = parseQuery(c, Query);
  const [fareRows, programRows] = await Promise.all([fetchFares(), fetchPrograms()]);

  const byKey = new Map(programRows.map((p) => [p.key, p]));
  const pick = (key: string): ProgramRow => {
    const p = byKey.get(key);
    if (!p) throw new ApiError(502, 'program_missing', `No "${key}" row in the programs table`);
    return p;
  };

  const applicable: ProgramRow[] = [];
  if (snap) applicable.push(pick('access'));
  if (student) applicable.push(pick('student'));

  const fullBus = findFare(fareRows, 'bus', 'full');
  const fullTrain = findFare(fareRows, 'train', 'full');
  const full = { rider: 'full' as const, bus: price(fullBus.price_cents), train: price(fullTrain.price_cents) };

  const programs = applicable.map((p) => {
    const rider = RIDER_FOR_PROGRAM[p.key];
    if (!rider) throw new ApiError(502, 'program_unmapped', `Program "${p.key}" has no fare mapping`);
    return { ...p, fares: programFares(fareRows, rider) };
  });

  c.header('Cache-Control', TEN_MINUTES);

  if (programs.length === 0) {
    const access = byKey.get('access');
    const accessBus = access ? findFare(fareRows, 'bus', 'reduced_access') : undefined;
    const note = access && accessBus
      ? `If anyone in your household gets SNAP, you may qualify for ${access.name} (${formatCents(accessBus.price_cents)} bus) at ${access.signup_url ?? 'getaccess.org'}.`
      : 'Reduced fares are available for SNAP households and K-12 students.';
    return c.json({
      input: { snap, student },
      eligible: false,
      programs: [],
      best: { program_key: null, ...full },
      full,
      message: `Full fare is ${full.bus.formatted} on the bus and ${full.train.formatted} on the train.`,
      note,
      signup_url: access?.signup_url ?? null,
      phone: access?.phone ?? null,
    });
  }

  // Cheapest bus fare wins; ties go to the first applicable program.
  const best = programs.reduce((a, b) => (b.fares.bus.price_cents < a.fares.bus.price_cents ? b : a));
  const runnerUp = programs.find((p) => p.key !== best.key);

  let message = `You could pay ${best.fares.bus.formatted} instead of ${full.bus.formatted} on the bus`;
  if (best.key === 'student') message += ' with a Ventra Student Card on school days';
  if (runnerUp) {
    message += `, or ${runnerUp.fares.bus.formatted} any time with ${runnerUp.name}`;
  }
  message += '.';

  return c.json({
    input: { snap, student },
    eligible: true,
    programs,
    best: { program_key: best.key, program_name: best.name, ...best.fares },
    full,
    message,
    signup_url: best.signup_url,
    phone: best.phone,
  });
});
