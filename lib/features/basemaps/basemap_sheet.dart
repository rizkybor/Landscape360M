import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/providers.dart';
import '../../core/theme/app_theme.dart';
import '../../data/basemaps/custom_basemaps.dart';
import '../map/map_tools_state.dart';
import '../offline/offline_state.dart' show formatBytes;
import '../tracks/track_recorder_panel.dart' show contactAdminLabel;
import 'basemap_state.dart';

// Custom basemaps (BasemapManager.tsx without the upload, which stays on the web): the
// account's basemaps with on / off, opacity, zoom to the basemap and delete.

Future<void> showBasemapSheet(BuildContext context) => showModalBottomSheet<void>(
  context: context,
  isScrollControlled: true,
  useSafeArea: true,
  builder: (_) => DraggableScrollableSheet(
    expand: false,
    initialChildSize: 0.6,
    maxChildSize: 0.95,
    builder: (context, controller) => _BasemapList(controller: controller),
  ),
);

class _BasemapList extends ConsumerStatefulWidget {
  const _BasemapList({required this.controller});
  final ScrollController controller;

  @override
  ConsumerState<_BasemapList> createState() => _BasemapListState();
}

class _BasemapListState extends ConsumerState<_BasemapList> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && ref.read(basemapsProvider.notifier).canUse) {
        unawaited(ref.read(basemapsProvider.notifier).refresh());
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final s = ref.watch(basemapsProvider);
    ref.watch(profileProvider);
    final rec = ref.read(basemapsProvider.notifier);
    final site = ref.watch(appConfigProvider).apiBaseUrl;
    return ListView(
      controller: widget.controller,
      padding: const EdgeInsets.fromLTRB(L360.gutter, 0, L360.gutter, 32),
      children: [
        Row(
          children: [
            Expanded(child: Text('Custom basemaps', style: Theme.of(context).textTheme.titleLarge)),
            if (s.loading) const SizedBox.square(dimension: 18, child: CircularProgressIndicator(strokeWidth: 2)),
          ],
        ),
        if (!rec.canUse)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 16),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Icons.lock_outline, color: L360Colors.sand500),
                SizedBox(width: 10),
                Expanded(
                  child: Text(
                    'Custom basemaps are available for Enterprise accounts. $contactAdminLabel to enable them.',
                    style: TextStyle(color: L360Colors.sand700, height: 1.35),
                  ),
                ),
              ],
            ),
          )
        else ...[
          Text(
            'Storage ${formatBytes(s.usedBytes)} of ${formatBytes(basemapStorageLimit)}',
            style: const TextStyle(color: L360Colors.sand600),
          ),
          const SizedBox(height: 6),
          LinearProgressIndicator(
            value: (s.usedBytes / basemapStorageLimit).clamp(0, 1),
            minHeight: 6,
            borderRadius: BorderRadius.circular(4),
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              const Expanded(
                child: Text(
                  'Upload GeoTIFF or PDF maps on the web; they show here. Switched-on basemaps are kept on this '
                  'phone and work without signal.',
                  style: TextStyle(fontSize: 12, color: L360Colors.sand500, height: 1.35),
                ),
              ),
              TextButton.icon(
                style: TextButton.styleFrom(minimumSize: const Size(0, 36)),
                onPressed: () => launchUrl(Uri.parse(site), mode: LaunchMode.externalApplication),
                icon: const Icon(Icons.open_in_new, size: 16),
                label: const Text('Web'),
              ),
            ],
          ),
          if (s.error != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(s.error!, style: const TextStyle(fontSize: 12, color: L360Colors.brick500)),
            ),
          const SizedBox(height: 12),
          for (final b in s.basemaps) _BasemapTile(basemap: b),
          if (s.basemaps.isEmpty && !s.loading)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 24),
              child: Text(
                'No basemaps yet. Upload one on the web.',
                textAlign: TextAlign.center,
                style: TextStyle(color: L360Colors.sand500),
              ),
            ),
        ],
      ],
    );
  }
}

class _BasemapTile extends ConsumerWidget {
  const _BasemapTile({required this.basemap});
  final CustomBasemap basemap;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final b = basemap;
    final s = ref.watch(basemapsProvider);
    final rec = ref.read(basemapsProvider.notifier);
    final onPhone = s.files.containsKey(b.id);
    return Card(
      key: Key('basemap-${b.id}'),
      margin: const EdgeInsets.only(bottom: 8),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 6, 4, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(b.name, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700)),
                      Text(
                        [
                          formatBytes(b.fileSize),
                          if (b.bounds == null)
                            'no position'
                          else if (b.active)
                            onPhone ? 'on this phone' : 'downloading…',
                        ].join(' · '),
                        style: const TextStyle(fontSize: 12, color: L360Colors.sand600),
                      ),
                    ],
                  ),
                ),
                if (b.bounds != null)
                  IconButton(
                    key: Key('basemap-zoom-${b.id}'),
                    tooltip: 'Zoom to basemap',
                    icon: const Icon(Icons.center_focus_strong, size: 20),
                    onPressed: () {
                      final g = b.bounds!;
                      ref.read(fitPointsProvider.notifier).go([(g.west, g.south), (g.east, g.north)]);
                      Navigator.pop(context);
                    },
                  ),
                Switch.adaptive(
                  key: Key('basemap-switch-${b.id}'),
                  value: b.active,
                  onChanged: (v) => rec.setActive(b.id, v),
                ),
                PopupMenuButton<String>(
                  tooltip: 'More',
                  icon: const Icon(Icons.more_horiz),
                  onSelected: (_) async {
                    final ok = await showDialog<bool>(
                      context: context,
                      builder: (context) => AlertDialog.adaptive(
                        title: Text('Delete "${b.name}"?'),
                        content: const Text('It is removed from your account, the web and this phone.'),
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
                      await rec.delete(b);
                    } on Object catch (e) {
                      if (context.mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
                      }
                    }
                  },
                  itemBuilder: (_) => const [
                    PopupMenuItem(
                      value: 'delete',
                      child: Text('Delete', style: TextStyle(color: L360Colors.brick500)),
                    ),
                  ],
                ),
              ],
            ),
            if (b.active)
              Row(
                children: [
                  const Text('Opacity', style: TextStyle(fontSize: 12, color: L360Colors.sand600)),
                  Expanded(
                    child: Slider.adaptive(
                      key: Key('basemap-opacity-${b.id}'),
                      value: s.opacityOf(b.id),
                      onChanged: (v) => rec.setOpacity(b.id, v),
                    ),
                  ),
                  SizedBox(
                    width: 44,
                    child: Text(
                      '${(s.opacityOf(b.id) * 100).round()}%',
                      style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700),
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
