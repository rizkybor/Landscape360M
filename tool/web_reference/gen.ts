// Generates reference values from the web code, for the Dart parity tests.
import * as S from 'WEB/src/utils/surveyUtils';
import * as A from 'WEB/src/utils/markedAreas';
import * as T from 'WEB/src/utils/trackRecorderGeo';
import * as L from 'WEB/src/lib/shareLocation';

type LL = [number, number];
const pairs: [number, number, number, number][] = [
  [-6.2, 106.8, -6.21, 106.83],
  [-7.6, 110.45, -7.55, 110.4],
  [-6.78991, 106.9832, -6.7, 107.1],
  [0, 0, 0, 1],
  [0, 0, 1, 0],
  [10, 20, -10, -20],
  [-37.95103341666667, 144.42486788888888, -37.65282113888889, 143.92649552777777],
  [60, -30, 61, 170],
  [-6.2, 106.8, -6.2 + 1 / 3600, 106.8],
  [3.5, 98.6, -8.6, 115.2],
];
const geodesic = pairs.map(([a, b, c, d]) => ({ input: [a, b, c, d], ...S.geodesicInverse(a, b, c, d) }));

const az = pairs.map(([a, b, c, d], i) => ({
  input: [a, b, i * 37.5, c, d, i * 11.25 + 3],
  ...S.getAzimuthData({ id: 'a', lat: a, lng: b, elevation: i * 37.5 }, { id: 'b', lat: c, lng: d, elevation: i * 11.25 + 3 }),
}));

const snaps: { prev: LL | null; last: LL; target: LL; step: number }[] = [
  { prev: [106.75, -6.235], last: [106.75, -6.234], target: [106.751, -6.2338], step: 90 },
  { prev: [106.75, -6.235], last: [106.751, -6.234], target: [106.7505, -6.2334], step: 90 },
  { prev: [106.75, -6.235], last: [106.75, -6.234], target: [106.7508, -6.2333], step: 45 },
  { prev: null, last: [106.75, -6.234], target: [106.7512, -6.2338], step: 90 },
  { prev: [106.75, -6.235], last: [106.75, -6.234], target: [106.7493, -6.2331], step: 15 },
  { prev: [110.4, -7.6], last: [110.402, -7.601], target: [110.401, -7.6035], step: 15 },
];
const snap = snaps.map((s) => ({ ...s, result: S.snapToAngle(s.prev, s.last, s.target, s.step) }));

const square = [
  { lng: 106.75, lat: -6.235 },
  { lng: 106.75, lat: -6.234 },
  { lng: 106.751, lat: -6.234 },
  { lng: 106.751, lat: -6.235 },
];
const handle = S.handleFromDrag(square[0], [106.7503, -6.2347]);
const lines = [
  { points: square },
  { points: square.map((p) => ({ ...p, corner: 'sharp' })) },
  { points: [...square, { lng: 106.752, lat: -6.2355 }].map((p, i) => (i === 2 ? { ...p, corner: 'sharp' } : p)) },
  { points: [{ ...square[0], handle }, { lng: 106.751, lat: -6.235 }] },
  { points: [{ ...square[0] }, { ...square[1], handle: { east: 20, north: -5 } }, square[2], { ...square[3], corner: 'sharp' }] },
].map((l) => ({
  ...l,
  line: S.buildSurveyLine(l.points as never),
  mids: S.segmentMidpoints(l.points as never),
}));
const handles = { handle, ends: S.handleEnds(square[0], { east: 12.5, north: -7.25 }) };

const coords = [-6.23642, 106.743808, -7.98765, 110.1234567, 0, 0.000001, -0.5, 179.999999, -89.9, 45.5, 6 + 13 / 60 + 59.999 / 3600];
const dms = coords.flatMap((c) => [
  { deg: c, isLat: true, out: S.toDMS(c, true) },
  { deg: c, isLat: false, out: S.toDMS(c, false) },
]);
const utm = pairs.map(([a, b]) => ({ lat: a, lng: b, out: S.toUTM(a, b) }));
const fmt = [0, 0.04, 0.05, 1.25, 12.345, 999.95, 1000, 1234.567, 98765.4321].map((m) => ({
  m,
  dist: S.formatDistance(m),
  deg: S.formatDegrees(m % 360),
  degIn: m % 360,
  trackDist: T.formatDistance(m),
  area: A.formatArea(m * 1000),
  areaIn: m * 1000,
  len: A.formatLength(m),
}));

const rings: LL[][] = [
  [[106.98, -6.79], [106.980904, -6.79], [106.980904, -6.789096], [106.98, -6.789096]],
  [[110.4, -7.6], [110.43, -7.61], [110.45, -7.58], [110.42, -7.55], [110.39, -7.57]],
  [[0, 0], [1, 0], [1, 1]],
];
const areas = rings.map((r) => ({ ring: r, area: A.ringArea(r), perimeter: A.ringPerimeter(r), mask: A.focusMask(r).geometry.coordinates }));

const hav = pairs.map(([a, b, c, d]) => ({ input: [a, b, c, d], d: T.haversineDistance({ lat: a, lng: b }, { lat: c, lng: d }) }));

const share = {
  url: L.sharedLocationUrl(-6.789912, 106.983201),
  urlNeg: L.sharedLocationUrl(-0.000004, -0.000006),
};

console.log(JSON.stringify({ geodesic, az, snap, lines, handles, dms, utm, fmt, areas, hav, share }, null, 1));
