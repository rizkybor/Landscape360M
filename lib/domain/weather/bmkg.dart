// BMKG weather forecast, port of src/components/WeatherWidget.tsx (web). The web always
// shows Kemayoran, Jakarta Pusat; the app asks for the village nearest to the user (see
// villages.dart) and keeps Kemayoran only as the fallback.

const bmkgDefaultAdm4 = '31.71.03.1001';
const bmkgDefaultLocation = 'Jakarta Pusat';

Uri bmkgForecastUrl([String adm4 = bmkgDefaultAdm4]) =>
    Uri.https('api.bmkg.go.id', '/publik/prakiraan-cuaca', {'adm4': adm4});

/// How the weather is drawn (the web's icon per BMKG description)
enum WeatherKind { sun, cloud, fog, rain, storm }

WeatherKind weatherKind(String description) => switch (description) {
  'Cerah' || 'Cerah Berawan' => WeatherKind.sun,
  'Berawan' || 'Berawan Tebal' => WeatherKind.cloud,
  'Udara Kabur' || 'Kabut' => WeatherKind.fog,
  'Hujan Ringan' || 'Hujan Sedang' => WeatherKind.rain,
  'Hujan Lebat' || 'Hujan Petir' => WeatherKind.storm,
  _ => WeatherKind.cloud,
};

class WeatherSample {
  const WeatherSample({
    required this.time,
    required this.temperature,
    required this.humidity,
    required this.description,
    required this.windSpeed,
    required this.windDirection,
  });

  final DateTime time; // local time of the place
  final double temperature; // °C
  final double humidity; // %
  final String description;
  final double windSpeed; // km/h
  final String windDirection;
}

class DailyForecast {
  const DailyForecast({
    required this.date,
    required this.dayName,
    required this.dayShort,
    required this.min,
    required this.max,
    required this.description,
  });

  final String date; // yyyy-mm-dd
  final String dayName; // "Senin"
  final String dayShort; // "Sen"
  final double min;
  final double max;
  final String description;
}

class WeatherReport {
  const WeatherReport({required this.location, required this.current, required this.days, this.region});

  final String location; // "Cipete Utara, Kebayoran Baru"
  final String? region; // "Kota Adm. Jakarta Selatan"
  final WeatherSample current;
  final List<DailyForecast> days;
}

class WeatherException implements Exception {
  const WeatherException(this.message);
  final String message;

  @override
  String toString() => message;
}

const _dayNames = ['Senin', 'Selasa', 'Rabu', 'Kamis', 'Jumat', 'Sabtu', 'Minggu'];
const _dayShort = ['Sen', 'Sel', 'Rab', 'Kam', 'Jum', 'Sab', 'Min'];

double _num(Object? v) => v is num ? v.toDouble() : double.tryParse('$v') ?? 0;

/// Current conditions (the forecast hour nearest to [now]) and the next 3 days
WeatherReport parseBmkg(Object? json, DateTime now) {
  final data = json is Map ? json['data'] : null;
  final first = data is List && data.isNotEmpty ? data.first : null;
  if (first is! Map) throw const WeatherException('Gagal memuat data cuaca.');
  // BMKG names the city field "kotkab"; the web reads "kotakab", which is always empty, so
  // it always shows its fallback. Both are read here.
  final lokasi = first['lokasi'] is Map
      ? first['lokasi'] as Map
      : (json as Map)['lokasi'] is Map
      ? json['lokasi'] as Map
      : const {};
  String? text(Object? v) => v is String && v.trim().isNotEmpty ? v.trim() : null;
  final desa = text(lokasi['desa']), kecamatan = text(lokasi['kecamatan']);
  final city = text(lokasi['kotkab']) ?? text(lokasi['kotakab']);
  final cuaca = first['cuaca'];
  final samples = <WeatherSample>[];
  void collect(Object? node) {
    if (node is List) {
      node.forEach(collect);
    } else if (node is Map) {
      final when = DateTime.tryParse('${node['local_datetime']}'.replaceFirst(' ', 'T'));
      if (when == null) return;
      samples.add(
        WeatherSample(
          time: when,
          temperature: _num(node['t']),
          humidity: _num(node['hu']),
          description: '${node['weather_desc'] ?? ''}',
          windSpeed: _num(node['ws']),
          windDirection: '${node['wd'] ?? ''}',
        ),
      );
    }
  }

  collect(cuaca);
  if (samples.isEmpty) throw const WeatherException('Gagal memuat data cuaca.');

  final current = samples.reduce(
    (a, b) => (b.time.difference(now).inSeconds.abs() < a.time.difference(now).inSeconds.abs()) ? b : a,
  );

  // Group by day in the order BMKG sends them, first 3 days
  final byDay = <String, List<WeatherSample>>{};
  for (final s in samples) {
    final key = s.time.toIso8601String().substring(0, 10);
    byDay.putIfAbsent(key, () => []).add(s);
  }
  final days = [
    for (final entry in byDay.entries.take(3))
      () {
        final list = entry.value;
        final temps = list.map((s) => s.temperature);
        final weekday = DateTime.parse(entry.key).weekday - 1;
        return DailyForecast(
          date: entry.key,
          dayName: _dayNames[weekday],
          dayShort: _dayShort[weekday],
          min: temps.reduce((a, b) => a < b ? a : b),
          max: temps.reduce((a, b) => a > b ? a : b),
          // The web takes the middle sample of the day
          description: list[list.length ~/ 2].description.isEmpty ? 'Berawan' : list[list.length ~/ 2].description,
        );
      }(),
  ];

  return WeatherReport(
    location: desa != null ? [desa, ?kecamatan].join(', ') : city ?? bmkgDefaultLocation,
    region: desa != null ? city : null,
    current: current,
    days: days,
  );
}
