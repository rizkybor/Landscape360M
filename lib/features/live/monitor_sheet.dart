import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/providers.dart';
import '../../core/theme/app_theme.dart';
import '../../core/ui/widgets.dart';
import '../../data/live/monitor_backend.dart';
import '../../domain/live/monitor.dart';
import '../community/community_widgets.dart' show confirmDialog, showSnack;
import '../map/map_tools_state.dart' show flyToProvider;
import '../tracks/track_recorder_state.dart' show trackClockProvider;
import 'monitor_state.dart';

// Team Monitor's screens (Tools > Monitor): the sheet with the switch and the members, the
// MONITOR pill on the map, the card of the member tapped (coordinates in DMS, elevation,
// speed, last update, as the web's popup), the card of a recalled activity, and the tracking
// lists (Activities and Logs, with a member filter, GPX and, for monitors, deleting a log).

Color _hex(String h) => Color(int.parse(h.substring(1), radix: 16) | 0xFF000000);

String _two(int v) => v.toString().padLeft(2, '0');

String _clock(DateTime t) {
  final l = t.toLocal();
  return '${_two(l.hour)}:${_two(l.minute)}:${_two(l.second)}';
}

const _days = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
const _months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];

String _date(DateTime t) {
  final l = t.toLocal();
  return '${_days[l.weekday - 1]}, ${l.day} ${_months[l.month - 1]} ${l.year}';
}

String _dateTime(DateTime t) {
  final l = t.toLocal();
  return '${l.day} ${_months[l.month - 1]} ${l.year} ${_two(l.hour)}:${_two(l.minute)}';
}

String _ago(int ms) {
  final s = (ms / 1000).round();
  if (s < 5) return 'just now';
  if (s < 60) return '$s s ago';
  if (s < 3600) return '${(s / 60).floor()} min ago';
  return '${(s / 3600).floor()} h ago';
}

String _km(double m) => m >= 1000 ? '${(m / 1000).toStringAsFixed(2)} km' : '${m.round()} m';

String _duration(DateTime from, DateTime? to) {
  final d = (to ?? DateTime.now()).difference(from);
  if (d.inMinutes < 60) return '${d.inMinutes} min';
  return '${d.inHours} h ${_two(d.inMinutes % 60)} min';
}

(String, Color) _statusLook(MonitorStatus s) => switch (s) {
  MonitorStatus.online => ('ONLINE (MOVING)', const Color(0xFF22C55E)),
  MonitorStatus.idle => ('IDLE (STATIONARY)', const Color(0xFFF59E0B)),
  MonitorStatus.offline => ('OFFLINE', const Color(0xFFEF4444)),
};

/// A member's round badge: initials on their colour (gray when offline)
class MemberBadge extends ConsumerWidget {
  const MemberBadge({super.key, required this.id, this.status = MonitorStatus.online, this.size = 40, this.profile});

  final String id;
  final MonitorStatus status;
  final double size;

