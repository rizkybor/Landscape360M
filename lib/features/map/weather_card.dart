import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:geolocator/geolocator.dart' as geo;
import 'package:url_launcher/url_launcher.dart';

import '../../core/theme/app_theme.dart';
import '../../core/ui/widgets.dart';
import '../../domain/weather/bmkg.dart';
import '../../domain/weather/villages.dart';
import 'map_tools_state.dart';

IconData weatherIcon(String description) => switch (weatherKind(description)) {
  WeatherKind.sun => Icons.wb_sunny_outlined,
  WeatherKind.cloud => Icons.cloud_outlined,
  WeatherKind.fog => Icons.foggy,
  WeatherKind.rain => Icons.water_drop_outlined,
  WeatherKind.storm => Icons.thunderstorm_outlined,
};

typedef LatLng = ({double lat, double lng});

bool _allowed(geo.LocationPermission p) => p == geo.LocationPermission.always || p == geo.LocationPermission.whileInUse;

/// The user's position. Asks for location the first time (the user opened the weather
/// for their area); null when it is refused or unavailable.
Future<LatLng?> deviceLocation() async {
  try {
    var permission = await geo.Geolocator.checkPermission();
    if (permission == geo.LocationPermission.denied) permission = await geo.Geolocator.requestPermission();
    if (!_allowed(permission)) return null;
    final p =
        await geo.Geolocator.getLastKnownPosition() ??
        await geo.Geolocator.getCurrentPosition(
          locationSettings: const geo.LocationSettings(
            accuracy: geo.LocationAccuracy.medium,
            timeLimit: Duration(seconds: 8),
          ),
        );
    return (lat: p.latitude, lng: p.longitude);
  } on Object {
    return null;
  }
}

/// BMKG weather over the map, like the web's WeatherWidget: now, and the next 3 days, for
/// the village nearest to the user (or to the map centre without location). The web always
/// shows Kemayoran. Tapping the header shrinks it to a pill; it refreshes every 30 minutes.
class WeatherCard extends ConsumerStatefulWidget {
  const WeatherCard({super.key, this.now, this.mapCenter, this.locate = deviceLocation});

  final DateTime Function()? now;

  /// Centre of the map, used when the user's position is not available
  final LatLng Function()? mapCenter;

  final Future<LatLng?> Function() locate;

  @override
  ConsumerState<WeatherCard> createState() => _WeatherCardState();
}

