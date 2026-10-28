import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:share_plus/share_plus.dart';

import '../../core/providers.dart';
import '../../core/theme/app_theme.dart';
import '../../data/tracks/gps_source.dart';
import '../../domain/tracks/recorded_track.dart';
import '../../domain/tracks/track_recorder_geo.dart';
import 'track_recorder_state.dart';

// The Track Recorder above the sheet (TrackRecorderPanel.tsx): start a recording, its live
// stats and controls, and a small REC pill while the panel is closed. Saved and shared
// tracks open in a sheet.

const contactAdminLabel = 'Hubungi Admin';

String _gpsLabel(GpsStatus s) => switch (s) {
  GpsStatus.idle => 'GPS idle',
  GpsStatus.searching => 'Searching for GPS signal…',
  GpsStatus.ok => 'GPS locked',
  GpsStatus.denied => 'Location permission is off. Allow it in Settings, then press Resume.',
  GpsStatus.unavailable => 'GPS unavailable. Turn on Location Services.',
  GpsStatus.error => 'GPS error',
};

/// Re-renders every second while [active], so the timer stays live
class _Ticker extends StatefulWidget {
  const _Ticker({required this.active, required this.builder});

  final bool active;
  final WidgetBuilder builder;

  @override
  State<_Ticker> createState() => _TickerState();
}

class _TickerState extends State<_Ticker> {
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _sync();
  }

  @override
  void didUpdateWidget(_Ticker old) {
    super.didUpdateWidget(old);
    _sync();
  }

  void _sync() {
    if (widget.active && _timer == null) {
      _timer = Timer.periodic(const Duration(seconds: 1), (_) => setState(() {}));
    } else if (!widget.active) {
      _timer?.cancel();
      _timer = null;
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.builder(context);
}

int _nowMs() => DateTime.now().millisecondsSinceEpoch;

/// Location permission before the first recording, with the reason shown first
Future<bool> ensureTrackGps(BuildContext context, GpsSource gps) async {
  final access = await gps.access();
  if (access == GpsAccess.allowed) return true;
  if (!context.mounted) return false;
  if (access == GpsAccess.servicesOff) {
    await _info(context, 'Location Services are off', 'Turn on Location Services in Settings to record a track.');
    return false;
  }
  if (access == GpsAccess.deniedForever) {
    final open = await _ask(
      context,
      'Location is off for Landscape 360 app',
      'Recording a track needs your location. Allow it in Settings (While Using the App is enough).',
      'Open Settings',
    );
    if (open) await gps.openSettings();
    return false;
  }
  final go = await _ask(
    context,
    'Allow location to record',
    'Landscape 360 app uses your location to draw your track. Recording keeps going when the screen is '
        'off or you switch apps: iPhone shows the location indicator, Android shows a notification. '
        'Your track stays on this phone and only goes to your own account.',
    'Continue',
  );
  if (!go) return false;
  return await gps.request() == GpsAccess.allowed;
}

Future<void> _info(BuildContext context, String title, String body) => showDialog<void>(
  context: context,
  builder: (context) => AlertDialog.adaptive(
    title: Text(title),
    content: Text(body),
    actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('OK'))],
  ),
);

Future<bool> _ask(BuildContext context, String title, String body, String action, {bool destructive = false}) async =>
    await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog.adaptive(
        title: Text(title),
        content: Text(body),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            style: destructive ? TextButton.styleFrom(foregroundColor: L360Colors.brick500) : null,
            child: Text(action),
          ),
        ],
      ),
    ) ??
    false;

class TrackRecorderPanel extends ConsumerStatefulWidget {
  const TrackRecorderPanel({super.key});

  @override
  ConsumerState<TrackRecorderPanel> createState() => _TrackRecorderPanelState();
}

