// Generates reference values from the web code, for the Dart parity tests.
import * as S from 'WEB/src/utils/surveyUtils';
import * as A from 'WEB/src/utils/markedAreas';
import * as T from 'WEB/src/utils/trackRecorderGeo';
import * as L from 'WEB/src/lib/shareLocation';
import * as Tiles from 'WEB/src/utils/tileUtils';
import * as C from 'WEB/src/utils/classicNav';
import * as CS from 'WEB/src/utils/classicSolve';

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

// Offline maps: tiles a download covers (RegionDrawingOverlay.tsx)
const tileBoxes: [Tiles.Bounds, number, number][] = [
  [{ west: 106.95, south: -6.82, east: 107.02, north: -6.75 }, 13, 15],
  [{ west: 110.40, south: -7.56, east: 110.47, north: -7.50 }, 12, 14],
  [{ west: 106.8, south: -6.25, east: 106.9, north: -6.15 }, 14, 16],
  [{ west: -0.1, south: 51.45, east: 0.05, north: 51.55 }, 10, 12],
];
const tiles = tileBoxes.map(([b, min, max]) => ({ bounds: b, min, max, count: Tiles.getTilesInBounds(b, min, max).length }));

// Classic: resection / intersection practice (classicNav.ts, classicSolve.ts)
const dmsCases = [
  ['7', '27', '16.92'], ['110', '26', '23.28'], ['', '', ''], ['', '5', ''], ['7.5', '0', '0'], ['7', '60', '0'],
  ['7', '0', '60'], ['91', '0', '0'], ['-7', '0', '0'], ['a', '0', '0'], ['359', '59', '59.99'], ['360', '0', '0'],
  ['12', '', ''], [' 6 ', '4,5', ''], ['6', '4', '5,25'],
].map(([d, m, s]) => ({ d, m, s }));
const classicDms = dmsCases.flatMap((input) =>
  ([90, 180, 360] as const).map((max) => ({ input, max, out: C.parseDms(input, max, 'latitude') })),
);
const classicToDms = [-7.45470, 110.43980, 0, 0.0000013, 59.999999, -0.5, 106.98321].map((v) => ({ v, out: C.toDmsInput(v) }));
const classicCompass = ['', '114', '114.5', '114,5', '360', '0', '-5', '400', 'abc', '45°', ' 12 '].map((t) => ({ t, out: C.parseCompass(t, 'azimuth') }));
const classicFormat = [0, 59.96, 359.96, -10, 720.25, 114.44, 11.25, 22.5, 33.74].map((v) => ({
  v,
  fmt: C.formatCompass(v),
  point: C.compassPoint(v),
  back: C.backAzimuthOf(v),
  diff: C.angleDiff(v, 350),
}));
const classicHints = ['N', 'NNE', 'ENE', 'S', 'WSW', 'NNW'].map((p) => ({ p, hint: C.compassPointHint(p) }));
const backChecks = [
  [240, 60], [60, 60], [240.5, 60.5], [240.7, 60.5], [200, 60], [30, 210], [30.04, 210], [0, 180], [181, 1],
].map(([back, az]) => ({ back, az, out: C.checkBackAzimuth(back, az) }));
const lineSets: C.Line[][] = [
  [{ from: [110.43, -7.46], bearing: 45 }, { from: [110.45, -7.46], bearing: 315 }],
  [{ from: [110.43, -7.46], bearing: 10 }, { from: [110.45, -7.46], bearing: 350 }],
  [{ from: [110.43, -7.46], bearing: 45 }, { from: [110.45, -7.46], bearing: 315 }, { from: [110.44, -7.48], bearing: 2 }],
  [{ from: [106.98, -6.78], bearing: 90 }, { from: [106.98, -6.79], bearing: 90 }],
  [
    { from: [110.43, -7.46], bearing: 45 }, { from: [110.45, -7.46], bearing: 315 },
    { from: [110.44, -7.48], bearing: 0 }, { from: [110.42, -7.44], bearing: 120 },
  ],
  [{ from: [110.43, -7.46], bearing: 225 }, { from: [110.45, -7.46], bearing: 135 }],
];
const classicFix = lineSets.map((lines) => {
  const fix = C.fixFromLines(lines);
  return {
    lines,
    fix,
    radius: fix ? C.fixRadius(fix) : null,
    review: fix ? C.reviewFix(fix, lines, 'intersection', lines.map((_, i) => `position ${String.fromCharCode(65 + i)}`)) : null,
  };
});
const classicAlong = [
  [[110.43, -7.46], 45, [110.44, -7.45]],
  [[110.43, -7.46], 45, [110.42, -7.47]],
  [[106.98, -6.78], 270, [106.97, -6.781]],
].map(([from, bearing, to]) => ({ from, bearing, to, out: C.lengthAlong(from as LL, bearing as number, to as LL) }));

