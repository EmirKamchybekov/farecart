import assert from 'node:assert/strict';
import { describe, it } from 'node:test';
import { NON_CTA_NOTE, tripCost, type FareLegInput } from '../../src/lib/tripFare.js';
import type { LegMode } from '../../src/lib/transitous.js';
import { FARES } from './fares.fixture.js';

const CTA = 'Chicago Transit Authority';
const T0 = Date.parse('2026-10-16T14:00:00Z');

/** Build legs from [mode, minutesAfterStart, agency?] tuples. */
function legs(spec: Array<[LegMode, number, string?]>): FareLegInput[] {
  return spec.map(([mode, min, agency]) => ({
    mode,
    agency_name: mode === 'walk' ? null : (agency ?? CTA),
    start_time: new Date(T0 + min * 60_000).toISOString(),
  }));
}

const RIDERS = [
  { rider: 'full', bus: 225, train: 250 },
  { rider: 'reduced_access', bus: 110, train: 125 },
  { rider: 'student', bus: 75, train: 75 },
] as const;

describe('tripCost', () => {
  for (const r of RIDERS) {
    describe(`rider=${r.rider}`, () => {
      it('bus-only trip costs one bus fare', () => {
        const c = tripCost(legs([['walk', 0], ['bus', 5], ['walk', 30]]), FARES, r.rider);
        assert.equal(c.rider_cents, r.bus);
        assert.equal(c.full_cents, 225);
        assert.equal(c.savings_cents, 225 - r.bus);
        assert.equal(c.boardings, 1);
        assert.equal(c.rider_formatted, `$${(r.bus / 100).toFixed(2)}`);
        assert.equal(c.note, undefined);
      });

      it('train first then bus costs the train fare + free transfer', () => {
        const c = tripCost(legs([['walk', 0], ['train', 5], ['walk', 25], ['bus', 30], ['walk', 50]]), FARES, r.rider);
        assert.equal(c.rider_cents, r.train);
        assert.equal(c.full_cents, 250);
        assert.equal(c.savings_cents, 250 - r.train);
        assert.equal(c.boardings, 2);
      });

      it('bus first then train stays at the bus fare', () => {
        const c = tripCost(legs([['bus', 0], ['train', 20]]), FARES, r.rider);
        assert.equal(c.rider_cents, r.bus);
        assert.equal(c.full_cents, 225);
      });

      it('3 boardings within 2h = first fare + 2 free transfers', () => {
        const c = tripCost(legs([['bus', 0], ['bus', 30], ['train', 60]]), FARES, r.rider);
        assert.equal(c.rider_cents, r.bus);
        assert.equal(c.boardings, 3);
      });

      it('4 boardings: the 4th starts a second fare at its own mode price', () => {
        const c = tripCost(legs([['bus', 0], ['bus', 20], ['bus', 40], ['train', 60]]), FARES, r.rider);
        assert.equal(c.rider_cents, r.bus + r.train);
        assert.equal(c.full_cents, 225 + 250);
        assert.equal(c.boardings, 4);
      });

      it('a boarding outside the transfer window starts a new fare', () => {
        const c = tripCost(legs([['bus', 0], ['bus', 121]]), FARES, r.rider);
        assert.equal(c.rider_cents, r.bus * 2);
      });

      it('a boarding exactly at the window edge is still a transfer', () => {
        const c = tripCost(legs([['bus', 0], ['bus', 120]]), FARES, r.rider);
        assert.equal(c.rider_cents, r.bus);
      });

      it('walk-only trip is free', () => {
        const c = tripCost(legs([['walk', 0]]), FARES, r.rider);
        assert.deepEqual(c, {
          rider_cents: 0, rider_formatted: '$0.00', full_cents: 0, full_formatted: '$0.00', savings_cents: 0, boardings: 0,
        });
      });

      it('non-CTA leg is flagged and not priced', () => {
        const c = tripCost(legs([['bus', 0], ['train', 30, 'Metra'], ['bus', 90, 'Pace']]), FARES, r.rider);
        assert.equal(c.note, NON_CTA_NOTE);
        assert.equal(c.rider_cents, r.bus, 'only the CTA bus is priced');
        assert.equal(c.boardings, 3);
      });
    });
  }

  it('window is measured from the boarding that started the fare, not the previous boarding', () => {
    // 0, 70, 140: the 3rd boarding is 70 min after the 2nd but 140 min after the fare started.
    const c = tripCost(legs([['bus', 0], ['bus', 70], ['bus', 140]]), FARES, 'full');
    assert.equal(c.rider_cents, 450);
  });

  it('missing boarding times are treated as inside the window', () => {
    const c = tripCost(
      [{ mode: 'bus', agency_name: CTA, start_time: null }, { mode: 'train', agency_name: CTA, start_time: null }],
      FARES,
      'full',
    );
    assert.equal(c.rider_cents, 225);
  });

  it('"other" modes (ferry, bike share) are counted as boardings but flagged, never priced', () => {
    const c = tripCost(legs([['other', 0, 'Divvy']]), FARES, 'full');
    assert.equal(c.rider_cents, 0);
    assert.equal(c.note, NON_CTA_NOTE);
  });
});