class _TrackRecorderPanelState extends ConsumerState<TrackRecorderPanel> {
  final _name = TextEditingController();
  TrackMode _mode = TrackMode.online;
  bool _starting = false;

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  Future<void> _start() async {
    if (_starting) return;
    setState(() => _starting = true);
    try {
      if (!await ensureTrackGps(context, ref.read(gpsSourceProvider))) return;
      unawaited(HapticFeedback.mediumImpact());
      await ref.read(trackRecorderProvider.notifier).start(_name.text, _mode);
      _name.clear();
      if (mounted) FocusScope.of(context).unfocus();
    } finally {
      if (mounted) setState(() => _starting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = ref.watch(trackRecorderProvider);
    final rec = ref.read(trackRecorderProvider.notifier);
    final profile = ref.watch(profileProvider).value;
    final canRecord = profile?.canRecordTracks ?? false;
    final online = ref.watch(onlineProvider).value ?? true;
    final active = s.active;
    return Material(
      key: const Key('track-panel'),
      color: Colors.white,
      elevation: 6,
      shadowColor: const Color(0x40000000),
      borderRadius: BorderRadius.circular(L360.radius),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 8, 4, 12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                const Icon(Icons.directions_walk, size: 20, color: L360Colors.ember600),
                const SizedBox(width: 8),
                const Expanded(
                  child: Text('Track Recorder', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700)),
                ),
                Tooltip(
                  message: online ? 'Online' : 'No signal: recording continues on this phone',
                  triggerMode: TooltipTriggerMode.tap,
                  child: Icon(
                    online ? Icons.wifi : Icons.wifi_off,
                    key: const Key('track-online'),
                    size: 18,
                    color: online ? L360Colors.forest600 : L360Colors.brick500,
                  ),
                ),
                IconButton(
                  key: const Key('track-list'),
                  tooltip: 'My tracks',
                  visualDensity: VisualDensity.compact,
                  icon: const Icon(Icons.folder_open_outlined, size: 20),
                  onPressed: () => showTracksSheet(context),
                ),
                IconButton(
                  key: const Key('track-close'),
                  tooltip: active == null ? 'Close' : 'Hide (recording continues)',
                  visualDensity: VisualDensity.compact,
                  icon: const Icon(Icons.close, size: 20),
                  onPressed: () => rec.setPanelOpen(false),
                ),
              ],
            ),
            if (s.error != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(0, 2, 10, 4),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: Text(s.error!, style: const TextStyle(fontSize: 12, color: L360Colors.brick500)),
                    ),
                    GestureDetector(
                      onTap: rec.clearError,
                      child: const Icon(Icons.close, size: 14, color: L360Colors.brick500),
                    ),
                  ],
                ),
              ),
            const SizedBox(height: 6),
            Padding(
              padding: const EdgeInsets.only(right: 10),
              child: active != null
                  ? _Recording(state: s, canRecord: canRecord, online: online)
                  : canRecord
                  ? _StartForm(
                      name: _name,
                      mode: _mode,
                      online: online,
                      starting: _starting,
                      onMode: (m) => setState(() => _mode = m),
                      onStart: _start,
                    )
                  : const _Locked(),
            ),
          ],
        ),
      ),
    );
  }
}

class _Locked extends StatelessWidget {
  const _Locked();

  @override
  Widget build(BuildContext context) => const Padding(
    padding: EdgeInsets.symmetric(vertical: 4),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(Icons.lock_outline, size: 20, color: L360Colors.sand500),
        SizedBox(width: 10),
        Expanded(
          child: Text.rich(
            TextSpan(
              children: [
                TextSpan(text: 'Recording tracks is available for Enterprise accounts. '),
                TextSpan(
                  text: contactAdminLabel,
                  style: TextStyle(fontWeight: FontWeight.w700, color: L360Colors.ember600),
                ),
                TextSpan(text: ' to enable it. You can still view your tracks and tracks shared with you.'),
              ],
            ),
            style: TextStyle(fontSize: 13, color: L360Colors.sand700, height: 1.35),
          ),
        ),
      ],
    ),
  );
}

class _StartForm extends StatelessWidget {
  const _StartForm({
    required this.name,
    required this.mode,
    required this.online,
    required this.starting,
    required this.onMode,
    required this.onStart,
  });

  final TextEditingController name;
  final TrackMode mode;
  final bool online;
  final bool starting;
  final ValueChanged<TrackMode> onMode;
  final VoidCallback onStart;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      TextField(
        key: const Key('track-name'),
        controller: name,
        maxLength: 120,
        textInputAction: TextInputAction.done,
        decoration: const InputDecoration(
          hintText: 'Track name (optional)',
          counterText: '',
          isDense: true,
          contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 11),
        ),
      ),
      const SizedBox(height: 8),
      Row(
        children: [
          for (final (m, icon, title, desc) in [
            (TrackMode.online, Icons.cloud_outlined, 'Online', 'Synced to the cloud automatically'),
            (TrackMode.offline, Icons.phone_iphone, 'Offline', 'On this phone only, upload later'),
          ]) ...[
            if (m == TrackMode.offline) const SizedBox(width: 8),
            Expanded(
              child: _ModeCard(
                key: Key('track-mode-${m.name}'),
                icon: icon,
                title: title,
                desc: desc,
                selected: mode == m,
                onTap: () {
                  HapticFeedback.selectionClick();
                  onMode(m);
                },
              ),
            ),
          ],
        ],
      ),
      if (mode == TrackMode.online && !online)
        const Padding(
          padding: EdgeInsets.only(top: 6),
          child: Text(
            'No signal right now. Recording works anyway; it syncs when the connection returns.',
            style: TextStyle(fontSize: 11, color: L360Colors.gold700),
          ),
        ),
      const SizedBox(height: 10),
      FilledButton.icon(
        key: const Key('track-start'),
        style: FilledButton.styleFrom(
          backgroundColor: L360Colors.ember600,
          minimumSize: const Size.fromHeight(46),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(L360.radiusSmall)),
        ),
        onPressed: starting ? null : onStart,
        icon: const Icon(Icons.fiber_manual_record, size: 16),
        label: const Text('Start Recording', style: TextStyle(fontWeight: FontWeight.w700)),
      ),
    ],
  );
}

