import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/app_theme.dart';
import '../../core/ui/widgets.dart';
import '../../data/community/community_repository.dart' show CommunityException;
import '../../data/geo/elevation_sampler.dart';
import '../../domain/community/club_map.dart';
import '../../domain/community/community.dart';
import '../../domain/map/map_settings.dart' show MapView;
import '../../domain/marked/marked_areas.dart' show formatArea, formatLength, ringArea, ringPerimeter;
import '../map/map_settings_controller.dart';
import 'club_map_layer.dart';
import 'club_map_state.dart';
import 'community_state.dart';
import 'community_widgets.dart';

// The Map tab of a club (20261102000030): draw a pin, line, area or note on the map (everyone in
// the club sees it within 30 seconds), 3D on the terrain, the list of drawings, and saved views
// for briefings; the page of one drawing (measurements, height or elevation profile from the SRTM
// tiles, comments, edit, delete); and the form for its label, note and colour.

String _message(Object e) => e is CommunityException ? e.message : '$e';

void _toMap(BuildContext context) => Navigator.of(context).popUntil((r) => r.isFirst);

class ClubMapTab extends ConsumerStatefulWidget {
  const ClubMapTab({super.key, required this.club});

  final CommunityClub club;

  @override
  ConsumerState<ClubMapTab> createState() => _ClubMapTabState();
}

class _ClubMapTabState extends ConsumerState<ClubMapTab> {
  AnnotationKind? _filter;
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    // The club's drawings go on the map and stay fresh while shown
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(ref.read(clubMapProvider.notifier).open(widget.club));
    });
  }

  void _draw(AnnotationKind kind) {
    ref.read(clubDrawProvider.notifier).start(kind);
    _toMap(context);
  }

  Future<void> _saveView() async {
    final name = await showDialog<String>(context: context, builder: (_) => const _ViewNameDialog());
    if (name == null || !mounted) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await ref.read(clubMapProvider.notifier).saveView(name);
    } on Object catch (e) {
      if (mounted) setState(() => _error = _message(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _deleteView(SavedView v) async {
    try {
      await ref.read(clubMapProvider.notifier).deleteView(v.id);
    } on Object catch (e) {
      if (mounted) setState(() => _error = _message(e));
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = ref.watch(clubMapProvider);
    final mine = s.club?.id == widget.club.id;
    final annotations = mine ? s.annotations : const <Annotation>[];
    final views = mine ? s.views : const <SavedView>[];
    final threeD = ref.watch(mapSettingsProvider.select((m) => m.is3D));
    final list = [
      for (final a in annotations)
        if (_filter == null || a.kind == _filter) a,
    ];
    const small = TextStyle(fontSize: 12, color: L360Colors.sand600);
    return RefreshIndicator(
      onRefresh: ref.read(clubMapProvider.notifier).reload,
      child: ListView(
        key: const Key('club-map'),
        padding: const EdgeInsets.fromLTRB(L360.gutter, 12, L360.gutter, 32),
        children: [
          const Text(
            'Draw on the club map: everyone in the club sees it on the map, in 2D or on the 3D terrain. '
            'Changes from others show within 30 seconds.',
            style: small,
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              for (final k in AnnotationKind.values) ...[
                Expanded(
                  child: _KindButton(kind: k, onTap: () => _draw(k)),
                ),
                if (k != AnnotationKind.values.last) const SizedBox(width: 8),
              ],
            ],
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              PillChip(
                key: const Key('club-map-3d'),
                label: threeD ? '3D terrain on' : 'View in 3D',
                on: threeD,
                leading: Icon(Icons.view_in_ar, size: 16, color: threeD ? Colors.white : L360Colors.forest700),
                onTap: () => ref.read(mapSettingsProvider.notifier).setView(threeD ? MapView.twoD : MapView.threeD),
              ),
              if (annotations.isNotEmpty)
                PillChip(
                  key: const Key('club-map-show-all'),
                  label: 'Show all on map',
                  on: false,
                  leading: const Icon(Icons.map_outlined, size: 16, color: L360Colors.forest700),
                  onTap: () {
                    ref.read(clubMapProvider.notifier)
                      ..select(null)
                      ..fit();
                    _toMap(context);
                  },
                ),
            ],
          ),
          if (_error != null || (mine && s.error != null)) ...[
            const SizedBox(height: 10),
            ErrorBanner(_error ?? s.error!),
          ],
          const SizedBox(height: 14),
          if (!mine || (s.loading && annotations.isEmpty))
            const LoadingCards(count: 2)
          else if (annotations.isEmpty)
            const EmptyState(
              icon: Icons.draw_outlined,
              title: 'Nothing drawn yet',
              text:
                  'Mark a water source, a shortcut, a camp area or a note for the team. Everyone in the club sees it.',
            )
          else ...[
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  PillChip(
                    key: const Key('club-map-filter-all'),
                    label: 'All · ${annotations.length}',
                    on: _filter == null,
                    onTap: () => setState(() => _filter = null),
                  ),
                  for (final k in AnnotationKind.values)
                    if (annotations.any((a) => a.kind == k)) ...[
                      const SizedBox(width: 6),
                      PillChip(
                        key: Key('club-map-filter-${k.name}'),
                        label: '${k.label}s',
                        on: _filter == k,
                        onTap: () => setState(() => _filter = _filter == k ? null : k),
                      ),
                    ],
                ],
              ),
            ),
            const SizedBox(height: 8),
            CommunityCard(
              child: Column(
                children: [
                  for (final a in list) ...[
                    _AnnotationTile(a: a),
                    if (a != list.last) const Divider(height: 1, indent: 52),
                  ],
                ],
              ),
            ),
          ],
          const SizedBox(height: 20),
          Row(
            children: [
              const Expanded(child: SectionLabel('Saved views')),
              TextButton.icon(
                key: const Key('club-view-save'),
                onPressed: _busy || !mine ? null : _saveView,
                icon: const Icon(Icons.videocam_outlined, size: 18),
                label: const Text('Save this view'),
              ),
            ],
          ),
          if (views.isEmpty)
            const Text(
              'Save the camera as it is on the map now (position, zoom, tilt, 2D or 3D) so the team can jump to it '
              'in a briefing.',
              style: small,
            )
          else
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final v in views)
                  PillChip(
                    key: Key('club-view-${v.id}'),
                    label: v.name,
                    on: false,
                    leading: Icon(
                      v.terrain ? Icons.view_in_ar : Icons.place_outlined,
                      size: 16,
                      color: L360Colors.gold700,
                    ),
                    trailing: v.isMine || widget.club.canManage
                        ? GestureDetector(
                            key: Key('club-view-delete-${v.id}'),
                            onTap: () => _deleteView(v),
                            child: const Icon(Icons.close, size: 16, color: L360Colors.sand500),
                          )
                        : null,
                    onTap: () {
                      ref.read(clubMapProvider.notifier).flyTo(v);
                      _toMap(context);
                    },
                  ),
              ],
            ),
        ],
      ),
    );
  }
}

