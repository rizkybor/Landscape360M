import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers.dart';
import '../../core/theme/app_theme.dart';
import '../../domain/map/offline_regions.dart';
import '../map/map_tools_state.dart';
import '../tracks/track_recorder_panel.dart' show contactAdminLabel;
import 'offline_state.dart';

// Offline maps: the list of areas (on this phone or only in the account), and while picking
// a new one, a frame on the map and the bar that downloads it.

Future<void> showOfflineSheet(BuildContext context) => showModalBottomSheet<void>(
  context: context,
  isScrollControlled: true,
  useSafeArea: true,
  builder: (_) => DraggableScrollableSheet(
    expand: false,
    initialChildSize: 0.65,
    maxChildSize: 0.95,
    builder: (context, controller) => _OfflineList(controller: controller),
  ),
);

class _OfflineList extends ConsumerStatefulWidget {
  const _OfflineList({required this.controller});
  final ScrollController controller;

  @override
  ConsumerState<_OfflineList> createState() => _OfflineListState();
}

class _OfflineListState extends ConsumerState<_OfflineList> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(ref.read(offlineProvider.notifier).refresh());
    });
  }

  @override
  Widget build(BuildContext context) {
    final s = ref.watch(offlineProvider);
    ref.watch(profileProvider);
    final rec = ref.read(offlineProvider.notifier);
    final limits = rec.limits;
    final atLimit = s.records.length >= limits.count;
    final onPhone = s.stored.values.fold<int>(0, (a, b) => a + b);
    return ListView(
      controller: widget.controller,
      padding: const EdgeInsets.fromLTRB(L360.gutter, 0, L360.gutter, 32),
      children: [
        Row(
          children: [
            Expanded(child: Text('Offline maps', style: Theme.of(context).textTheme.titleLarge)),
            if (s.loading) const SizedBox.square(dimension: 18, child: CircularProgressIndicator(strokeWidth: 2)),
          ],
        ),
        Text(
          '${s.records.length} of ${limits.count} maps · up to ${limits.sizeMb.toStringAsFixed(0)} MB each'
          '${onPhone > 0 ? ' · ${formatBytes(onPhone)} on this phone' : ''}',
          style: const TextStyle(color: L360Colors.sand600),
        ),
        const SizedBox(height: 4),
        const Text(
          'Downloaded areas keep the map, 3D terrain and contours working without signal.',
          style: TextStyle(fontSize: 12, color: L360Colors.sand500),
        ),
        const SizedBox(height: 12),
        FilledButton.icon(
          key: const Key('offline-new'),
          onPressed: atLimit
              ? null
              : () {
                  rec.startFraming();
                  Navigator.pop(context);
                },
          icon: const Icon(Icons.crop_free),
          label: const Text('Download an area'),
        ),
        if (atLimit)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(
              'Your plan allows ${limits.count} offline map${limits.count == 1 ? '' : 's'}. Delete one or '
              '$contactAdminLabel for more.',
              style: const TextStyle(fontSize: 12, color: L360Colors.brick600),
            ),
          ),
        if (s.error != null)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(s.error!, style: const TextStyle(fontSize: 12, color: L360Colors.brick500)),
          ),
        const SizedBox(height: 12),
        for (final v in s.regions) _RegionTile(view: v),
        if (s.records.isEmpty && !s.loading)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 24),
            child: Text(
              'No offline maps yet. Press "Download an area" before going where there is no signal.',
              textAlign: TextAlign.center,
              style: TextStyle(color: L360Colors.sand500),
            ),
          ),
      ],
    );
  }
}