class _ModeCard extends StatelessWidget {
  const _ModeCard({
    super.key,
    required this.icon,
    required this.title,
    required this.desc,
    required this.selected,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final String desc;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Material(
    color: selected ? const Color(0xFFFDF1E9) : L360Colors.sand50,
    shape: RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(L360.radiusSmall),
      side: BorderSide(color: selected ? L360Colors.ember500 : L360Colors.sand200, width: selected ? 1.5 : 1),
    ),
    child: InkWell(
      borderRadius: BorderRadius.circular(L360.radiusSmall),
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(10, 8, 8, 9),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(icon, size: 16, color: selected ? L360Colors.ember600 : L360Colors.sand600),
                const SizedBox(width: 6),
                Text(title, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700)),
              ],
            ),
            const SizedBox(height: 2),
            Text(desc, style: const TextStyle(fontSize: 11, color: L360Colors.sand600, height: 1.25)),
          ],
        ),
      ),
    ),
  );
}

class _Recording extends ConsumerWidget {
  const _Recording({required this.state, required this.canRecord, required this.online});

  final TrackRecorderState state;
  final bool canRecord;
  final bool online;

  String _syncLine(RecordedTrack t) {
    if (t.mode == TrackMode.offline) return 'Saved on this phone';
    if (t.syncStatus == TrackSyncStatus.synced && t.syncedAt != null) {
      final d = DateTime.fromMillisecondsSinceEpoch(t.syncedAt!);
      String p(int n) => n.toString().padLeft(2, '0');
      return 'Synced to the cloud at ${p(d.hour)}:${p(d.minute)}:${p(d.second)}';
    }
    if (t.syncStatus == TrackSyncStatus.error) return 'Cloud sync failed, will retry: ${t.syncError ?? ''}';
    return online ? 'Syncing to the cloud every minute' : 'Saved on this phone · syncs when back online';
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = state.active!;
    final rec = ref.read(trackRecorderProvider.notifier);
    final recording = state.recording;
    final fix = state.currentFix;
    final st = t.stats;
    final gpsBad = state.gpsStatus == GpsStatus.denied || state.gpsStatus == GpsStatus.unavailable;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            _RecDot(recording: recording),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Text(
                        recording ? 'Recording' : 'Paused',
                        style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700),
                      ),
                      const SizedBox(width: 6),
                      _Tag(t.mode.name.toUpperCase()),
                    ],
                  ),
                  Text(
                    t.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 12, color: L360Colors.sand600),
                  ),
                ],
              ),
            ),
            _Ticker(
              active: recording,
              builder: (_) => Text(
                formatDuration(t.elapsedAt(_nowMs())),
                key: const Key('track-elapsed'),
                style: const TextStyle(
                  fontSize: 24,
                  fontWeight: FontWeight.w700,
                  fontFeatures: [FontFeature.tabularFigures()],
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 10),
        GridView.count(
          crossAxisCount: 3,
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          mainAxisSpacing: 6,
          crossAxisSpacing: 6,
          childAspectRatio: 2.3,
          padding: EdgeInsets.zero,
          children: [
            _Stat('Distance', formatTrackDistance(st.distanceM)),
            _Stat('Moving', formatDuration(st.movingTimeMs)),
            _Stat('Avg speed', '${t.avgSpeedKmh.toStringAsFixed(1)} km/h'),
            _Stat('Gain', '↑ ${st.elevationGainM.round()} m'),
            _Stat('Loss', '↓ ${st.elevationLossM.round()} m'),
            _Stat('Altitude', fix?.alt == null ? '—' : '${fix!.alt!.round()} m'),
          ],
        ),
        const SizedBox(height: 8),
        Text(
          '${_gpsLabel(state.gpsStatus)}'
          '${state.gpsStatus == GpsStatus.ok && fix != null ? ' · ±${fix.accuracy.round()} m' : ''}'
          ' · ${st.pointCount} points',
          style: TextStyle(fontSize: 11, color: gpsBad ? L360Colors.brick500 : L360Colors.sand600),
        ),
        Text(_syncLine(t), style: const TextStyle(fontSize: 11, color: L360Colors.sand600)),
        const SizedBox(height: 10),
        Row(
          children: [
            Expanded(
              child: _ActionButton(
                key: const Key('track-pause'),
                icon: recording ? Icons.pause : Icons.play_arrow,
                label: recording ? 'Pause' : 'Resume',
                background: L360Colors.sand100,
                foreground: L360Colors.ink,
                onPressed: !recording && !canRecord
                    ? null
                    : () async {
                        unawaited(HapticFeedback.selectionClick());
                        if (recording) {
                          await rec.pause();
                        } else if (await ensureTrackGps(context, ref.read(gpsSourceProvider))) {
                          await rec.resume();
                        }
                      },
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: _ActionButton(
                key: const Key('track-finish'),
                icon: Icons.stop,
                label: 'Finish',
                background: L360Colors.forest700,
                foreground: Colors.white,
                onPressed: () async {
                  if (!await _ask(context, 'Finish and save this track?', t.name, 'Save Track')) return;
                  unawaited(HapticFeedback.mediumImpact());
                  await rec.stop();
                },
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: _ActionButton(
                key: const Key('track-discard'),
                icon: Icons.delete_outline,
                label: 'Discard',
                background: L360Colors.brick50,
                foreground: L360Colors.brick500,
                onPressed: () async {
                  if (!await _ask(
                    context,
                    'Discard this recording?',
                    'All its points are deleted.',
                    'Discard',
                    destructive: true,
                  )) {
                    return;
                  }
                  await rec.discard();
                },
              ),
            ),
          ],
        ),
        if (!recording && !canRecord)
          const Padding(
            padding: EdgeInsets.only(top: 6),
            child: Text(
              'Recording needs Enterprise. $contactAdminLabel. You can still finish and save this track.',
              style: TextStyle(fontSize: 11, color: L360Colors.sand600),
            ),
          ),
      ],
    );
  }
}