class _KindButton extends StatelessWidget {
  const _KindButton({required this.kind, required this.onTap});

  final AnnotationKind kind;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Material(
    color: Colors.white,
    shape: RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(L360.radiusSmall),
      side: const BorderSide(color: L360Colors.sand200),
    ),
    child: InkWell(
      key: Key('club-draw-${kind.name}'),
      borderRadius: BorderRadius.circular(L360.radiusSmall),
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 10),
        child: Column(
          children: [
            Icon(annotationIcon(kind), size: 20, color: L360Colors.gold700),
            const SizedBox(height: 4),
            FittedBox(
              fit: BoxFit.scaleDown,
              child: Text(kind.label, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700)),
            ),
          ],
        ),
      ),
    ),
  );
}

class _AnnotationTile extends ConsumerWidget {
  const _AnnotationTile({required this.a});

  final Annotation a;

  @override
  Widget build(BuildContext context, WidgetRef ref) => ListTile(
    key: Key('annotation-${a.id}'),
    dense: true,
    leading: Icon(annotationIcon(a.kind), color: hexToColor(a.color)),
    title: Text(a.label, maxLines: 1, overflow: TextOverflow.ellipsis),
    subtitle: Text(
      [a.authorName, ?a.measure].where((t) => t.isNotEmpty).join(' · '),
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
    ),
    trailing: a.commentCount > 0
        ? Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.chat_bubble_outline, size: 14, color: L360Colors.sand500),
              const SizedBox(width: 3),
              Text('${a.commentCount}', style: const TextStyle(fontSize: 12, color: L360Colors.sand600)),
            ],
          )
        : null,
    onTap: () => openAnnotation(context, ref, a),
  );
}

class _ViewNameDialog extends StatefulWidget {
  const _ViewNameDialog();

  @override
  State<_ViewNameDialog> createState() => _ViewNameDialogState();
}