  /// The account: its photo instead of the initials, which are then the name's
  final TrackerProfile? profile;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final (_, dot) = _statusLook(status);
    final photo = profile?.avatarPath;
    final label = trackerLabel(id, profile);
    return SizedBox(
      width: size,
      height: size,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Container(
            width: size,
            height: size,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: status == MonitorStatus.offline ? const Color(0xFF6B7280) : _hex(trackerColor(id)),
              shape: BoxShape.circle,
              border: Border.all(color: Colors.white, width: 2.5),
              boxShadow: const [BoxShadow(color: Color(0x33000000), blurRadius: 6, offset: Offset(0, 2))],
            ),
            clipBehavior: Clip.antiAlias,
            child: status == MonitorStatus.offline
                ? Icon(Icons.wifi_off, size: size * 0.42, color: Colors.white)
                : photo != null
                ? Image.network(
                    ref.watch(avatarUrlProvider)(photo),
                    key: Key('member-photo-$id'),
                    fit: BoxFit.cover,
                    errorBuilder: (_, _, _) => Center(
                      child: Text(
                        trackerInitials(label),
                        style: TextStyle(fontSize: size * 0.32, fontWeight: FontWeight.w800, color: Colors.white),
                      ),
                    ),
                  )
                : Text(
                    trackerInitials(label),
                    style: TextStyle(fontSize: size * 0.32, fontWeight: FontWeight.w800, color: Colors.white),
                  ),
          ),
          Positioned(
            right: -2,
            bottom: -2,
            child: Container(
              width: size * 0.34,
              height: size * 0.34,
              decoration: BoxDecoration(
                color: dot,
                shape: BoxShape.circle,
                border: Border.all(color: Colors.white, width: 2),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// --- The sheet (Tools > Monitor) -----------------------------------------------------------------

Future<void> showMonitorSheet(BuildContext context) => showModalBottomSheet<void>(
  context: context,
  useSafeArea: true,
  isScrollControlled: true,
  builder: (_) => const _MonitorSheet(),
);

class _MonitorSheet extends ConsumerStatefulWidget {
  const _MonitorSheet();

  @override
  ConsumerState<_MonitorSheet> createState() => _MonitorSheetState();
}

class _MonitorSheetState extends ConsumerState<_MonitorSheet> {
  bool _busy = false;

  Future<void> _toggle() async {
    setState(() => _busy = true);
    final ctrl = ref.read(monitorProvider.notifier);
    if (ref.read(monitorProvider).on) {
      await ctrl.stop();
    } else if (!await ctrl.start()) {
      if (mounted) showSnack(context, 'Team Monitor is for Enterprise monitor accounts.');
    }
    if (mounted) setState(() => _busy = false);
  }

  void _focus(MonitorTracker t) {
    ref.read(monitorProvider.notifier).select(t.id);
    ref.read(flyToProvider.notifier).go(t.latest.lng, t.latest.lat, zoom: 15);
    Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final s = ref.watch(monitorProvider);
    final allowed = ref.watch(profileProvider).value?.canMonitor ?? false;
    final now = ref.read(trackClockProvider)();
    final members = s.members;
    final (dot, line) = switch ((s.on, s.connection)) {
      (false, _) => (L360Colors.sand300, 'Off'),
      (true, MonitorConnection.connecting) => (L360Colors.gold400, 'Joining the tracking room…'),
      (true, MonitorConnection.connected) => (
        L360Colors.forest500,
        '${members.length} member${members.length == 1 ? '' : 's'} · ${s.online(now)} online',
      ),
      (true, MonitorConnection.error) => (L360Colors.brick500, s.error ?? 'Could not join'),
      (true, MonitorConnection.off) => (L360Colors.gold400, 'Reconnecting…'),
    };
    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.6,
      maxChildSize: 0.95,
      builder: (context, scroll) => ListView(
        controller: scroll,
        padding: const EdgeInsets.fromLTRB(L360.gutter, 8, L360.gutter, 24),
        children: [
          Row(
            children: [
              const Icon(Icons.visibility_outlined, color: L360Colors.forest700),
              const SizedBox(width: 10),
              const Expanded(
                child: Text('Team Monitor', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
              ),
              Switch(
                key: const Key('monitor-switch'),
                value: s.on,
                onChanged: _busy || !allowed ? null : (_) => _toggle(),
              ),
            ],
          ),
          const SizedBox(height: 4),
          const Text(
            'Follow every member sharing their position from the app, live on the map. '
            'Positions arrive every few seconds while this is on.',
            style: TextStyle(fontSize: 13, color: L360Colors.sand600),
          ),
          const SizedBox(height: 12),
          if (!allowed)
            Container(
              key: const Key('monitor-locked'),
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(color: L360Colors.gold50, borderRadius: BorderRadius.circular(12)),
              child: const Text(
                'Team Monitor is for Enterprise monitor accounts. Members share their position with GPS Tracking.',
                style: TextStyle(fontSize: 13, color: L360Colors.gold700),
              ),
            )
          else
            Row(
              children: [
                Container(
                  width: 10,
                  height: 10,
                  decoration: BoxDecoration(color: dot, shape: BoxShape.circle),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    line,
                    key: const Key('monitor-status'),
                    style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
                  ),
                ),
                if (s.on)
                  TextButton.icon(
                    key: const Key('monitor-ask'),
                    onPressed: () => unawaited(ref.read(monitorProvider.notifier).askNow()),
                    icon: const Icon(Icons.refresh, size: 18),
                    label: const Text('Ask now'),
                  ),
              ],
            ),
          if (allowed) ...[
            const SizedBox(height: 8),
            OutlinedButton.icon(
              key: const Key('monitor-lists'),
              onPressed: () => showTrackingLists(context),
              icon: const Icon(Icons.history, size: 18),
              label: const Text('Tracking lists'),
            ),
          ],
          if (s.on) ...[
            const SizedBox(height: 16),
            const SectionLabel('Members'),
            if (members.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 12),
                child: Text(
                  'Nobody is sharing yet. Members switch on GPS Tracking in the app; their positions show here within seconds.',
                  style: TextStyle(fontSize: 13, color: L360Colors.sand600),
                ),
              ),
            for (final t in members)
              ListTile(
                key: Key('member-${t.id}'),
                contentPadding: EdgeInsets.zero,
                leading: MemberBadge(id: t.id, status: t.status(now), profile: s.profileOf(t.id)),
                title: Text(trackerLabel(t.id, s.profileOf(t.id)), style: const TextStyle(fontWeight: FontWeight.w700)),
                subtitle: Text(
                  [
                    if (s.profileOf(t.id)?.name != null) t.id,
                    _statusLook(t.status(now)).$1,
                    _ago(now - t.latest.time),
                    if (t.latest.battery != null) '${t.latest.battery}%',
                  ].join(' · '),
                  style: const TextStyle(fontSize: 12),
                ),
                trailing: const Icon(Icons.my_location, size: 18, color: L360Colors.forest700),
                selected: t.id == s.selectedId,
                onTap: () => _focus(t),
              ),
          ],
        ],
      ),
    );
  }
}

// --- On the map ----------------------------------------------------------------------------------

/// The pill while Team Monitor is on
class MonitorPill extends ConsumerWidget {
  const MonitorPill({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(monitorProvider);
    if (!s.on) return const SizedBox.shrink();
    final now = ref.read(trackClockProvider)();
    final ok = s.connection == MonitorConnection.connected;
    final n = s.trackers.length;
    return Center(
      child: Material(
        key: const Key('monitor-pill'),
        color: Colors.white,
        elevation: 4,
        shadowColor: const Color(0x40000000),
        shape: const StadiumBorder(side: BorderSide(color: L360Colors.forest200)),
        child: InkWell(
          customBorder: const StadiumBorder(),
          onTap: () => showMonitorSheet(context),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.visibility, size: 14, color: ok ? L360Colors.forest600 : L360Colors.gold500),
                const SizedBox(width: 8),
                Text(
                  ok
                      ? 'MONITOR · $n member${n == 1 ? '' : 's'} · ${s.online(now)} online'
                      : s.connection == MonitorConnection.error
                      ? 'MONITOR · not connected'
                      : 'MONITOR · joining…',
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

/// The member tapped on the map (the web's popup)
class MonitorMemberCard extends ConsumerWidget {
  const MonitorMemberCard({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(monitorProvider);
    final t = s.selected;
    if (t == null) return const SizedBox.shrink();
    final now = ref.read(trackClockProvider)();
    final status = t.status(now);
    final (label, dot) = _statusLook(status);
    final p = t.latest;
    final terrain = ref.watch(monitorElevationProvider);
    final elevation = terrain ?? p.alt;
    final profile = s.profileOf(t.id);
    final wa = profile?.phone == null ? null : whatsappUrl(profile!.phone!);
    const small = TextStyle(fontSize: 10, fontWeight: FontWeight.w700, color: L360Colors.sand500, letterSpacing: 0.8);
    return Material(
      key: const Key('monitor-card'),
      color: Colors.white,
      elevation: 6,
      shadowColor: const Color(0x40000000),
      borderRadius: BorderRadius.circular(L360.radius),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 12, 8, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                MemberBadge(id: t.id, status: status, size: 44, profile: profile),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        trackerLabel(t.id, profile),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w800),
                      ),
                      if (profile?.name != null)
                        Text(
                          t.id,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 11, fontFamily: 'monospace', color: L360Colors.sand500),
                        ),
                      Row(
                        children: [
                          Container(
                            width: 8,
                            height: 8,
                            decoration: BoxDecoration(color: dot, shape: BoxShape.circle),
                          ),
                          const SizedBox(width: 6),
                          Text(label, style: small),
                        ],
                      ),
                    ],
                  ),
                ),
                IconButton(
                  key: const Key('monitor-card-close'),
                  tooltip: 'Close',
                  onPressed: () => ref.read(monitorProvider.notifier).select(null),
                  icon: const Icon(Icons.close, size: 20, color: L360Colors.sand500),
                ),
              ],
            ),
            if (profile != null) ...[const SizedBox(height: 8), _ProfileLines(profile: profile, whatsapp: wa)],
            const SizedBox(height: 10),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: L360Colors.sand50,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: L360Colors.sand200),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('COORDINATES', style: small),
                  const SizedBox(height: 2),
                  Text(
                    toDms(p.lat, isLat: true),
                    style: const TextStyle(fontFamily: 'monospace', fontSize: 13, fontWeight: FontWeight.w600),
                  ),
                  Text(
                    toDms(p.lng, isLat: false),
                    style: const TextStyle(fontFamily: 'monospace', fontSize: 13, fontWeight: FontWeight.w600),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(
                  child: _Metric(
                    label: 'ELEVATION',
                    value: elevation == null ? '-' : elevation.round().toString(),
                    unit: 'mdpl',
                  ),
                ),
                Expanded(
                  child: _Metric(label: 'SPEED', value: (p.speed ?? 0).toStringAsFixed(1), unit: 'km/h'),
                ),
                if (p.battery != null)
                  Expanded(
                    child: _Metric(label: 'BATTERY', value: '${p.battery}', unit: '%'),
                  ),
              ],
            ),
            const SizedBox(height: 8),
            const Divider(height: 1),
            const SizedBox(height: 6),
            Row(
              children: [
                const Text('Last update', style: TextStyle(fontSize: 11, color: L360Colors.sand500)),
                const Spacer(),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Text(
                      _clock(DateTime.fromMillisecondsSinceEpoch(p.time)),
                      style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700, fontFamily: 'monospace'),
                    ),
                    Text(
                      _date(DateTime.fromMillisecondsSinceEpoch(p.time)),
                      style: const TextStyle(fontSize: 10.5, color: L360Colors.sand500),
                    ),
                  ],
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// The account behind the tracker: plan and role, organization, email, phone with WhatsApp
class _ProfileLines extends StatelessWidget {
  const _ProfileLines({required this.profile, required this.whatsapp});

  final TrackerProfile profile;
  final String? whatsapp;

  Future<void> _open(String url) async {
    final uri = Uri.parse(url);
    if (await canLaunchUrl(uri)) await launchUrl(uri, mode: LaunchMode.externalApplication);
  }

  @override
  Widget build(BuildContext context) {
    final p = profile;
    const line = TextStyle(fontSize: 12.5, color: L360Colors.sand700);
    Widget row(IconData icon, Widget child, {VoidCallback? onTap}) => InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Row(
          children: [
            Icon(icon, size: 14, color: L360Colors.sand400),
            const SizedBox(width: 6),
            Expanded(child: child),
          ],
        ),
      ),
    );
    return Column(
      key: const Key('monitor-profile'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          spacing: 6,
          runSpacing: 4,
          children: [
            if (p.plan != null)
              Pill(
                p.plan!,
                background: L360Colors.gold50,
                foreground: L360Colors.gold700,
                icon: Icons.workspace_premium_outlined,
              ),
            Pill(
              p.roleLabel,
              background: L360Colors.forest50,
              foreground: L360Colors.forest700,
              icon: p.role == 'monitor360' ? Icons.visibility_outlined : Icons.hiking,
            ),
          ],
        ),
        const SizedBox(height: 6),
        if (p.organization != null)
          row(Icons.groups_outlined, Text(p.organization!, maxLines: 1, overflow: TextOverflow.ellipsis, style: line)),
        if (p.email != null)
          row(
            Icons.mail_outline,
            Text(p.email!, maxLines: 1, overflow: TextOverflow.ellipsis, style: line),
            onTap: () => _open('mailto:${p.email}'),
          ),
        if (p.phone != null)
          row(
            Icons.phone_outlined,
            Row(
              children: [
                Expanded(
                  child: Text(p.phone!, maxLines: 1, overflow: TextOverflow.ellipsis, style: line),
                ),
                if (whatsapp != null)
                  TextButton.icon(
                    key: const Key('monitor-whatsapp'),
                    style: TextButton.styleFrom(
                      visualDensity: VisualDensity.compact,
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                    ),
                    onPressed: () => _open(whatsapp!),
                    icon: const Icon(Icons.chat_outlined, size: 14),
                    label: const Text('WhatsApp', style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w700)),
                  ),
              ],
            ),
            onTap: () => _open('tel:${p.phone!.replaceAll(RegExp(r'[^\d+]'), '')}'),
          ),
        if (p.matches > 1)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              '${p.matches} accounts use this email name; showing the one that shared last.',
              style: const TextStyle(fontSize: 11, color: L360Colors.gold700),
            ),
          ),
      ],
    );
  }
}

