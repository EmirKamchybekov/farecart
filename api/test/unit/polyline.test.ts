import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { describe, it } from 'node:test';
import { decodePolyline, detectPrecision, encodePolyline, inChicago } from '../../src/lib/polyline.js';
import type { MotisPlanResponse } from '../../src/lib/transitous.js';

const fixture: MotisPlanResponse = JSON.parse(
  readFileSync(new URL('../fixtures/transitous-plan.json', import.meta.url), 'utf8'),
);
const itinerary = fixture.itineraries![0]!;
const walkLeg = itinerary.legs[0]!;
const busLeg = itinerary.legs[1]!;

describe('decodePolyline', () => {
  it('decodes the Google reference example at precision 5', () => {
    const pts = decodePolyline('_p~iF~ps|U_ulLnnqC_mqNvxq`@', 5);
    assert.deepEqual(pts, [
      { lat: 38.5, lng: -120.2 },
      { lat: 40.7, lng: -120.95 },
      { lat: 43.252, lng: -126.453 },
    ]);
  });

  it('round-trips through encodePolyline at both precisions', () => {
    const pts = [{ lat: 41.8807, lng: -87.7262 }, { lat: 41.8819, lng: -87.6868 }, { lat: 41.87, lng: -87.7 }];
    for (const precision of [5, 7] as const) {
      const decoded = decodePolyline(encodePolyline(pts, precision), precision);
      for (let i = 0; i < pts.length; i++) {
        assert.ok(Math.abs(decoded[i]!.lat - pts[i]!.lat) < 10 ** -precision + 1e-9);
        assert.ok(Math.abs(decoded[i]!.lng - pts[i]!.lng) < 10 ** -precision + 1e-9);
      }
    }
  });
});

describe('Transitous fixture (41.8807,-87.7262 -> 41.8819,-87.6868)', () => {
  it('walk leg decodes at precision 7 to the requested origin', () => {
    const pts = decodePolyline(walkLeg.legGeometry!.points, 7);
    assert.equal(pts.length, walkLeg.legGeometry!.length);
    assert.ok(Math.abs(pts[0]!.lat - 41.8807) < 1e-4);
    assert.ok(Math.abs(pts[0]!.lng + 87.7262) < 1e-4);
  });

  it('bus 20 leg decodes along Madison St and every point is in Chicago', () => {
    const pts = decodePolyline(busLeg.legGeometry!.points, 7);
    assert.ok(pts.length > 50);
    assert.ok(pts.every(inChicago));
    assert.ok(Math.abs(pts[0]!.lat - busLeg.from.lat) < 1e-3);
    assert.ok(Math.abs(pts.at(-1)!.lng - busLeg.to.lon) < 1e-3);
  });

  it('detectPrecision reports 7 for every leg of every itinerary', () => {
    for (const it of fixture.itineraries!) {
      for (const leg of it.legs) {
        assert.equal(detectPrecision(leg.legGeometry!.points, leg.legGeometry!.precision), 7);
      }
    }
  });

  it('decoding the precision-7 line as 5 lands far outside Chicago (so detection is meaningful)', () => {
    assert.equal(inChicago(decodePolyline(busLeg.legGeometry!.points, 5)[0]!), false);
  });
});

describe('detectPrecision', () => {
  const chicago = [{ lat: 41.8807, lng: -87.7262 }, { lat: 41.8819, lng: -87.6868 }];

  it('returns 5 for a precision-5 encoding of a Chicago line, even if upstream claims 7', () => {
    assert.equal(detectPrecision(encodePolyline(chicago, 5), 7), 5);
  });

  it('returns 7 for a precision-7 encoding, even if upstream claims 5', () => {
    assert.equal(detectPrecision(encodePolyline(chicago, 7), 5), 7);
  });

  it('falls back to the reported precision when neither decoding lands in Chicago', () => {
    const berlin = encodePolyline([{ lat: 52.52, lng: 13.405 }], 7);
    assert.equal(detectPrecision(berlin, 5), 5);
    assert.equal(detectPrecision(berlin, 7), 7);
    assert.equal(detectPrecision(berlin, null), 7);
  });

  it('falls back on an empty or malformed string', () => {
    assert.equal(detectPrecision('', 5), 5);
    assert.equal(detectPrecision('\u007f', undefined), 7);
  });
});