class _RecDot extends StatefulWidget {
  const _RecDot({required this.recording});

  final bool recording;

  @override
  State<_RecDot> createState() => _RecDotState();
}

class _RecDotState extends State<_RecDot> with SingleTickerProviderStateMixin {
  late final _pulse = AnimationController(vsync: this, duration: const Duration(milliseconds: 900));

  @override
  void initState() {
    super.initState();
    if (widget.recording) _pulse.repeat(reverse: true);
  }

  @override
  void didUpdateWidget(_RecDot old) {
    super.didUpdateWidget(old);
    if (widget.recording && !_pulse.isAnimating) {
      _pulse.repeat(reverse: true);
    } else if (!widget.recording) {
      _pulse.stop();
      _pulse.value = 1;
    }
  }

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => FadeTransition(
    opacity: widget.recording ? Tween<double>(begin: 0.35, end: 1).animate(_pulse) : const AlwaysStoppedAnimation(1),
    child: Container(
      width: 10,
      height: 10,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: widget.recording ? L360Colors.brick500 : L360Colors.gold400,
      ),
    ),
  );
}

class _Tag extends StatelessWidget {
  const _Tag(this.text, {this.background = L360Colors.sand100, this.foreground = L360Colors.sand700});

  final String text;
  final Color background;
  final Color foreground;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
    decoration: BoxDecoration(color: background, borderRadius: BorderRadius.circular(6)),
    child: Text(
      text,
      style: TextStyle(fontSize: 9.5, fontWeight: FontWeight.w700, color: foreground, letterSpacing: 0.3),
    ),
  );
}

class _Stat extends StatelessWidget {
  const _Stat(this.label, this.value);

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
    decoration: BoxDecoration(color: L360Colors.sand50, borderRadius: BorderRadius.circular(10)),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Text(
          label.toUpperCase(),
          style: const TextStyle(
            fontSize: 9,
            fontWeight: FontWeight.w700,
            color: L360Colors.sand500,
            letterSpacing: 0.5,
          ),
        ),
        FittedBox(
          fit: BoxFit.scaleDown,
          alignment: Alignment.centerLeft,
          child: Text(
            value,
            style: const TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w700,
              fontFeatures: [FontFeature.tabularFigures()],
            ),
          ),
        ),
      ],
    ),
  );
}

class _ActionButton extends StatelessWidget {
  const _ActionButton({
    super.key,
    required this.icon,
    required this.label,
    required this.background,
    required this.foreground,
    required this.onPressed,
  });

  final IconData icon;
  final String label;
  final Color background;
  final Color foreground;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) => FilledButton.icon(
    style: FilledButton.styleFrom(
      backgroundColor: background,
      foregroundColor: foreground,
      minimumSize: const Size.fromHeight(42),
      padding: const EdgeInsets.symmetric(horizontal: 6),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(L360.radiusSmall)),
    ),
    onPressed: onPressed,
    icon: Icon(icon, size: 18),
    label: Text(label, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700)),
  );
}