class _Metric extends StatelessWidget {
  const _Metric({required this.label, required this.value, required this.unit});

  final String label;
  final String value;
  final String unit;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(
        label,
        style: const TextStyle(
          fontSize: 10,
          fontWeight: FontWeight.w700,
          color: L360Colors.sand500,
          letterSpacing: 0.8,
        ),
      ),
      Row(
        crossAxisAlignment: CrossAxisAlignment.baseline,
        textBaseline: TextBaseline.alphabetic,
        children: [
          Text(value, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w800)),
          const SizedBox(width: 3),
          Text(unit, style: const TextStyle(fontSize: 11, color: L360Colors.sand500)),
        ],
      ),
    ],
  );
}

/// A recalled activity on the map: hide it or take it off
class MonitorSessionCard extends ConsumerWidget {
  const MonitorSessionCard({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(monitorProvider);
    final points = s.session;
    if (points == null) return const SizedBox.shrink();
    var distance = 0.0;
    for (var i = 1; i < points.length; i++) {
      distance += metersBetween(points[i - 1].lat, points[i - 1].lng, points[i].lat, points[i].lng);
    }
    final who = points.isEmpty ? 'Activity' : points.first.trackerId;
    return Material(
      key: const Key('monitor-session-card'),
      color: Colors.white,
      elevation: 4,
      shadowColor: const Color(0x40000000),
      borderRadius: BorderRadius.circular(L360.radius),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 8, 4, 8),
        child: Row(
          children: [
            const Icon(Icons.route, size: 20, color: Color(0xFF3B82F6)),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '$who · activity',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontWeight: FontWeight.w700),
                  ),
                  Text(
                    '${points.length} points · ${_km(distance)}'
                    '${points.isEmpty ? '' : ' · ${_dateTime(DateTime.fromMillisecondsSinceEpoch(points.first.time))}'}',
                    style: const TextStyle(fontSize: 12, color: L360Colors.sand600),
                  ),
                ],
              ),
            ),
            IconButton(
              key: const Key('monitor-session-eye'),
              tooltip: s.sessionVisible ? 'Hide' : 'Show',
              onPressed: () => ref.read(monitorProvider.notifier).toggleSessionVisible(),
              icon: Icon(
                s.sessionVisible ? Icons.visibility : Icons.visibility_off,
                size: 20,
                color: L360Colors.sand600,
              ),
            ),
            IconButton(
              key: const Key('monitor-session-close'),
              tooltip: 'Take off the map',
              onPressed: () => ref.read(monitorProvider.notifier).closeSession(),
              icon: const Icon(Icons.close, size: 20, color: L360Colors.sand600),
            ),
          ],
        ),
      ),
    );
  }
}