class _RegionTile extends ConsumerWidget {
  const _RegionTile({required this.view});
  final OfflineRegionView view;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final r = view.record;
    final rec = ref.read(offlineProvider.notifier);
    final (status, color) = switch (view.status) {
      OfflineStatus.downloading => ('Downloading ${(view.progress * 100).round()}%', L360Colors.gold700),
      OfflineStatus.ready => ('On this phone · ${formatBytes(view.bytes ?? 0)}', L360Colors.forest700),
      OfflineStatus.notOnPhone => ('Not on this phone (saved in your account)', L360Colors.sand600),
      OfflineStatus.failed => ('Download stopped', L360Colors.brick500),
    };
    return Card(
      key: Key('offline-${r.id}'),
      margin: const EdgeInsets.only(bottom: 8),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 10, 4, 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  view.status == OfflineStatus.ready ? Icons.offline_pin : Icons.cloud_outlined,
                  color: color,
                  size: 20,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(r.name, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700)),
                      Text(
                        status,
                        style: TextStyle(fontSize: 12, color: color, fontWeight: FontWeight.w600),
                      ),
                      Text(
                        'Zoom ${r.minZoom}–${r.maxZoom} · ${r.tileCount} tiles · est. ${r.sizeEstMb.toStringAsFixed(2)} MB',
                        style: const TextStyle(fontSize: 11, color: L360Colors.sand500),
                      ),
                    ],
                  ),
                ),
                PopupMenuButton<String>(
                  key: Key('offline-more-${r.id}'),
                  tooltip: 'More',
                  icon: const Icon(Icons.more_horiz),
                  onSelected: (v) async {
                    switch (v) {
                      case 'open':
                        final (lng, lat) = r.bounds.center;
                        ref.read(flyToProvider.notifier).go(lng, lat, zoom: r.minZoom < 14 ? 14 : r.minZoom.toDouble());
                        Navigator.pop(context);
                      case 'download':
                        unawaited(rec.downloadAgain(r));
                      case 'delete':
                        final ok = await showDialog<bool>(
                          context: context,
                          builder: (context) => AlertDialog.adaptive(
                            title: Text('Delete "${r.name}"?'),
                            content: const Text('It is removed from this phone and from your account.'),
                            actions: [
                              TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
                              TextButton(
                                onPressed: () => Navigator.pop(context, true),
                                style: TextButton.styleFrom(foregroundColor: L360Colors.brick500),
                                child: const Text('Delete'),
                              ),
                            ],
                          ),
                        );
                        if (ok != true) return;
                        try {
                          await rec.delete(r);
                        } on Object catch (e) {
                          if (context.mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
                          }
                        }
                    }
                  },
                  itemBuilder: (_) => [
                    const PopupMenuItem(value: 'open', child: Text('Show on map')),
                    if (view.status == OfflineStatus.notOnPhone || view.status == OfflineStatus.failed)
                      const PopupMenuItem(value: 'download', child: Text('Download to this phone')),
                    if (view.status != OfflineStatus.downloading)
                      const PopupMenuItem(
                        value: 'delete',
                        child: Text('Delete', style: TextStyle(color: L360Colors.brick500)),
                      ),
                  ],
                ),
              ],
            ),
            if (view.status == OfflineStatus.downloading)
              Padding(
                padding: const EdgeInsets.fromLTRB(30, 8, 12, 0),
                child: LinearProgressIndicator(
                  value: view.progress,
                  minHeight: 5,
                  borderRadius: BorderRadius.circular(4),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// Darkens the map outside [frame]: what is inside is downloaded
class OfflineFrame extends StatelessWidget {
  const OfflineFrame({super.key, required this.frame});
  final Rect frame;

  @override
  Widget build(BuildContext context) => IgnorePointer(
    child: CustomPaint(key: const Key('offline-frame'), size: Size.infinite, painter: _FramePainter(frame)),
  );
}

class _FramePainter extends CustomPainter {
  const _FramePainter(this.frame);
  final Rect frame;

  @override
  void paint(Canvas canvas, Size size) {
    final outside = Path()
      ..fillType = PathFillType.evenOdd
      ..addRect(Offset.zero & size)
      ..addRRect(RRect.fromRectAndRadius(frame, const Radius.circular(12)));
    canvas
      ..drawPath(outside, Paint()..color = const Color(0x73000000))
      ..drawRRect(
        RRect.fromRectAndRadius(frame, const Radius.circular(12)),
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2.5
          ..color = Colors.white,
      );
  }

  @override
  bool shouldRepaint(_FramePainter old) => old.frame != frame;
}

/// The bar while framing: name, what to download, size against the plan, Download
class OfflineBar extends ConsumerStatefulWidget {
  const OfflineBar({super.key, required this.frame});
  final Rect frame;

  @override
  ConsumerState<OfflineBar> createState() => _OfflineBarState();
}

class _OfflineBarState extends ConsumerState<OfflineBar> {
  final _name = TextEditingController();
  bool _satellite = true;
  bool _map = true;
  OfflinePlan? _plan;
  String? _error;
  bool _busy = false;
  int _version = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _measure());
  }

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  /// Bounds of the frame on the map and the download that makes
  Future<void> _measure() async {
    final project = ref.read(mapProjectionProvider);
    if (project == null) return;
    final v = ++_version;
    final f = widget.frame;
    final corners = await Future.wait([
      project(f.left, f.top),
      project(f.right, f.bottom),
      project(f.left, f.bottom),
      project(f.right, f.top),
    ]);
    if (!mounted || v != _version || corners.any((c) => c == null)) return;
    final bounds = OfflineBounds.around([for (final c in corners) c!]);
    setState(() => _plan = OfflinePlan.of(bounds, ref.read(mapZoomProvider), satellite: _satellite, map: _map));
  }

  Future<void> _download() async {
    final plan = _plan;
    if (plan == null) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    final problem = await ref
        .read(offlineProvider.notifier)
        .download(_name.text, plan, satellite: _satellite, map: _map);
    if (!mounted) return;
    setState(() {
      _busy = false;
      _error = problem;
    });
    if (problem == null) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('Downloading… see the progress under Map → Offline maps.')));
    }
  }

  @override
  Widget build(BuildContext context) {
    // The size follows the map as it is moved and zoomed
    ref
      ..listen(mapCenterProvider, (_, _) => unawaited(_measure()))
      ..listen(mapZoomProvider, (_, _) => unawaited(_measure()));
    final rec = ref.read(offlineProvider.notifier);
    ref.watch(profileProvider);
    final plan = _plan;
    final limits = rec.limits;
    final tooBig = plan != null && plan.sizeMb > limits.sizeMb;
    return Material(
      key: const Key('offline-bar'),
      color: Colors.white,
      elevation: 6,
      shadowColor: const Color(0x40000000),
      borderRadius: BorderRadius.circular(L360.radius),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 10, 14, 12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text(
              'Move and zoom the map so the frame covers the area',
              style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 8),
            TextField(
              key: const Key('offline-name'),
              controller: _name,
              maxLength: 80,
              decoration: const InputDecoration(isDense: true, counterText: '', hintText: 'Name, e.g. Gede Pangrango'),
            ),
            const SizedBox(height: 6),
            Wrap(
              spacing: 8,
              children: [
                FilterChip(
                  key: const Key('offline-satellite'),
                  label: const Text('Satellite'),
                  selected: _satellite,
                  onSelected: (v) {
                    setState(() => _satellite = v);
                    unawaited(_measure());
                  },
                ),
                FilterChip(
                  key: const Key('offline-map'),
                  label: const Text('Map (trails, roads)'),
                  selected: _map,
                  onSelected: (v) {
                    setState(() => _map = v);
                    unawaited(_measure());
                  },
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              plan == null
                  ? 'Measuring…'
                  : 'Zoom ${plan.minZoom}–${plan.maxZoom} · ${plan.tiles} tiles · '
                        '≈ ${plan.sizeMb.toStringAsFixed(2)} MB of ${limits.sizeMb.toStringAsFixed(0)} MB',
              key: const Key('offline-estimate'),
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: tooBig ? L360Colors.brick500 : L360Colors.sand700,
              ),
            ),
            if (tooBig)
              const Text(
                'Too large for your plan: zoom in or pick a smaller area.',
                style: TextStyle(fontSize: 12, color: L360Colors.brick500),
              ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  _error!,
                  key: const Key('offline-error'),
                  style: const TextStyle(fontSize: 12, color: L360Colors.brick500),
                ),
              ),
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    style: OutlinedButton.styleFrom(minimumSize: const Size(0, 44)),
                    onPressed: rec.stopFraming,
                    child: const Text('Cancel'),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: FilledButton.icon(
                    key: const Key('offline-download'),
                    style: FilledButton.styleFrom(minimumSize: const Size(0, 44)),
                    onPressed: _busy || plan == null || tooBig ? null : _download,
                    icon: const Icon(Icons.download, size: 18),
                    label: const Text('Download'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