/// While the panel is closed during a recording: REC, time and distance; tap to open
class RecPill extends ConsumerWidget {
  const RecPill({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(trackRecorderProvider);
    final t = s.active;
    if (t == null) return const SizedBox.shrink();
    return Center(
      child: Material(
        key: const Key('rec-pill'),
        color: Colors.white,
        elevation: 4,
        shadowColor: const Color(0x40000000),
        shape: const StadiumBorder(side: BorderSide(color: Color(0xFFF5C4A3))),
        child: InkWell(
          customBorder: const StadiumBorder(),
          onTap: () => ref.read(trackRecorderProvider.notifier).setPanelOpen(true),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
            child: _Ticker(
              active: s.recording,
              builder: (_) => Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _RecDot(recording: s.recording),
                  const SizedBox(width: 8),
                  Text(
                    s.recording ? 'REC' : 'PAUSED',
                    style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w800),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    '${formatDuration(t.elapsedAt(_nowMs()))} · ${formatTrackDistance(t.stats.distanceM)}',
                    style: const TextStyle(fontSize: 12, fontFeatures: [FontFeature.tabularFigures()]),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// --- My tracks / Shared ----------------------------------------------------------------------

/// Opening a track shows it on the map; the map zooms to it
Future<void> showTracksSheet(BuildContext context) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (_) => DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.7,
      maxChildSize: 0.95,
      builder: (context, controller) => _TracksSheet(controller: controller),
    ),
  );
}

class _TracksSheet extends ConsumerStatefulWidget {
  const _TracksSheet({required this.controller});

  final ScrollController controller;

  @override
  ConsumerState<_TracksSheet> createState() => _TracksSheetState();
}

class _TracksSheetState extends ConsumerState<_TracksSheet> {
  bool _shared = false;

  @override
  void initState() {
    super.initState();
    // After this frame: loading changes the recorder's state
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final rec = ref.read(trackRecorderProvider.notifier);
      unawaited(rec.loadTracks());
      unawaited(rec.loadShared());
    });
  }

  Future<void> _show(String id) async {
    final v = await ref.read(trackRecorderProvider.notifier).view(id);
    if (v != null && mounted) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final s = ref.watch(trackRecorderProvider);
    final rec = ref.read(trackRecorderProvider.notifier);
    final online = ref.watch(onlineProvider).value ?? true;
    // The recording shows live stats in the list
    final mine = [for (final t in s.tracks) t.id == s.active?.id ? s.active! : t];
    return ListView(
      controller: widget.controller,
      padding: const EdgeInsets.fromLTRB(L360.gutter, 0, L360.gutter, 32),
      children: [
        Row(
          children: [
            Expanded(child: Text('Tracks', style: Theme.of(context).textTheme.titleLarge)),
            IconButton(
              tooltip: 'Refresh',
              onPressed: s.loadingTracks || s.loadingShared
                  ? null
                  : () {
                      unawaited(rec.loadTracks());
                      unawaited(rec.loadShared());
                    },
              icon: s.loadingTracks || s.loadingShared
                  ? const SizedBox.square(dimension: 18, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.refresh),
            ),
          ],
        ),
        const SizedBox(height: 8),
        SegmentedButton<bool>(
          showSelectedIcon: false,
          segments: [
            ButtonSegment(value: false, label: Text('My Tracks (${mine.length})', key: const Key('tab-mine'))),
            ButtonSegment(value: true, label: Text('Shared (${s.shared.length})', key: const Key('tab-shared'))),
          ],
          selected: {_shared},
          onSelectionChanged: (v) => setState(() => _shared = v.first),
        ),
        const SizedBox(height: 6),
        if (s.error != null) ...[
          Text(s.error!, style: const TextStyle(fontSize: 12, color: L360Colors.brick500)),
          const SizedBox(height: 6),
        ],
        Text(
          _shared
              ? (online
                    ? 'Tracks other accounts shared with you (view only)'
                    : 'Shared tracks need an internet connection.')
              : (online ? 'On this phone and in the cloud' : 'On this phone (no signal)'),
          style: const TextStyle(fontSize: 12, color: L360Colors.sand500),
        ),
        const SizedBox(height: 10),
        if (!_shared) ...[
          for (final (i, t) in mine.indexed)
            _TrackCard(
              key: Key('track-${t.id}'),
              index: i + 1,
              track: t,
              recording: t.id == s.active?.id,
              viewing: s.viewing?.track.id == t.id,
              onTap: t.id == s.active?.id ? null : () => _show(t.id),
              onMore: t.id == s.active?.id ? null : () => _trackActions(context, t),
            ),
          if (mine.isEmpty) _Empty(s.loadingTracks ? 'Loading tracks…' : 'No tracks yet. Start your first recording.'),
        ] else ...[
          for (final (i, sh) in s.shared.indexed)
            _TrackCard(
              key: Key('shared-${sh.track.id}'),
              index: i + 1,
              track: sh.track,
              owner: sh.ownerEmail ?? 'unknown',
              viewing: s.viewing?.track.id == sh.track.id,
              onTap: online ? () => _show(sh.track.id) : null,
              onMore: () => _sharedActions(context, sh),
            ),
          if (s.shared.isEmpty)
            _Empty(s.loadingShared ? 'Loading shared tracks…' : 'No tracks have been shared with you yet.'),
        ],
      ],
    );
  }

  Future<void> _export(String id) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      final (name, gpx) = await ref.read(trackRecorderProvider.notifier).exportGpx(id);
      await SharePlus.instance.share(
        ShareParams(
          files: [XFile.fromData(utf8.encode(gpx), mimeType: 'application/gpx+xml', name: name)],
          fileNameOverrides: [name],
        ),
      );
    } on Object catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('Export failed: $e')));
    }
  }

  Future<void> _trackActions(BuildContext context, RecordedTrack t) async {
    final s = ref.read(trackRecorderProvider);
    final rec = ref.read(trackRecorderProvider.notifier);
    final profile = ref.read(profileProvider).value;
    final canRecord = profile?.canRecordTracks ?? false;
    final online = ref.read(onlineProvider).value ?? true;
    final canUpload =
        canRecord &&
        online &&
        const {TrackSyncStatus.local, TrackSyncStatus.pending, TrackSyncStatus.error}.contains(t.syncStatus);
    final canRename = !t.inCloud || (profile?.canRenameCloudTracks ?? false);
    final viewing = s.viewing?.track.id == t.id;
    final action = await _actionSheet(context, t.name, [
      (
        viewing ? 'hide' : 'show',
        viewing ? Icons.visibility_off_outlined : Icons.visibility_outlined,
        viewing ? 'Hide from map' : 'Show on map',
      ),
      if (t.syncStatus != TrackSyncStatus.remote || online) ('gpx', Icons.ios_share, 'Export GPX'),
      if (canRecord && online) ('share', Icons.group_add_outlined, 'Share with an account'),
      if (canUpload) ('upload', Icons.cloud_upload_outlined, 'Upload to cloud'),
      if (canRename) ('rename', Icons.edit_outlined, 'Rename'),
      ('delete', Icons.delete_outline, t.syncStatus == TrackSyncStatus.local ? 'Delete' : 'Delete (also from cloud)'),
    ]);
    if (!context.mounted) return;
    switch (action) {
      case 'show':
        await _show(t.id);
      case 'hide':
        rec.closeView();
      case 'gpx':
        await _export(t.id);
      case 'share':
        await showShareSheet(context, t);
      case 'upload':
        await rec.sync(t.id);
      case 'rename':
        final name = await _rename(context, t.name);
        if (name != null) await rec.rename(t.id, name);
      case 'delete':
        if (await _ask(
          context,
          'Delete "${t.name}"?',
          t.syncStatus == TrackSyncStatus.local
              ? 'It is removed from this phone.'
              : 'It is removed from this phone and the cloud.',
          'Delete',
          destructive: true,
        )) {
          await rec.delete(t.id);
        }
    }
  }

  Future<void> _sharedActions(BuildContext context, SharedTrack sh) async {
    final s = ref.read(trackRecorderProvider);
    final rec = ref.read(trackRecorderProvider.notifier);
    final online = ref.read(onlineProvider).value ?? true;
    final viewing = s.viewing?.track.id == sh.track.id;
    final action = await _actionSheet(context, sh.track.name, [
      if (online || viewing)
        (
          viewing ? 'hide' : 'show',
          viewing ? Icons.visibility_off_outlined : Icons.visibility_outlined,
          viewing ? 'Hide from map' : 'Show on map',
        ),
      if (online) ('gpx', Icons.ios_share, 'Export GPX'),
      ('leave', Icons.logout, 'Remove from my list'),
    ]);
    if (!context.mounted) return;
    switch (action) {
      case 'show':
        await _show(sh.track.id);
      case 'hide':
        rec.closeView();
      case 'gpx':
        await _export(sh.track.id);
      case 'leave':
        if (await _ask(
          context,
          'Remove "${sh.track.name}" from your list?',
          'The owner can share it with you again.',
          'Remove',
          destructive: true,
        )) {
          await rec.leaveShared(sh.track.id);
        }
    }
  }
}