// --- Tracking lists -------------------------------------------------------------------------------

Future<void> showTrackingLists(BuildContext context) => showModalBottomSheet<void>(
  context: context,
  useSafeArea: true,
  isScrollControlled: true,
  builder: (_) => const _TrackingLists(),
);

class _TrackingLists extends ConsumerStatefulWidget {
  const _TrackingLists();

  @override
  ConsumerState<_TrackingLists> createState() => _TrackingListsState();
}

class _TrackingListsState extends ConsumerState<_TrackingLists> {
  static const _limit = 20;
  bool _activities = true;
  bool _loading = false;
  bool _more = true;
  String? _filter; // a member's id, or everyone
  List<MonitorMember> _members = const [];
  List<ActivitySummary> _sessions = const [];
  List<TrackerLog> _logs = const [];
  String? _error;
  String? _busyId;

  MonitorRepository get _repo => ref.read(monitorRepositoryProvider);

  @override
  void initState() {
    super.initState();
    unawaited(_reload());
    unawaited(_loadMembers());
  }

  Future<void> _loadMembers() async {
    try {
      final m = await _repo.members();
      if (mounted) setState(() => _members = m);
    } on Object {
      // The filter stays "all"
    }
  }

  Future<void> _reload() => _load(more: false);

  Future<void> _load({required bool more}) async {
    if (_loading) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      if (_activities) {
        final page = await _repo.activities(userId: _filter, limit: _limit, offset: more ? _sessions.length : 0);
        if (!mounted) return;
        setState(() {
          _sessions = more ? [..._sessions, ...page] : page;
          _more = page.length >= _limit;
        });
      } else {
        final page = await _repo.logs(userId: _filter, limit: _limit, offset: more ? _logs.length : 0);
        if (!mounted) return;
        setState(() {
          _logs = more ? [..._logs, ...page] : page;
          _more = page.length >= _limit;
        });
      }
    } on Object catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _showActivity(ActivitySummary a) async {
    setState(() => _busyId = a.sessionId);
    try {
      final points = await _repo.activityPoints(a);
      if (!mounted) return;
      if (points.isEmpty) {
        showSnack(context, 'No points found for this activity.');
        return;
      }
      ref.read(monitorProvider.notifier).showSession(points);
      final mid = points[points.length ~/ 2];
      ref.read(flyToProvider.notifier).go(mid.lng, mid.lat, zoom: 13);
      Navigator.of(context).popUntil((r) => r.isFirst);
    } on Object catch (e) {
      if (mounted) showSnack(context, 'Failed to load the activity: $e');
    } finally {
      if (mounted) setState(() => _busyId = null);
    }
  }