class _WeatherCardState extends ConsumerState<WeatherCard> {
  WeatherReport? _report;
  String? _source; // where the forecast is for: near the user, map centre, or the fallback
  String? _error;
  bool _loading = true;
  bool _minimized = false;
  Timer? _refresh;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
    _refresh = Timer.periodic(const Duration(minutes: 30), (_) => unawaited(_load()));
  }

  @override
  void dispose() {
    _refresh?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final service = ref.read(weatherServiceProvider);
      final now = widget.now?.call();
      final gps = await widget.locate();
      final at = gps ?? widget.mapCenter?.call();
      final index = at == null
          ? null
          : await ref.read(villageIndexProvider.future).catchError((Object _) => VillageIndex(const []));
      final candidates = at == null || index == null ? const <Village>[] : index.nearest(at.lat, at.lng);
      WeatherReport? report;
      // The nearest village first; if BMKG does not know its code (a newer split), the next
      for (final v in candidates) {
        try {
          report = await service.forecast(adm4: v.code, now: now);
          break;
        } on WeatherException {
          continue;
        }
      }
      final fallback = report == null;
      report ??= await service.forecast(now: now);
      if (mounted) {
        setState(() {
          _report = report;
          _source = fallback
              ? (candidates.isEmpty ? 'Outside BMKG coverage · Jakarta Pusat' : 'Default location')
              : gps != null
              ? 'Near your location'
              : 'Map centre';
        });
      }
    } on WeatherException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  /// "Use my location" after location was refused: ask again, or open Settings when the
  /// phone no longer asks
  Future<void> _useMyLocation() async {
    try {
      final p = await geo.Geolocator.checkPermission();
      if (p == geo.LocationPermission.deniedForever) {
        await geo.Geolocator.openAppSettings();
        return;
      }
      await geo.Geolocator.requestPermission();
    } on Object {
      // Location not available on this device
    }
    await _load();
  }

  void _toggleSize() {
    HapticFeedback.selectionClick();
    setState(() => _minimized = !_minimized);
  }

  @override
  Widget build(BuildContext context) {
    final r = _report;
    if (_minimized) {
      return GestureDetector(
        key: const Key('weather-pill'),
        onTap: _toggleSize,
        child: GlassPanel(
          radius: 20,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                r == null ? Icons.cloud_outlined : weatherIcon(r.current.description),
                size: 18,
                color: L360Colors.gold700,
              ),
              const SizedBox(width: 6),
              Text(
                r == null ? 'Cuaca' : '${r.current.temperature.toStringAsFixed(0)}°C · ${r.current.description}',
                style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
              ),
              const SizedBox(width: 4),
              const Icon(Icons.expand_more, size: 16, color: L360Colors.sand500),
            ],
          ),
        ),
      );
    }
    return GlassPanel(
      key: const Key('weather-card'),
      child: SizedBox(
        width: 230,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            InkWell(
              onTap: _toggleSize,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 10, 4, 6),
                child: Row(
                  children: [
                    const Icon(Icons.place_outlined, size: 14, color: L360Colors.forest700),
                    const SizedBox(width: 4),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            r?.location ?? 'Finding your area…',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700),
                          ),
                          if (r != null)
                            Text(
                              [?r.region, ?_source].join(' · '),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(fontSize: 10, color: L360Colors.sand500),
                            ),
                        ],
                      ),
                    ),
                    const Icon(Icons.expand_less, size: 18, color: L360Colors.sand500),
                    IconButton(
                      tooltip: 'Close weather',
                      visualDensity: VisualDensity.compact,
                      iconSize: 16,
                      icon: const Icon(Icons.close, color: L360Colors.sand500),
                      onPressed: () => ref.read(weatherShownProvider.notifier).hide(),
                    ),
                  ],
                ),
              ),
            ),
            if (_loading && r == null)
              const Padding(
                padding: EdgeInsets.all(20),
                child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
              )
            else if (_error != null && r == null)
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
                child: Column(
                  children: [
                    Text(_error!, style: const TextStyle(fontSize: 12, color: L360Colors.brick500)),
                    TextButton(onPressed: _load, child: const Text('Try again')),
                  ],
                ),
              )
            else if (r != null) ...[
              if (_source == 'Map centre')
                Padding(
                  padding: const EdgeInsets.fromLTRB(8, 0, 8, 4),
                  child: TextButton.icon(
                    key: const Key('weather-use-location'),
                    style: TextButton.styleFrom(visualDensity: VisualDensity.compact),
                    onPressed: _useMyLocation,
                    icon: const Icon(Icons.my_location, size: 14),
                    label: const Text('Use my location', style: TextStyle(fontSize: 12)),
                  ),
                ),
              _Now(sample: r.current),
              const Padding(padding: EdgeInsets.symmetric(horizontal: 12), child: Divider()),
              const Padding(
                padding: EdgeInsets.fromLTRB(12, 8, 12, 4),
                child: Row(
                  children: [
                    Icon(Icons.calendar_today_outlined, size: 11, color: L360Colors.sand500),
                    SizedBox(width: 4),
                    Text(
                      '3 HARI KEDEPAN',
                      style: TextStyle(
                        fontSize: 10,
                        letterSpacing: 1,
                        fontWeight: FontWeight.w700,
                        color: L360Colors.sand500,
                      ),
                    ),
                  ],
                ),
              ),
              for (final d in r.days) _Day(day: d),
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 4, 12, 10),
                child: GestureDetector(
                  onTap: () => launchUrl(Uri.parse('https://www.bmkg.go.id/'), mode: LaunchMode.externalApplication),
                  child: const Text(
                    'Sumber: BMKG · Wilayah: BIG',
                    textAlign: TextAlign.right,
                    style: TextStyle(fontSize: 10, color: L360Colors.sand500, decoration: TextDecoration.underline),
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _Now extends StatelessWidget {
  const _Now({required this.sample});

  final WeatherSample sample;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(12, 0, 12, 10),
    child: Row(
      children: [
        Icon(weatherIcon(sample.description), size: 36, color: L360Colors.gold500),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '${sample.temperature.toStringAsFixed(0)}°C',
                style: const TextStyle(fontSize: 26, fontWeight: FontWeight.w700, height: 1.1),
              ),
              Text(sample.description, style: const TextStyle(fontSize: 12, color: L360Colors.sand600)),
            ],
          ),
        ),
        Column(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            _Stat(icon: Icons.water_drop_outlined, text: '${sample.humidity.toStringAsFixed(0)}%'),
            const SizedBox(height: 4),
            _Stat(icon: Icons.air, text: '${_trim(sample.windSpeed)} km/h'),
          ],
        ),
      ],
    ),
  );
}

String _trim(double v) => v == v.roundToDouble() ? v.toInt().toString() : v.toString();

class _Stat extends StatelessWidget {
  const _Stat({required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      Icon(icon, size: 12, color: L360Colors.sand500),
      const SizedBox(width: 3),
      Text(text, style: const TextStyle(fontSize: 11, color: L360Colors.sand700)),
    ],
  );
}

class _Day extends StatelessWidget {
  const _Day({required this.day});

  final DailyForecast day;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 3),
    child: Row(
      children: [
        SizedBox(width: 56, child: Text(day.dayName, style: const TextStyle(fontSize: 12))),
        Icon(weatherIcon(day.description), size: 16, color: L360Colors.gold500),
        const SizedBox(width: 6),
        Expanded(
          child: Text(
            day.description,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 11, color: L360Colors.sand600),
          ),
        ),
        Text(
          '${day.min.toStringAsFixed(0)}° / ${day.max.toStringAsFixed(0)}°',
          style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
        ),
      ],
    ),
  );
}