Future<String?> _actionSheet(
  BuildContext context,
  String title,
  List<(String, IconData, String)> items,
) => showModalBottomSheet<String>(
  context: context,
  useSafeArea: true,
  isScrollControlled: true,
  builder: (context) => SingleChildScrollView(
    child: Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(L360.gutter, 4, L360.gutter, 8),
          child: Text(
            title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.titleMedium,
          ),
        ),
        for (final (id, icon, label) in items)
          ListTile(
            key: Key('action-$id'),
            leading: Icon(icon, color: id == 'delete' || id == 'leave' ? L360Colors.brick500 : L360Colors.forest700),
            title: Text(label, style: TextStyle(color: id == 'delete' || id == 'leave' ? L360Colors.brick500 : null)),
            onTap: () => Navigator.pop(context, id),
          ),
        const SizedBox(height: 8),
      ],
    ),
  ),
);

Future<String?> _rename(BuildContext context, String current) {
  final text = TextEditingController(text: current);
  return showDialog<String>(
    context: context,
    builder: (context) => AlertDialog.adaptive(
      title: const Text('Rename track'),
      content: Material(
        type: MaterialType.transparency,
        child: TextField(controller: text, autofocus: true, maxLength: 120),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        TextButton(onPressed: () => Navigator.pop(context, text.text), child: const Text('Save')),
      ],
    ),
  ).whenComplete(text.dispose);
}