  Future<void> _shareGpx(String name, String fileName, Future<List<MonitorPacket>> Function() points) async {
    try {
      final pts = await points();
      if (!mounted) return;
      if (pts.isEmpty) {
        showSnack(context, 'No points found to export.');
        return;
      }
      final gpx = pointsGpx(pts, name: name);
      await SharePlus.instance.share(
        ShareParams(
          files: [XFile.fromData(utf8.encode(gpx), mimeType: 'application/gpx+xml', name: fileName)],
          fileNameOverrides: [fileName],
        ),
      );
    } on Object catch (e) {
      if (mounted) showSnack(context, 'Export failed: $e');
    }
  }

  Future<void> _deleteLog(TrackerLog l) async {
    if (!await confirmDialog(
      context,
      title: 'Delete this log?',
      message: 'The point is removed for good.',
      action: 'Delete',
    )) {
      return;
    }
    try {
      await _repo.deleteLog(l.id);
      if (mounted) {
        setState(
          () => _logs = [
            for (final x in _logs)
              if (x.id != l.id) x,
          ],
        );
      }
    } on Object catch (e) {
      if (mounted) showSnack(context, 'Failed to delete the log: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final monitor = ref.watch(profileProvider).value?.canMonitor ?? false;
    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.75,
      maxChildSize: 0.95,
      builder: (context, scroll) => Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(L360.gutter, 12, 8, 4),
            child: Row(
              children: [
                const Icon(Icons.history, color: L360Colors.forest700),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text('Tracking lists', style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700)),
                      Text(
                        monitor ? 'Monitoring all units' : 'Your movement history',
                        style: const TextStyle(fontSize: 12, color: L360Colors.sand600),
                      ),
                    ],
                  ),
                ),
                IconButton(
                  key: const Key('lists-refresh'),
                  tooltip: 'Refresh',
                  onPressed: _loading ? null : _reload,
                  icon: const Icon(Icons.refresh),
                ),
                if (!_activities && monitor)
                  IconButton(
                    key: const Key('lists-gpx-all'),
                    tooltip: 'Export logs as GPX',
                    onPressed: () => _shareGpx(
                      'Tracking Logs ${_dateTime(DateTime.now())}',
                      'Tracking_Logs_${DateTime.now().toIso8601String().substring(0, 10)}.gpx',
                      () async => [
                        for (final l in (await _repo.logs(userId: _filter, limit: 2000)).reversed)
                          MonitorPacket(
                            trackerId: l.memberName,
                            lat: l.lat,
                            lng: l.lng,
                            alt: l.elevation,
                            speed: l.speed,
                            time: l.time.millisecondsSinceEpoch,
                          ),
                      ],
                    ),
                    icon: const Icon(Icons.file_download_outlined),
                  ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(L360.gutter, 4, L360.gutter, 8),
            child: Row(
              children: [
                SegmentedButton<bool>(
                  segments: const [
                    ButtonSegment(value: true, label: Text('Activities')),
                    ButtonSegment(value: false, label: Text('Logs')),
                  ],
                  selected: {_activities},
                  showSelectedIcon: false,
                  style: const ButtonStyle(visualDensity: VisualDensity.compact),
                  onSelectionChanged: (v) {
                    setState(() {
                      _activities = v.first;
                      _more = true;
                    });
                    unawaited(_reload());
                  },
                ),
                const Spacer(),
                if (monitor)
                  DropdownButton<String?>(
                    key: const Key('lists-filter'),
                    value: _filter,
                    underline: const SizedBox.shrink(),
                    style: const TextStyle(fontSize: 13, color: L360Colors.ink),
                    items: [
                      const DropdownMenuItem(value: null, child: Text('All users')),
                      for (final m in _members) DropdownMenuItem(value: m.userId, child: Text(m.name)),
                    ],
                    onChanged: (v) {
                      setState(() => _filter = v);
                      unawaited(_reload());
                    },
                  ),
              ],
            ),
          ),
          if (_error != null)
            Padding(padding: const EdgeInsets.fromLTRB(L360.gutter, 0, L360.gutter, 8), child: ErrorBanner(_error!)),
          Expanded(
            child: NotificationListener<ScrollNotification>(
              onNotification: (n) {
                if (_more && !_loading && n.metrics.pixels > n.metrics.maxScrollExtent - 200) {
                  unawaited(_load(more: true));
                }
                return false;
              },
              child: _activities ? _sessionsList(scroll, monitor) : _logsList(scroll, monitor),
            ),
          ),
        ],
      ),
    );
  }

  Widget _sessionsList(ScrollController scroll, bool monitor) {
    if (_sessions.isEmpty) return _empty('No activities found.');
    return ListView.separated(
      controller: scroll,
      padding: const EdgeInsets.fromLTRB(L360.gutter, 0, L360.gutter, 24),
      itemCount: _sessions.length + (_loading ? 1 : 0),
      separatorBuilder: (_, _) => const Divider(height: 1),
      itemBuilder: (context, i) {
        if (i == _sessions.length) {
          return const Padding(
            padding: EdgeInsets.all(12),
            child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
          );
        }
        final a = _sessions[i];
        final live = a.endedAt == null;
        return ListTile(
          key: Key('activity-${a.sessionId}'),
          contentPadding: EdgeInsets.zero,
          leading: MemberBadge(
            id: a.memberName.toUpperCase(),
            status: live ? MonitorStatus.online : MonitorStatus.idle,
            size: 38,
          ),
          title: Row(
            children: [
              Flexible(
                child: Text(
                  a.memberName,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
              ),
              if (live) ...[
                const SizedBox(width: 6),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                  decoration: BoxDecoration(color: L360Colors.forest100, borderRadius: BorderRadius.circular(6)),
                  child: const Text(
                    'LIVE',
                    style: TextStyle(fontSize: 9.5, fontWeight: FontWeight.w800, color: L360Colors.forest800),
                  ),
                ),
              ],
            ],
          ),
          subtitle: Text(
            '${_dateTime(a.startedAt)} · ${_duration(a.startedAt, a.endedAt)} · ${_km(a.distanceM)} · ${a.pointCount} pts',
            style: const TextStyle(fontSize: 12),
          ),
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              IconButton(
                key: Key('activity-gpx-${a.sessionId}'),
                tooltip: 'GPX',
                onPressed: () => _shareGpx(
                  'Activity ${_dateTime(a.startedAt)}',
                  'Activity_${a.startedAt.toIso8601String().substring(0, 10)}.gpx',
                  () => _repo.activityPoints(a),
                ),
                icon: const Icon(Icons.file_download_outlined, size: 20, color: L360Colors.sand600),
              ),
              IconButton(
                key: Key('activity-show-${a.sessionId}'),
                tooltip: 'Show on map',
                onPressed: _busyId == a.sessionId ? null : () => _showActivity(a),
                icon: _busyId == a.sessionId
                    ? const SizedBox.square(dimension: 18, child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.map_outlined, size: 20, color: L360Colors.forest700),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _logsList(ScrollController scroll, bool monitor) {
    if (_logs.isEmpty) return _empty('No logs found.');
    return ListView.separated(
      controller: scroll,
      padding: const EdgeInsets.fromLTRB(L360.gutter, 0, L360.gutter, 24),
      itemCount: _logs.length + (_loading ? 1 : 0),
      separatorBuilder: (_, _) => const Divider(height: 1),
      itemBuilder: (context, i) {
        if (i == _logs.length) {
          return const Padding(
            padding: EdgeInsets.all(12),
            child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
          );
        }
        final l = _logs[i];
        return ListTile(
          key: Key('log-${l.id}'),
          contentPadding: EdgeInsets.zero,
          dense: true,
          title: Text(
            '${_clock(l.time)} · ${l.memberName}',
            style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 13),
          ),
          subtitle: Text(
            '${toDms(l.lat, isLat: true)}  ${toDms(l.lng, isLat: false)}\n'
            '${_date(l.time)} · ${l.elevation?.round() ?? 0} m · ${(l.speed ?? 0).toStringAsFixed(1)} km/h',
            style: const TextStyle(fontSize: 11.5, fontFamily: 'monospace'),
          ),
          isThreeLine: true,
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              IconButton(
                tooltip: 'Show on map',
                onPressed: () {
                  ref.read(flyToProvider.notifier).go(l.lng, l.lat, zoom: 15);
                  Navigator.of(context).popUntil((r) => r.isFirst);
                },
                icon: const Icon(Icons.my_location, size: 18, color: L360Colors.forest700),
              ),
              if (monitor)
                IconButton(
                  key: Key('log-delete-${l.id}'),
                  tooltip: 'Delete',
                  onPressed: () => _deleteLog(l),
                  icon: const Icon(Icons.delete_outline, size: 18, color: L360Colors.brick500),
                ),
            ],
          ),
        );
      },
    );
  }

  Widget _empty(String text) => Center(
    child: _loading
        ? const CircularProgressIndicator()
        : Padding(
            padding: const EdgeInsets.all(24),
            child: Text(text, style: const TextStyle(color: L360Colors.sand600)),
          ),
  );
}