const P = (lat: [string, string, string], lng: [string, string, string], south = true, west = false) => ({
  lat: { d: lat[0], m: lat[1], s: lat[2] },
  lng: { d: lng[0], m: lng[1], s: lng[2] },
  south,
  west,
});
const blank = P(['', '', ''], ['', '', '']);
const sg = (point: ReturnType<typeof P>, azimuth: string, back: string, azChecks: number, backChecks: number) => ({
  point,
  azimuth,
  back,
  azChecks,
  backChecks,
});
const solveCases = [
  // Resection: position set, A done, B half done
  {
    mode: 'resection',
    origin: P(['7', '27', '16.92'], ['110', '26', '23.28']),
    declination: '0',
    sightings: [sg(blank, '60', '240', 1, 1), sg(blank, '150', '', 1, 0)],
  },
  // Resection without a position: nothing opens
  { mode: 'resection', origin: blank, declination: '', sightings: [sg(blank, '60', '', 0, 0), sg(blank, '', '', 0, 0)] },
  // Resection, wrong back azimuth twice: the answer shows
  {
    mode: 'resection',
    origin: P(['7', '27', '0'], ['110', '26', '0']),
    declination: '0.8',
    sightings: [sg(blank, '60', '200', 1, 2), sg(blank, '', '', 0, 0)],
  },
  // Intersection, two positions, a fix
  {
    mode: 'intersection',
    origin: blank,
    declination: '0',
    sightings: [
      sg(P(['7', '27', '36'], ['110', '25', '48']), '45', '225', 1, 1),
      sg(P(['7', '27', '36'], ['110', '27', '0']), '315', '135', 1, 1),
    ],
  },
  // Intersection with declination and a third position
  {
    mode: 'intersection',
    origin: blank,
    declination: '-1.2',
    sightings: [
      sg(P(['7', '27', '36'], ['110', '25', '48']), '45', '225', 1, 1),
      sg(P(['7', '27', '36'], ['110', '27', '0']), '315', '135', 1, 1),
      sg(P(['7', '28', '48'], ['110', '26', '24']), '3', '183', 1, 1),
    ],
  },
  // Intersection: the lines meet behind position A
  {
    mode: 'intersection',
    origin: blank,
    declination: '0',
    sightings: [
      sg(P(['7', '27', '36'], ['110', '25', '48']), '225', '45', 1, 1),
      sg(P(['7', '27', '36'], ['110', '27', '0']), '135', '315', 1, 1),
    ],
  },
  // Intersection: parallel lines; and positions too close; and a bad declination
  {
    mode: 'intersection',
    origin: blank,
    declination: '0',
    sightings: [
      sg(P(['7', '27', '36'], ['110', '25', '48']), '90', '270', 1, 1),
      sg(P(['7', '28', '36'], ['110', '25', '48']), '90', '270', 1, 1),
    ],
  },
  {
    mode: 'intersection',
    origin: blank,
    declination: '45',
    sightings: [
      sg(P(['7', '27', '36'], ['110', '25', '48']), '45', '', 1, 0),
      sg(P(['7', '27', '36.5'], ['110', '25', '48']), '', '', 0, 0),
    ],
  },
  {
    mode: 'intersection',
    origin: blank,
    declination: '0',
    sightings: [sg(P(['7', '27', ''], ['', '', '']), '', '', 0, 0), sg(blank, '', '', 0, 0)],
  },
];
const classicSolve = solveCases.map((c) => ({
  input: c,
  out: CS.solveClassic(c as Parameters<typeof CS.solveClassic>[0]),
}));
const classic = {
  dms: classicDms,
  toDms: classicToDms,
  compass: classicCompass,
  format: classicFormat,
  hints: classicHints,
  points: C.COMPASS_POINTS,
  backChecks,
  fix: classicFix,
  along: classicAlong,
  solve: classicSolve,
};

console.log(JSON.stringify({ geodesic, az, snap, lines, handles, dms, utm, fmt, areas, hav, share, tiles, classic }, null, 1));