class _ViewNameDialogState extends State<_ViewNameDialog> {
  final _name = TextEditingController();

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Save this view'),
    content: TextField(
      key: const Key('club-view-name'),
      controller: _name,
      autofocus: true,
      maxLength: viewNameMax,
      decoration: const InputDecoration(hintText: 'e.g. Briefing: summit approach'),
      onChanged: (_) => setState(() {}),
    ),
    actions: [
      TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
      TextButton(
        key: const Key('club-view-name-save'),
        onPressed: _name.text.trim().isEmpty ? null : () => Navigator.pop(context, _name.text.trim()),
        child: const Text('Save'),
      ),
    ],
  );
}

// --- One drawing ---------------------------------------------------------------------------------

/// Selects [a] on the map and opens its page
Future<void> openAnnotation(BuildContext context, WidgetRef ref, Annotation a) {
  ref.read(clubMapProvider.notifier).select(a.id);
  return Navigator.of(
    context,
    rootNavigator: true,
  ).push(MaterialPageRoute<void>(builder: (_) => AnnotationPage(annotationId: a.id)));
}

final _commentsProvider = FutureProvider.autoDispose.family<List<AnnotationComment>, (String, int)>(
  (ref, key) => ref.watch(clubMapRepositoryProvider).comments(key.$1),
);

class AnnotationPage extends ConsumerStatefulWidget {
  const AnnotationPage({super.key, required this.annotationId});

  final String annotationId;

  @override
  ConsumerState<AnnotationPage> createState() => _AnnotationPageState();
}

