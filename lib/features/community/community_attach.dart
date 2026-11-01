import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/app_theme.dart';
import '../../domain/community/community_attachments.dart';
import '../../domain/marked/marked_areas.dart' show formatArea, formatLength;
import '../../domain/tracks/recorded_track.dart';
import '../areas/area_state.dart';
import '../classic/classic_state.dart';
import '../marked/marked_state.dart';
import '../tracks/track_recorder_state.dart';

// Choosing the map data to attach (Pro, Enterprise, admin): one of my marked locations, marked
// areas, recorded tracks in the cloud, or a Classic Field Work I share by link. Locations, areas
// and tracks go as a copy; a track is thinned to 1500 points.

/// [trackPoints]: how far a track is thinned (1500 for a post, 5000 for a club workspace)
Future<Attachment?> pickAttachment(BuildContext context, {int trackPoints = maxTrackPoints}) =>
    showModalBottomSheet<Attachment>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (_) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.7,
        maxChildSize: 0.95,
        builder: (context, controller) => _AttachList(controller: controller, trackPoints: trackPoints),
      ),
    );

class _AttachList extends ConsumerStatefulWidget {
  const _AttachList({required this.controller, required this.trackPoints});

  final ScrollController controller;
  final int trackPoints;

  @override
  ConsumerState<_AttachList> createState() => _AttachListState();
}

class _AttachListState extends ConsumerState<_AttachList> {
  String? _loadingTrack;
  String? _error;

  Future<void> _track(RecordedTrack t) async {
    setState(() {
      _loadingTrack = t.id;
      _error = null;
    });
    try {
      final points = await ref.read(trackCloudProvider).fetchPoints(t.id);
      if (!mounted) return;
      if (points.length < 2) {
        setState(() {
          _loadingTrack = null;
          _error = 'This track has no points in the cloud yet.';
        });
        return;
      }
      Navigator.pop(
        context,
        trackAttachment(
          name: t.name,
          distanceM: t.stats.distanceM,
          points: [for (final p in points) (p.lng, p.lat)],
          maxPoints: widget.trackPoints,
        ),
      );
    } on Object catch (e) {
      if (mounted) {
        setState(() {
          _loadingTrack = null;
          _error = '$e';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final places = ref.watch(markedProvider.select((s) => s.mine));
    final areas = ref.watch(areasProvider.select((s) => s.areas));
    final tracks = ref
        .watch(trackRecorderProvider.select((s) => s.tracks))
        .where((t) => t.syncStatus == TrackSyncStatus.synced || t.syncStatus == TrackSyncStatus.remote)
        .toList();
    final fieldWorks = [
      for (final list in ref.watch(classicProvider.select((s) => s.fieldWorks)).values)
        for (final f in list)
          if (f.shareToken != null) f,
    ];
    Widget section(String title) => Padding(
      padding: const EdgeInsets.only(top: 14, bottom: 4),
      child: Text(
        title,
        style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: L360Colors.sand600),
      ),
    );
    Widget none(String text) => Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Text(text, style: const TextStyle(fontSize: 12, color: L360Colors.sand500)),
    );
    return ListView(
      key: const Key('attach-list'),
      controller: widget.controller,
      padding: const EdgeInsets.fromLTRB(L360.gutter, 0, L360.gutter, 32),
      children: [
        Text('Attach map data', style: Theme.of(context).textTheme.titleLarge),
        const Text(
          'A copy goes with the post, so readers see it even if you change or delete the original.',
          style: TextStyle(fontSize: 12, color: L360Colors.sand600),
        ),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(_error!, style: const TextStyle(color: L360Colors.brick500, fontSize: 12)),
          ),
        section('RECORDED TRACKS'),
        if (tracks.isEmpty) none('No tracks in the cloud yet.'),
        for (final t in tracks)
          ListTile(
            key: Key('attach-track-${t.id}'),
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.timeline, color: L360Colors.forest700),
            title: Text(t.name),
            subtitle: Text(formatLength(t.stats.distanceM)),
            trailing: _loadingTrack == t.id
                ? const SizedBox.square(dimension: 18, child: CircularProgressIndicator(strokeWidth: 2))
                : null,
            onTap: _loadingTrack == null ? () => unawaited(_track(t)) : null,
          ),
        section('MARKED AREAS'),
        if (areas.isEmpty) none('No marked areas yet.'),
        for (final a in areas)
          ListTile(
            key: Key('attach-area-${a.id}'),
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.hexagon_outlined, color: L360Colors.gold700),
            title: Text(a.name),
            subtitle: Text(formatArea(a.areaM2)),
            onTap: () => Navigator.pop(context, areaAttachment(name: a.name, color: a.color, ring: a.ring)),
          ),
        section('MARKED LOCATIONS'),
        if (places.isEmpty) none('No marked locations yet.'),
        for (final l in places)
          ListTile(
            key: Key('attach-place-${l.id}'),
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.pin_drop_outlined, color: L360Colors.forest700),
            title: Text(l.name),
            subtitle: Text(l.category.label),
            onTap: () => Navigator.pop(
              context,
              placeAttachment(name: l.name, category: l.category.name, lat: l.lat, lng: l.lng),
            ),
          ),
        section('CLASSIC FIELD WORKS (SHARED BY LINK)'),
        if (fieldWorks.isEmpty) none('Share a Field Work from Classic to attach it.'),
        for (final f in fieldWorks)
          ListTile(
            key: Key('attach-classic-${f.id}'),
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.architecture, color: L360Colors.forest700),
            title: Text(f.name),
            onTap: () => Navigator.pop(context, classicAttachment(name: f.name, token: f.shareToken)),
          ),
      ],
    );
  }
}
