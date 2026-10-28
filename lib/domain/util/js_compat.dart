// Helpers that reproduce JavaScript number behaviour, so text and numbers built here are
// identical to the web app (Landscape 360 web, React).

/// JavaScript `Math.round`: halves round up (towards +∞), so -2.5 becomes -2 (Dart's
/// `round()` would give -3).
double jsRound(double x) {
  if (!x.isFinite) return x;
  final floor = x.floorToDouble();
  return x - floor >= 0.5 ? floor + 1 : floor;
}

/// `Math.round` as an integer string, e.g. for "2958 mdpl"
String jsRoundStr(double x) => jsRound(x).toInt().toString();

/// JavaScript `String(n)` / template literal for a number: 107 → "107", -6.9 → "-6.9"
String jsNum(num n) {
  if (n is int) return n.toString();
  final d = n.toDouble();
  if (d.isNaN) return 'NaN';
  if (d.isInfinite) return d > 0 ? 'Infinity' : '-Infinity';
  if (d == d.truncateToDouble() && d.abs() < 1e21) {
    // -0 prints as "0" in JavaScript
    return d == 0 ? '0' : d.toInt().toString();
  }
  return d.toString();
}

/// JavaScript `Number(value)` for user / URL text: trims, '' becomes 0, anything not a
/// plain decimal number becomes NaN.
double jsNumber(String? value) {
  if (value == null) return double.nan;
  final v = value.trim();
  if (v.isEmpty) return 0;
  if (v == 'Infinity' || v == '+Infinity') return double.infinity;
  if (v == '-Infinity') return double.negativeInfinity;
  if (!RegExp(r'^[+-]?(\d+\.?\d*|\.\d+)([eE][+-]?\d+)?$').hasMatch(v)) return double.nan;
  return double.parse(v);
}

/// JavaScript `%` (sign follows the dividend), unlike Dart's always-positive `%`
double jsMod(double a, double b) => a.remainder(b);

/// First value of [key] in a query string such as "?at=1,2&x=y", like
/// `new URLSearchParams(search).get(key)`; null when absent.
String? queryParam(String search, String key) {
  final query = search.startsWith('?') ? search.substring(1) : search;
  if (query.isEmpty) return null;
  for (final part in query.split('&')) {
    if (part.isEmpty) continue;
    final eq = part.indexOf('=');
    final rawKey = eq < 0 ? part : part.substring(0, eq);
    final rawValue = eq < 0 ? '' : part.substring(eq + 1);
    if (_decode(rawKey) == key) return _decode(rawValue);
  }
  return null;
}

String _decode(String s) {
  final plus = s.replaceAll('+', ' ');
  try {
    return Uri.decodeComponent(plus);
  } on ArgumentError {
    return plus;
  }
}

/// Day/month hour:minute in the phone's time zone, e.g. "26/10 08:05"
String formatDayTime(int ms) {
  final d = DateTime.fromMillisecondsSinceEpoch(ms);
  String pad(int n) => n.toString().padLeft(2, '0');
  return '${pad(d.day)}/${pad(d.month)} ${pad(d.hour)}:${pad(d.minute)}';
}

/// JavaScript `new Date(ms).toISOString()`: "1970-01-01T00:00:05.000Z"
String isoString(int ms) {
  final d = DateTime.fromMillisecondsSinceEpoch(ms, isUtc: true);
  String p(int n, [int w = 2]) => n.toString().padLeft(w, '0');
  return '${p(d.year, 4)}-${p(d.month)}-${p(d.day)}T${p(d.hour)}:${p(d.minute)}:${p(d.second)}.${p(d.millisecond, 3)}Z';
}
