import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:geolocator/geolocator.dart' as geo;
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/providers.dart';
import '../../core/theme/app_theme.dart';
import '../../domain/share/share_location.dart';
import '../../domain/survey/survey_utils.dart';
import '../../domain/util/js_compat.dart';

// Share Location (ShareLocationButton.tsx): one GPS fix of where you are now (not live),
// sent to WhatsApp, another app, or copied. The height comes from the terrain when the map
// has it, which is steadier than the phone's GPS altitude.

/// One position of the phone; tests replace it
typedef PhoneFix = Future<LocationFix> Function();

final phoneFixProvider = Provider<PhoneFix>(
  (ref) => () async {
    if (!await geo.Geolocator.isLocationServiceEnabled()) throw const _LocationError('Turn on Location Services.');
    var p = await geo.Geolocator.checkPermission();
    if (p == geo.LocationPermission.denied) p = await geo.Geolocator.requestPermission();
    if (p == geo.LocationPermission.denied || p == geo.LocationPermission.deniedForever) {
      throw const _LocationError('Location is off for Landscape 360 app. Allow it in Settings.');
    }
    final pos = await geo.Geolocator.getCurrentPosition(
      locationSettings: const geo.LocationSettings(
        accuracy: geo.LocationAccuracy.high,
        timeLimit: Duration(seconds: 15),
      ),
    );
    return LocationFix(
      lat: pos.latitude,
      lng: pos.longitude,
      elevation: pos.altitude == 0 && pos.altitudeAccuracy <= 0 ? null : pos.altitude,
      accuracy: pos.accuracy,
      time: pos.timestamp.millisecondsSinceEpoch,
    );
  },
);

class _LocationError implements Exception {
  const _LocationError(this.message);
  final String message;

  @override
  String toString() => message;
}

Future<void> showShareLocationSheet(
  BuildContext context, {
  Future<double?> Function(double lng, double lat)? terrainAt,
}) => showModalBottomSheet<void>(
  context: context,
  useSafeArea: true,
  builder: (_) => _ShareLocationSheet(terrainAt: terrainAt),
);

class _ShareLocationSheet extends ConsumerStatefulWidget {
  const _ShareLocationSheet({this.terrainAt});

  final Future<double?> Function(double lng, double lat)? terrainAt;

  @override
  ConsumerState<_ShareLocationSheet> createState() => _ShareLocationSheetState();
}

class _ShareLocationSheetState extends ConsumerState<_ShareLocationSheet> {
  LocationFix? _fix;
  String? _error;
  bool _copied = false;

  @override
  void initState() {
    super.initState();
    unawaited(_locate());
  }

  Future<void> _locate() async {
    setState(() {
      _fix = null;
      _error = null;
    });
    try {
      var fix = await ref.read(phoneFixProvider)();
      final terrain = await widget.terrainAt?.call(fix.lng, fix.lat).catchError((Object _) => null);
      if (terrain != null) {
        fix = LocationFix(lat: fix.lat, lng: fix.lng, elevation: terrain, accuracy: fix.accuracy, time: fix.time);
      }
      if (mounted) setState(() => _fix = fix);
    } on TimeoutException {
      if (mounted) setState(() => _error = 'Could not get your location. Try again under open sky.');
    } on Object catch (e) {
      if (mounted) setState(() => _error = e is _LocationError ? e.message : 'Could not get your location: $e');
    }
  }

  String get _text {
    final p = ref.read(profileProvider).value;
    return buildShareLocationText(_fix!, p?.displayName ?? '');
  }

  @override
  Widget build(BuildContext context) {
    final fix = _fix;
    return Padding(
      padding: const EdgeInsets.fromLTRB(L360.gutter, 0, L360.gutter, 20),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('Share Location', style: Theme.of(context).textTheme.titleLarge),
          const Text('Where you are now, once (not live).', style: TextStyle(color: L360Colors.sand600)),
          const SizedBox(height: 14),
          if (_error != null) ...[
            Text(_error!, style: const TextStyle(color: L360Colors.brick500)),
            const SizedBox(height: 10),
            OutlinedButton(onPressed: _locate, child: const Text('Try again')),
          ] else if (fix == null)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 18),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  SizedBox.square(dimension: 18, child: CircularProgressIndicator(strokeWidth: 2)),
                  SizedBox(width: 10),
                  Text('Getting your location…'),
                ],
              ),
            )
          else ...[
            Container(
              key: const Key('share-fix'),
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: L360Colors.sand50,
                border: Border.all(color: L360Colors.sand200),
                borderRadius: BorderRadius.circular(L360.radiusSmall),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '${toDMS(fix.lat, isLat: true)} ${toDMS(fix.lng, isLat: false)}',
                    style: const TextStyle(fontWeight: FontWeight.w700),
                  ),
                  Text(
                    [
                      if (fix.elevation != null) '${jsRoundStr(fix.elevation!)} mdpl',
                      if (fix.accuracy != null) '±${jsRoundStr(fix.accuracy!)} m',
                    ].join(' · '),
                    style: const TextStyle(fontSize: 13, color: L360Colors.sand600),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),
            FilledButton.icon(
              key: const Key('share-whatsapp'),
              style: FilledButton.styleFrom(
                backgroundColor: const Color(0xFF25D366),
                minimumSize: const Size.fromHeight(48),
              ),
              onPressed: () {
                unawaited(launchUrl(Uri.parse(whatsappShareUrl(_text)), mode: LaunchMode.externalApplication));
                Navigator.pop(context);
              },
              icon: const Icon(Icons.chat),
              label: const Text('Send to WhatsApp'),
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    key: const Key('share-other'),
                    onPressed: () async {
                      final r = await SharePlus.instance.share(ShareParams(text: _text, title: 'My location'));
                      if (r.status == ShareResultStatus.success && context.mounted) Navigator.pop(context);
                    },
                    icon: const Icon(Icons.ios_share, size: 18),
                    label: const Text('Other apps'),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: OutlinedButton.icon(
                    key: const Key('share-copy'),
                    onPressed: () async {
                      await Clipboard.setData(ClipboardData(text: _text));
                      setState(() => _copied = true);
                      Future<void>.delayed(const Duration(milliseconds: 1500), () {
                        if (mounted) setState(() => _copied = false);
                      });
                    },
                    icon: Icon(_copied ? Icons.check : Icons.copy, size: 18),
                    label: Text(_copied ? 'Copied' : 'Copy'),
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}