class _Empty extends StatelessWidget {
  const _Empty(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 28),
    child: Text(
      text,
      textAlign: TextAlign.center,
      style: const TextStyle(color: L360Colors.sand500),
    ),
  );
}

class _TrackCard extends StatelessWidget {
  const _TrackCard({
    super.key,
    required this.index,
    required this.track,
    this.owner,
    this.recording = false,
    this.viewing = false,
    this.onTap,
    this.onMore,
  });

  final int index;
  final RecordedTrack track;
  final String? owner; // shared tracks: the owner's email
  final bool recording;
  final bool viewing;
  final VoidCallback? onTap;
  final VoidCallback? onMore;

  static const _badges = {
    TrackSyncStatus.local: ('Phone only', L360Colors.sand100, L360Colors.sand700),
    TrackSyncStatus.pending: ('Waiting to sync', L360Colors.gold50, L360Colors.gold700),
    TrackSyncStatus.synced: ('Synced', L360Colors.forest50, L360Colors.forest700),
    TrackSyncStatus.error: ('Sync failed', L360Colors.brick50, L360Colors.brick600),
    TrackSyncStatus.remote: ('Cloud', L360Colors.forest50, L360Colors.forest700),
  };

  @override
  Widget build(BuildContext context) {
    final t = track;
    final (label, bg, fg) = _badges[t.syncStatus]!;
    final inProgress = owner != null && t.status != TrackStatus.completed;
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      color: viewing ? L360Colors.forest50 : null,
      child: InkWell(
        borderRadius: BorderRadius.circular(L360.radiusSmall),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 4, 10),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 26,
                height: 26,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: viewing ? L360Colors.forest700 : L360Colors.sand100,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  '$index',
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                    color: viewing ? Colors.white : L360Colors.sand600,
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      t.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700),
                    ),
                    if (owner != null)
                      Text(
                        'by $owner',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 12, color: L360Colors.ember600),
                      ),
                    const SizedBox(height: 2),
                    Text(
                      '${formatTrackDate(t.startedAt)} · ${formatTrackDistance(t.stats.distanceM)} · '
                      '${formatDuration(recording ? t.elapsedAt(_nowMs()) : t.elapsedMs)} · ↑ ${t.stats.elevationGainM.round()} m',
                      style: const TextStyle(fontSize: 12, color: L360Colors.sand600),
                    ),
                    const SizedBox(height: 6),
                    Wrap(
                      spacing: 6,
                      runSpacing: 4,
                      children: [
                        if (recording)
                          const _Tag('RECORDING', background: L360Colors.brick50, foreground: L360Colors.brick600)
                        else if (inProgress)
                          _Tag(
                            'IN PROGRESS · ${formatTrackDate(t.updatedAt).split(' ').last}',
                            background: L360Colors.brick50,
                            foreground: L360Colors.brick600,
                          )
                        else if (owner == null)
                          Tooltip(
                            message: t.syncError ?? label,
                            triggerMode: TooltipTriggerMode.tap,
                            child: _Tag(label.toUpperCase(), background: bg, foreground: fg),
                          ),
                        _Tag(t.mode.name.toUpperCase()),
                        if (viewing)
                          const _Tag('ON MAP', background: L360Colors.forest50, foreground: L360Colors.forest700),
                      ],
                    ),
                  ],
                ),
              ),
              if (onMore != null)
                IconButton(
                  key: Key('more-${t.id}'),
                  tooltip: 'More',
                  icon: const Icon(Icons.more_horiz, color: L360Colors.sand600),
                  onPressed: onMore,
                ),
            ],
          ),
        ),
      ),
    );
  }
}