class _AnnotationPageState extends ConsumerState<AnnotationPage> {
  final _comment = TextEditingController();
  ({List<double> dist, List<double> heights})? _profile;
  bool _profiling = false;
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _comment.dispose();
    super.dispose();
  }

  Future<void> _act(Future<void> Function() fn) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await fn();
    } on Object catch (e) {
      if (mounted) setState(() => _error = _message(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Height at a pin, or the profile along a line or around an area, from the SRTM tiles
  Future<void> _analyse(Annotation a) async {
    setState(() {
      _profiling = true;
      _error = null;
    });
    try {
      final pts = a.points;
      final line = a.kind == AnnotationKind.area && pts.length >= 3 ? [...pts, pts.first] : pts;
      final samples = line.length == 1 ? [(at: line.first, distM: 0.0)] : densifyLine(line);
      final heights = await ref.read(elevationSamplerProvider).sample([for (final s in samples) s.at]);
      if (mounted) {
        setState(() => _profile = (dist: [for (final s in samples) s.distM], heights: heights));
      }
    } on ElevationException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } on Object {
      if (mounted) setState(() => _error = 'Could not read the elevation data.');
    } finally {
      if (mounted) setState(() => _profiling = false);
    }
  }

  Future<void> _delete(Annotation a) async {
    final ok = await confirmDialog(
      context,
      title: 'Delete this drawing?',
      message: '"${a.label}" and its comments are removed for everyone in the club.',
      action: 'Delete',
    );
    if (!ok || !mounted) return;
    await _act(() async {
      await ref.read(clubMapProvider.notifier).delete(a.id);
      if (mounted) Navigator.of(context).pop();
    });
  }

  @override
  Widget build(BuildContext context) {
    final s = ref.watch(clubMapProvider);
    final a = s.annotations.where((x) => x.id == widget.annotationId).firstOrNull;
    if (a == null) {
      return Scaffold(
        appBar: AppBar(),
        body: const Center(child: Text('This drawing is no longer there.')),
      );
    }
    final club = s.club;
    final canEdit = a.isMine || (club?.canManage ?? false);
    final now = ref.watch(communityClockProvider)();
    final comments = ref.watch(_commentsProvider((a.id, a.commentCount)));
    final pts = a.points;
    final stats = _profile == null ? null : profileStats(_profile!.heights);
    final color = hexToColor(a.color);
    Widget pill(String text, {Key? key}) => Container(
      key: key,
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(color: L360Colors.sand100, borderRadius: BorderRadius.circular(20)),
      child: Text(text, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700)),
    );
    return Scaffold(
      appBar: AppBar(
        title: Text(a.kind.label),
        actions: [
          if (canEdit)
            IconButton(
              key: const Key('annotation-edit'),
              tooltip: 'Edit',
              icon: const Icon(Icons.edit_outlined),
              onPressed: () {
                ref.read(clubDrawProvider.notifier).start(a.kind, existing: a);
                _toMap(context);
              },
            ),
        ],
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(L360.gutter),
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Icon(annotationIcon(a.kind), color: color),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(a.label, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
                      Text(
                        '${a.authorName} · ${timeAgo(a.updatedAt, now)}',
                        style: const TextStyle(fontSize: 12, color: L360Colors.sand600),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            if (a.note != null) ...[
              const SizedBox(height: 10),
              Text(a.note!, style: const TextStyle(fontSize: 14, height: 1.45)),
            ],
            const SizedBox(height: 12),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                if (a.kind == AnnotationKind.line)
                  pill('Length ${formatLength(lineLengthM(pts))}', key: const Key('annotation-length')),
                if (a.kind == AnnotationKind.area) ...[
                  pill('Area ${formatArea(ringArea(pts))}', key: const Key('annotation-area')),
                  pill('Perimeter ${formatLength(ringPerimeter(pts))}'),
                ],
                if (a.kind.isPoint && pts.isNotEmpty)
                  pill('${pts.first.$2.toStringAsFixed(5)}, ${pts.first.$1.toStringAsFixed(5)}'),
              ],
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                OutlinedButton.icon(
                  key: const Key('annotation-show'),
                  onPressed: () {
                    ref.read(clubMapProvider.notifier)
                      ..select(a.id)
                      ..fit(a);
                    _toMap(context);
                  },
                  icon: const Icon(Icons.map_outlined, size: 18),
                  label: const Text('Show on map'),
                ),
                if (_profile == null)
                  OutlinedButton.icon(
                    key: const Key('annotation-elevation'),
                    onPressed: _profiling ? null : () => _analyse(a),
                    icon: _profiling
                        ? const SizedBox.square(dimension: 16, child: CircularProgressIndicator(strokeWidth: 2))
                        : const Icon(Icons.terrain_outlined, size: 18),
                    label: Text(a.kind.isPoint ? 'Height here' : 'Elevation profile'),
                  ),
              ],
            ),
            if (_profile != null) ...[
              const SizedBox(height: 12),
              if (a.kind.isPoint)
                Text(
                  _profile!.heights.first.isFinite
                      ? '${_profile!.heights.first.round()} m above sea level'
                      : 'No elevation data here.',
                  key: const Key('annotation-height'),
                  style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
                )
              else ...[
                SizedBox(
                  height: 120,
                  child: CustomPaint(
                    key: const Key('annotation-profile'),
                    painter: ElevationChartPainter(dist: _profile!.dist, heights: _profile!.heights, color: color),
                    size: Size.infinite,
                  ),
                ),
                if (stats != null) ...[
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      for (final (k, v) in [
                        ('Lowest', '${stats.min.round()} m'),
                        ('Highest', '${stats.max.round()} m'),
                        ('Climb', '+${stats.gain.round()} m'),
                        ('Descent', '−${stats.loss.round()} m'),
                      ]) ...[
                        Expanded(
                          child: _Stat(label: k, value: v),
                        ),
                        if (k != 'Descent') const SizedBox(width: 6),
                      ],
                    ],
                  ),
                ],
                const SizedBox(height: 6),
                Text(
                  'From SRTM elevation data (~30 m). Height difference start to end: '
                  '${stats == null ? '–' : '${(stats.end - stats.start).round()} m'}.',
                  style: const TextStyle(fontSize: 11, color: L360Colors.sand500),
                ),
              ],
            ],
            if (_error != null) ...[const SizedBox(height: 10), ErrorBanner(_error!)],
            const SizedBox(height: 20),
            const SectionLabel('Comments'),
            switch (comments) {
              AsyncData(:final value) when value.isEmpty => const Padding(
                padding: EdgeInsets.symmetric(vertical: 4),
                child: Text('No comments yet.', style: TextStyle(fontSize: 13, color: L360Colors.sand600)),
              ),
              AsyncData(:final value) => Column(
                children: [
                  for (final c in value)
                    Padding(
                      key: Key('annotation-comment-${c.id}'),
                      padding: const EdgeInsets.symmetric(vertical: 4),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Expanded(
                            child: Text.rich(
                              TextSpan(
                                children: [
                                  TextSpan(
                                    text: '${c.authorName} ',
                                    style: const TextStyle(fontWeight: FontWeight.w700),
                                  ),
                                  TextSpan(text: c.body),
                                ],
                              ),
                              style: const TextStyle(fontSize: 13, height: 1.4),
                            ),
                          ),
                          if (c.isMine || (club?.canManage ?? false))
                            IconButton(
                              tooltip: 'Delete comment',
                              visualDensity: VisualDensity.compact,
                              icon: const Icon(Icons.close, size: 16, color: L360Colors.brick500),
                              onPressed: _busy
                                  ? null
                                  : () => _act(() async {
                                      await ref.read(clubMapRepositoryProvider).deleteComment(c.id);
                                      await ref.read(clubMapProvider.notifier).reload();
                                    }),
                            ),
                        ],
                      ),
                    ),
                ],
              ),
              AsyncError(:final error) => ErrorBanner(_message(error)),
              _ => const LinearProgressIndicator(),
            },
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    key: const Key('annotation-comment'),
                    controller: _comment,
                    maxLength: annotationCommentMax,
                    minLines: 1,
                    maxLines: 4,
                    decoration: const InputDecoration(hintText: 'Comment…', counterText: ''),
                    onChanged: (_) => setState(() {}),
                  ),
                ),
                const SizedBox(width: 8),
                FilledButton(
                  key: const Key('annotation-comment-send'),
                  // The theme's buttons are full width; this one sits next to the field
                  style: FilledButton.styleFrom(minimumSize: const Size(0, 44)),
                  onPressed: _busy || _comment.text.trim().isEmpty
                      ? null
                      : () => _act(() async {
                          await ref.read(clubMapRepositoryProvider).addComment(a.id, _comment.text);
                          _comment.clear();
                          await ref.read(clubMapProvider.notifier).reload();
                        }),
                  child: const Text('Send'),
                ),
              ],
            ),
            if (canEdit) ...[
              const SizedBox(height: 24),
              Center(
                child: TextButton.icon(
                  key: const Key('annotation-delete'),
                  style: TextButton.styleFrom(foregroundColor: L360Colors.brick500),
                  onPressed: _busy ? null : () => _delete(a),
                  icon: const Icon(Icons.delete_outline, size: 18),
                  label: const Text('Delete drawing'),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _Stat extends StatelessWidget {
  const _Stat({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(vertical: 6),
    decoration: BoxDecoration(
      color: L360Colors.sand50,
      borderRadius: BorderRadius.circular(L360.radiusSmall),
      border: Border.all(color: L360Colors.sand100),
    ),
    child: Column(
      children: [
        FittedBox(
          fit: BoxFit.scaleDown,
          child: Text(value, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700)),
        ),
        Text(label, style: const TextStyle(fontSize: 11, color: L360Colors.sand600)),
      ],
    ),
  );
}

/// Distance along the line against height, filled below, with the highest, lowest and length
class ElevationChartPainter extends CustomPainter {
  ElevationChartPainter({required this.dist, required this.heights, required this.color});

  final List<double> dist;
  final List<double> heights;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final pts = [
      for (var i = 0; i < dist.length && i < heights.length; i++)
        if (heights[i].isFinite) (dist[i], heights[i]),
    ];
    if (pts.length < 2) return;
    final w = size.width, h = size.height;
    final maxD = pts.last.$1 == 0 ? 1.0 : pts.last.$1;
    final lo = pts.map((p) => p.$2).reduce(math.min);
    final hi = pts.map((p) => p.$2).reduce(math.max);
    final span = math.max(hi - lo, 10.0);
    Offset xy((double, double) p) => Offset(p.$1 / maxD * w, h - 14 - (p.$2 - lo) / span * (h - 28));
    final line = Path()..moveTo(xy(pts.first).dx, xy(pts.first).dy);
    for (final p in pts.skip(1)) {
      line.lineTo(xy(p).dx, xy(p).dy);
    }
    final fill = Path.from(line)
      ..lineTo(w, h)
      ..lineTo(0, h)
      ..close();
    canvas
      ..drawPath(fill, Paint()..color = color.withValues(alpha: 0.15))
      ..drawPath(
        line,
        Paint()
          ..color = color
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2
          ..strokeJoin = StrokeJoin.round,
      );
    void label(String text, Offset at, {bool right = false}) {
      final tp = TextPainter(
        text: TextSpan(
          text: text,
          style: const TextStyle(fontSize: 10, color: L360Colors.sand600),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(canvas, right ? at - Offset(tp.width, 0) : at);
    }

    label('${hi.round()} m', const Offset(2, 0));
    label('${lo.round()} m', Offset(2, h - 12));
    label(formatLength(maxD), Offset(w - 2, h - 12), right: true);
  }

  @override
  bool shouldRepaint(ElevationChartPainter old) => old.dist != dist || old.heights != heights || old.color != color;
}

// --- Label, note and colour ---------------------------------------------------------------------

/// After the points: the label, note and colour, then Save (or back to the map to change the shape)
class AnnotationFormPage extends ConsumerStatefulWidget {
  const AnnotationFormPage({super.key, required this.draw});

  final ClubDraw draw;

  @override
  ConsumerState<AnnotationFormPage> createState() => _AnnotationFormPageState();
}

class _AnnotationFormPageState extends ConsumerState<AnnotationFormPage> {
  late final _label = TextEditingController(text: widget.draw.label);
  late final _note = TextEditingController(text: widget.draw.note);
  late String _color = widget.draw.color;
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _label.dispose();
    _note.dispose();
    super.dispose();
  }

  ClubDraw get _current => widget.draw.copyWith(label: _label.text, note: _note.text, color: _color);

  Future<void> _save() async {
    final d = _current;
    if (d.label.trim().isEmpty) return setState(() => _error = 'Give it a label.');
    final geometry = annotationGeometry(d.kind, d.points);
    if (geometry == null) return setState(() => _error = 'Add more points on the map first.');
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final map = ref.read(clubMapProvider.notifier);
      final id = await map.save(
        d.editingId,
        kind: d.kind,
        label: d.label,
        note: d.note,
        color: d.color,
        geometry: geometry,
      );
      if (!mounted) return;
      final saved = ref.read(clubMapProvider).annotations.where((a) => a.id == id).firstOrNull;
      Navigator.of(context).pop();
      // Back on the map, the new drawing fits the screen
      if (saved != null) map.fit(saved);
    } on Object catch (e) {
      if (mounted) setState(() => _error = _message(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final d = widget.draw;
    final pts = d.points;
    final measure = d.kind == AnnotationKind.line
        ? 'Length ${formatLength(lineLengthM(pts))}'
        : d.kind == AnnotationKind.area
        ? 'Area ${formatArea(ringArea(pts))}'
        : null;
    return Scaffold(
      appBar: AppBar(title: Text(d.editingId == null ? 'New ${d.kind.label.toLowerCase()}' : 'Edit drawing')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(L360.gutter),
          children: [
            if (measure != null) ...[
              Text(measure, style: const TextStyle(color: L360Colors.sand600)),
              const SizedBox(height: 12),
            ],
            TextField(
              key: const Key('annotation-label'),
              controller: _label,
              autofocus: d.label.isEmpty,
              maxLength: annotationLabelMax,
              textCapitalization: TextCapitalization.sentences,
              decoration: const InputDecoration(labelText: 'Label', hintText: 'e.g. Water source'),
            ),
            const SizedBox(height: 8),
            TextField(
              key: const Key('annotation-note'),
              controller: _note,
              maxLength: annotationNoteMax,
              minLines: 2,
              maxLines: 6,
              textCapitalization: TextCapitalization.sentences,
              decoration: const InputDecoration(labelText: 'Note (optional)'),
            ),
            const SizedBox(height: 8),
            const SectionLabel('Colour'),
            const SizedBox(height: 6),
            Wrap(
              spacing: 10,
              runSpacing: 10,
              children: [
                for (final c in annotationColors)
                  Semantics(
                    selected: _color == c,
                    label: c,
                    button: true,
                    child: GestureDetector(
                      key: Key('annotation-color-$c'),
                      onTap: () => setState(() => _color = c),
                      child: AnimatedContainer(
                        duration: const Duration(milliseconds: 150),
                        width: 36,
                        height: 36,
                        decoration: BoxDecoration(
                          color: hexToColor(c),
                          shape: BoxShape.circle,
                          border: Border.all(color: _color == c ? L360Colors.ink : Colors.white, width: 3),
                          boxShadow: const [BoxShadow(color: Color(0x33000000), blurRadius: 3)],
                        ),
                      ),
                    ),
                  ),
              ],
            ),
            if (_error != null) ...[const SizedBox(height: 12), ErrorBanner(_error!)],
            const SizedBox(height: 20),
            KeyedSubtree(
              key: const Key('annotation-save'),
              child: BusyButton(label: 'Save', busy: _busy, onPressed: _save),
            ),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              key: const Key('annotation-change-shape'),
              onPressed: _busy
                  ? null
                  : () {
                      ref.read(clubDrawProvider.notifier).resume(_current);
                      Navigator.of(context).pop();
                    },
              icon: const Icon(Icons.edit_location_alt_outlined, size: 18),
              label: const Text('Change shape on the map'),
            ),
          ],
        ),
      ),
    );
  }
}
