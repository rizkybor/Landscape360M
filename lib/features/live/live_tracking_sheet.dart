import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers.dart';
import '../../core/theme/app_theme.dart';
import '../../data/tracks/gps_source.dart';
import '../tracks/track_recorder_state.dart' show gpsSourceProvider, trackClockProvider;
import 'live_tracking_state.dart';

// GPS Tracking's sheet (Tools > GPS) and the LIVE pill on the map while it is on

Future<void> showLiveTrackingSheet(BuildContext context) =>
    showModalBottomSheet<void>(context: context, useSafeArea: true, builder: (context) => const _LiveSheet());

String _ago(int ms) {
  final s = (ms / 1000).round();
  if (s < 5) return 'just now';
  if (s < 60) return '$s s ago';
  return '${(s / 60).floor()} min ago';
}

class _LiveSheet extends ConsumerWidget {
  const _LiveSheet();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(liveTrackingProvider);
    final profile = ref.watch(profileProvider).value;
    final allowed = profile?.canBroadcast ?? false;
    final ctrl = ref.read(liveTrackingProvider.notifier);
    final (dot, line) = switch (s.status) {
      LiveStatus.off => (L360Colors.sand300, 'Not sharing'),
      LiveStatus.starting => (L360Colors.gold400, 'Starting…'),
      LiveStatus.live => (
        L360Colors.forest500,
        'Sharing · sent ${_ago(ref.read(trackClockProvider)() - (s.sentAt ?? 0))}',
      ),
      LiveStatus.waiting => (L360Colors.gold400, 'No signal · sends again when it is back'),
      LiveStatus.refused => (L360Colors.brick500, 'Not accepted by the server'),
    };
    // Scrolls on small phones with large text
    return SingleChildScrollView(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(L360.gutter, 4, L360.gutter, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text('GPS Tracking', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
            const SizedBox(height: 4),
            const Text(
              'Share your live position with your team\'s monitors, also with the screen off. '
              'Only monitor accounts can see it.',
              style: TextStyle(fontSize: 13, color: L360Colors.sand600),
            ),
            const SizedBox(height: 14),
            if (!allowed)
              Container(
                key: const Key('live-locked'),
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: L360Colors.sand50,
                  borderRadius: BorderRadius.circular(L360.radiusSmall),
                  border: Border.all(color: L360Colors.sand200),
                ),
                child: Text(
                  profile == null
                      ? 'Sign in to share your position with your team.'
                      : 'GPS Tracking is available for Pro and Enterprise accounts. Contact your admin to upgrade.',
                  style: const TextStyle(fontSize: 13, color: L360Colors.sand700),
                ),
              )
            else ...[
              Row(
                children: [
                  Container(
                    width: 10,
                    height: 10,
                    decoration: BoxDecoration(shape: BoxShape.circle, color: dot),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      line,
                      key: const Key('live-status'),
                      style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
                    ),
                  ),
                ],
              ),
              if (s.gpsError != null || s.error != null) ...[
                const SizedBox(height: 6),
                Text(
                  s.gpsError ?? s.error!,
                  key: const Key('live-error'),
                  style: const TextStyle(fontSize: 12, color: L360Colors.brick500),
                ),
              ],
              const SizedBox(height: 14),
              if (s.on)
                OutlinedButton.icon(
                  key: const Key('live-stop'),
                  onPressed: () => unawaited(ctrl.stop()),
                  icon: const Icon(Icons.stop_circle_outlined),
                  label: const Text('Stop sharing'),
                )
              else
                FilledButton.icon(
                  key: const Key('live-start'),
                  onPressed: () async {
                    final ok = await ctrl.start();
                    if (!ok && context.mounted && ref.read(liveTrackingProvider).gpsError != null) {
                      final gps = ref.read(gpsSourceProvider);
                      if (await gps.access() == GpsAccess.deniedForever) unawaited(gps.openSettings());
                    }
                  },
                  icon: const Icon(Icons.navigation_outlined),
                  label: const Text('Start sharing'),
                ),
            ],
          ],
        ),
      ),
    );
  }
}

/// On the map while the position is shared; opens the sheet
class LivePill extends ConsumerWidget {
  const LivePill({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(liveTrackingProvider);
    if (!s.on) return const SizedBox.shrink();
    final ok = s.status == LiveStatus.live || s.status == LiveStatus.starting;
    return Center(
      child: Material(
        key: const Key('live-pill'),
        color: Colors.white,
        elevation: 4,
        shadowColor: const Color(0x40000000),
        shape: const StadiumBorder(side: BorderSide(color: L360Colors.forest200)),
        child: InkWell(
          customBorder: const StadiumBorder(),
          onTap: () => showLiveTrackingSheet(context),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.navigation, size: 14, color: ok ? L360Colors.forest600 : L360Colors.gold500),
                const SizedBox(width: 8),
                Text(
                  ok ? 'LIVE · sharing your position' : 'LIVE · waiting for signal',
                  style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w800),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