// --- Sharing (TrackShareManager.tsx) ---------------------------------------------------------

Future<void> showShareSheet(BuildContext context, RecordedTrack track) => showModalBottomSheet<void>(
  context: context,
  isScrollControlled: true,
  useSafeArea: true,
  builder: (context) => Padding(
    padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
    child: _ShareSheet(track: track),
  ),
);

class _ShareSheet extends ConsumerStatefulWidget {
  const _ShareSheet({required this.track});

  final RecordedTrack track;

  @override
  ConsumerState<_ShareSheet> createState() => _ShareSheetState();
}

class _ShareSheetState extends ConsumerState<_ShareSheet> {
  final _email = TextEditingController();
  List<TrackShare> _shares = const [];
  bool _loading = true;
  bool _sharing = false;
  String? _error;
  String? _notice;

  TrackRecorderController get _rec => ref.read(trackRecorderProvider.notifier);

  @override
  void initState() {
    super.initState();
    unawaited(_refresh());
  }

  @override
  void dispose() {
    _email.dispose();
    super.dispose();
  }

  Future<void> _refresh() async {
    try {
      // A track never uploaded has no recipients yet
      final shares = widget.track.inCloud ? await _rec.listShares(widget.track.id) : const <TrackShare>[];
      if (mounted) setState(() => _shares = shares);
    } on Object catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _share() async {
    final email = _email.text.trim();
    if (email.isEmpty || _sharing) return;
    setState(() {
      _sharing = true;
      _error = null;
      _notice = null;
    });
    try {
      final share = await _rec.share(widget.track.id, email);
      if (!mounted) return;
      setState(() {
        _shares = [..._shares.where((s) => s.userId != share.userId), share];
        _notice = 'Shared with ${share.email}';
        _email.clear();
      });
    } on Object catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _sharing = false);
    }
  }

  Future<void> _revoke(TrackShare share) async {
    if (!await _ask(
      context,
      'Remove access for ${share.email}?',
      'They can no longer see this track.',
      'Remove',
      destructive: true,
    )) {
      return;
    }
    try {
      await _rec.revokeShare(widget.track.id, share.userId);
      if (!mounted) return;
      setState(() {
        _shares = _shares.where((s) => s.userId != share.userId).toList();
        _notice = 'Access removed for ${share.email}';
        _error = null;
      });
    } on Object catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
  }

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(L360.gutter, 0, L360.gutter, 24),
    child: Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('Share track', style: Theme.of(context).textTheme.titleLarge),
        Text(widget.track.name, style: const TextStyle(color: L360Colors.sand600)),
        const SizedBox(height: 12),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: TextField(
                key: const Key('share-email'),
                controller: _email,
                keyboardType: TextInputType.emailAddress,
                autocorrect: false,
                textInputAction: TextInputAction.send,
                onSubmitted: (_) => _share(),
                decoration: const InputDecoration(hintText: 'Recipient account email', isDense: true),
              ),
            ),
            const SizedBox(width: 8),
            FilledButton(
              key: const Key('share-send'),
              // Beside the field: not the theme's full width
              style: FilledButton.styleFrom(minimumSize: const Size(0, 44)),
              onPressed: _sharing ? null : _share,
              child: _sharing
                  ? const SizedBox.square(
                      dimension: 18,
                      child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                    )
                  : const Text('Share'),
            ),
          ],
        ),
        const SizedBox(height: 6),
        const Text(
          'They see it under Shared (view only) and can export GPX. A track not in the cloud yet is uploaded first.',
          style: TextStyle(fontSize: 12, color: L360Colors.sand500),
        ),
        if (_error != null || _notice != null) ...[
          const SizedBox(height: 8),
          Text(
            _error ?? _notice!,
            style: TextStyle(fontSize: 13, color: _error != null ? L360Colors.brick500 : L360Colors.forest700),
          ),
        ],
        const SizedBox(height: 12),
        Text(
          _loading
              ? 'Loading…'
              : _shares.isEmpty
              ? 'Not shared with anyone yet'
              : 'Shared with ${_shares.length} account${_shares.length == 1 ? '' : 's'}',
          style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: L360Colors.sand600),
        ),
        for (final share in _shares)
          ListTile(
            contentPadding: EdgeInsets.zero,
            dense: true,
            leading: const Icon(Icons.person_outline),
            title: Text(share.email),
            trailing: IconButton(
              tooltip: 'Remove access',
              icon: const Icon(Icons.person_remove_outlined, color: L360Colors.brick500),
              onPressed: () => _revoke(share),
            ),
          ),
      ],
    ),
  );
}
