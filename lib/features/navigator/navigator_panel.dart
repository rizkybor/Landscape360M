import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/providers.dart';
import '../../core/theme/app_theme.dart';
import '../../domain/survey/survey_model.dart';
import '../../domain/survey/survey_utils.dart';
import 'navigator_state.dart';

// The Navigator's panel above the sheet (like the web's SurveyorPanel on phones): the
// active sheet, line mode and angle snap, corners, and the points and saved surveys

const lineHint =
    'Tap the map to add a point. Drag a point to move it. Press and hold a point, then drag, to bend the line. '
    'Tap a point to show its curve handles.';

Color _hex(String hex) => Color(int.parse('FF${hex.replaceFirst('#', '')}', radix: 16));

class NavigatorPanel extends ConsumerWidget {
  const NavigatorPanel({super.key, required this.onShowSurvey});

  /// Called with a survey just opened, so the map can show it
  final ValueChanged<SurveyDoc> onShowSurvey;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(navigatorProvider);
    final nav = ref.read(navigatorProvider.notifier);
    final g = s.doc.activeGroup;
    final signedIn = ref.watch(authUserIdProvider).value != null;
    return Material(
      key: const Key('navigator-panel'),
      color: Colors.white,
      elevation: 6,
      shadowColor: const Color(0x40000000),
      borderRadius: BorderRadius.circular(L360.radius),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 4, 10),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                const Icon(Icons.straighten, size: 20, color: L360Colors.gold700),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text('Navigator', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700)),
                      Text(
                        g == null
                            ? 'Tap the map to add the first point'
                            : '${g.points.length} point${g.points.length == 1 ? '' : 's'} · ${formatDistance(g.totalDistance)}',
                        style: const TextStyle(fontSize: 11, color: L360Colors.sand500),
                      ),
                    ],
                  ),
                ),
                _SyncBadge(state: s, signedIn: signedIn),
                IconButton(
                  key: const Key('navigator-points'),
                  tooltip: 'Points',
                  visualDensity: VisualDensity.compact,
                  icon: const Icon(Icons.format_list_numbered, size: 20),
                  onPressed: () => showPointsSheet(context),
                ),
                IconButton(
                  key: const Key('navigator-surveys'),
                  tooltip: 'Saved surveys',
                  visualDensity: VisualDensity.compact,
                  icon: const Icon(Icons.folder_open_outlined, size: 20),
                  onPressed: () => showSurveysSheet(context, onShowSurvey),
                ),
                IconButton(
                  key: const Key('navigator-close'),
                  tooltip: 'Close Navigator',
                  visualDensity: VisualDensity.compact,
                  icon: const Icon(Icons.close, size: 20),
                  onPressed: nav.close,
                ),
              ],
            ),
            if (s.error != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(2, 4, 8, 0),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(s.error!, style: const TextStyle(fontSize: 12, color: L360Colors.brick500)),
                    ),
                    GestureDetector(
                      onTap: nav.clearError,
                      child: const Icon(Icons.close, size: 14, color: L360Colors.brick500),
                    ),
                  ],
                ),
              ),
            const SizedBox(height: 6),
            // Sheets of the survey
            SizedBox(
              height: 32,
              child: ListView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.only(right: 8),
                children: [
                  for (final group in s.doc.groups)
                    Padding(
                      padding: const EdgeInsets.only(right: 6),
                      child: ChoiceChip(
                        key: Key('sheet-${group.id}'),
                        visualDensity: VisualDensity.compact,
                        showCheckmark: false, // the colour dot says which sheet it is
                        avatar: CircleAvatar(radius: 5, backgroundColor: _hex(group.color)),
                        label: Text(group.name, style: const TextStyle(fontSize: 12)),
                        selected: group.id == g?.id,
                        onSelected: (_) => nav.setActiveGroup(group.id),
                      ),
                    ),
                  ActionChip(
                    key: const Key('sheet-add'),
                    visualDensity: VisualDensity.compact,
                    avatar: const Icon(Icons.add, size: 16),
                    label: const Text('Sheet', style: TextStyle(fontSize: 12)),
                    onPressed: () {
                      HapticFeedback.selectionClick();
                      nav.createGroup();
                    },
                  ),
                ],
              ),
            ),
            const SizedBox(height: 8),
            // Line mode, angle snap and corners
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: Row(
                children: [
                  Expanded(
                    child: _Segmented(
                      options: const [('Curve', Icons.gesture, false), ('Straight', Icons.turn_right, true)],
                      selected: s.straight,
                      onSelected: nav.setStraight,
                    ),
                  ),
                  if (g != null && g.points.length >= 3) ...[
                    const SizedBox(width: 6),
                    PopupMenuButton<PointCorner>(
                      key: const Key('navigator-corners'),
                      tooltip: 'Corners of every point',
                      onSelected: (c) => nav.setGroupCorners(g.id, c),
                      itemBuilder: (_) => const [
                        PopupMenuItem(value: PointCorner.smooth, child: Text('Curve the line through every point')),
                        PopupMenuItem(value: PointCorner.sharp, child: Text('Sharp corner at every point')),
                      ],
                      child: Container(
                        height: 40,
                        padding: const EdgeInsets.symmetric(horizontal: 10),
                        decoration: BoxDecoration(color: L360Colors.sand100, borderRadius: BorderRadius.circular(10)),
                        child: const Row(
                          children: [
                            Icon(Icons.timeline, size: 16, color: L360Colors.sand700),
                            SizedBox(width: 4),
                            Text('Corners', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
                          ],
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
            if (s.straight) ...[
              const SizedBox(height: 6),
              Padding(
                padding: const EdgeInsets.only(right: 8),
                child: Row(
                  children: [
                    const Text('Angle', style: TextStyle(fontSize: 12, color: L360Colors.sand600)),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Container(
                        height: 32,
                        padding: const EdgeInsets.all(2),
                        decoration: BoxDecoration(color: L360Colors.sand100, borderRadius: BorderRadius.circular(9)),
                        child: Row(
                          children: [
                            for (final step in angleSteps)
                              Expanded(
                                child: GestureDetector(
                                  key: Key('angle-$step'),
                                  behavior: HitTestBehavior.opaque,
                                  onTap: () {
                                    HapticFeedback.selectionClick();
                                    nav.setAngleStep(step);
                                  },
                                  child: Container(
                                    alignment: Alignment.center,
                                    decoration: BoxDecoration(
                                      color: s.angleStep == step ? Colors.white : Colors.transparent,
                                      borderRadius: BorderRadius.circular(7),
                                    ),
                                    child: Text(
                                      step == 0 ? 'Free' : '$step°',
                                      style: TextStyle(
                                        fontSize: 12,
                                        fontWeight: s.angleStep == step ? FontWeight.w700 : FontWeight.w500,
                                        color: s.angleStep == step ? L360Colors.ink : L360Colors.sand600,
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _SyncBadge extends StatelessWidget {
  const _SyncBadge({required this.state, required this.signedIn});

  final SurveyNavigatorState state;
  final bool signedIn;

  @override
  Widget build(BuildContext context) {
    final (icon, color, tip) = !signedIn
        ? (Icons.phone_iphone, L360Colors.sand500, 'Saved on this phone. Sign in to save to the cloud.')
        : state.syncing
        ? (Icons.cloud_upload_outlined, L360Colors.gold700, 'Saving…')
        : state.dirty
        ? (Icons.cloud_off_outlined, L360Colors.sand500, 'Saved on this phone; sent to the cloud when online')
        : (Icons.cloud_done_outlined, L360Colors.forest600, 'Saved to the cloud');
    return Tooltip(
      message: tip,
      triggerMode: TooltipTriggerMode.tap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6),
        child: Icon(icon, key: const Key('navigator-sync'), size: 18, color: color),
      ),
    );
  }
}

class _Segmented extends StatelessWidget {
  const _Segmented({required this.options, required this.selected, required this.onSelected});

  final List<(String, IconData, bool)> options;
  final bool selected;
  final ValueChanged<bool> onSelected;

  @override
  // The chosen half is filled edge to edge (no inner inset), so it does not look squashed
  Widget build(BuildContext context) => Container(
    height: 40,
    clipBehavior: Clip.antiAlias,
    decoration: BoxDecoration(color: L360Colors.sand100, borderRadius: BorderRadius.circular(10)),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final (label, icon, value) in options)
          Expanded(
            child: GestureDetector(
              key: Key('mode-${label.toLowerCase()}'),
              behavior: HitTestBehavior.opaque,
              onTap: () {
                HapticFeedback.selectionClick();
                onSelected(value);
              },
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 150),
                color: selected == value ? L360Colors.gold400 : Colors.transparent,
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(icon, size: 15, color: selected == value ? L360Colors.ink : L360Colors.sand600),
                    const SizedBox(width: 4),
                    Text(
                      label,
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: selected == value ? FontWeight.w700 : FontWeight.w500,
                        color: selected == value ? L360Colors.ink : L360Colors.sand600,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
      ],
    ),
  );
}

// --- Points ------------------------------------------------------------------------------

Future<void> showPointsSheet(BuildContext context) => showModalBottomSheet<void>(
  context: context,
  isScrollControlled: true,
  useSafeArea: true,
  builder: (_) => DraggableScrollableSheet(
    expand: false,
    initialChildSize: 0.7,
    maxChildSize: 0.95,
    builder: (context, controller) => _PointsList(controller: controller),
  ),
);

class _PointsList extends ConsumerWidget {
  const _PointsList({required this.controller});

  final ScrollController controller;

  Future<String?> _ask(BuildContext context, String title, String initial) {
    final text = TextEditingController(text: initial);
    return showDialog<String>(
      context: context,
      builder: (context) => AlertDialog.adaptive(
        title: Text(title),
        content: Material(
          color: Colors.transparent,
          child: TextField(controller: text, autofocus: true, textCapitalization: TextCapitalization.sentences),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.pop(context, text.text), child: const Text('Save')),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(navigatorProvider);
    final nav = ref.read(navigatorProvider.notifier);
    final g = s.doc.activeGroup;
    return ListView(
      controller: controller,
      padding: const EdgeInsets.fromLTRB(L360.gutter, 0, L360.gutter, 32),
      children: [
        if (g == null)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 40),
            child: Text(
              lineHint,
              textAlign: TextAlign.center,
              style: TextStyle(color: L360Colors.sand600),
            ),
          )
        else ...[
          Row(
            children: [
              CircleAvatar(radius: 6, backgroundColor: _hex(g.color)),
              const SizedBox(width: 8),
              Expanded(child: Text(g.name, style: Theme.of(context).textTheme.titleLarge)),
              IconButton(
                tooltip: 'Rename sheet',
                icon: const Icon(Icons.edit_outlined),
                onPressed: () async {
                  final name = await _ask(context, 'Sheet name', g.name);
                  if (name != null && name.trim().isNotEmpty) nav.renameGroup(g.id, name.trim());
                },
              ),
              IconButton(
                tooltip: 'Delete sheet',
                icon: const Icon(Icons.delete_outline, color: L360Colors.brick500),
                onPressed: () async {
                  final ok = await _confirm(context, 'Delete "${g.name}"?', 'Its points are removed.');
                  if (ok) nav.deleteGroup(g.id);
                },
              ),
            ],
          ),
          Text(
            '${g.points.length} points · total ${formatDistance(g.totalDistance)}',
            style: const TextStyle(color: L360Colors.sand600),
          ),
          const SizedBox(height: 4),
          const Text(lineHint, style: TextStyle(fontSize: 12, color: L360Colors.sand500)),
          const SizedBox(height: 12),
          for (var i = 0; i < g.points.length; i++) ...[
            _PointCard(
              index: i,
              point: g.points[i],
              color: _hex(g.color),
              onRename: () async {
                final name = await _ask(context, 'Point name', g.points[i].name ?? '');
                if (name != null) nav.renamePoint(g.id, g.points[i].id, name);
              },
              onCorner: () => nav.setCorner(
                g.id,
                g.points[i].id,
                g.points[i].corner == PointCorner.sharp ? PointCorner.smooth : PointCorner.sharp,
              ),
              onRemove: () => nav.removePoint(g.id, g.points[i].id),
            ),
            if (i + 1 < g.points.length) _DataCard(p1: g.points[i], p2: g.points[i + 1]),
          ],
          if (g.points.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: OutlinedButton.icon(
                icon: const Icon(Icons.layers_clear_outlined),
                label: const Text('Clear points'),
                onPressed: () async {
                  final ok = await _confirm(context, 'Clear all points of "${g.name}"?', 'This cannot be undone.');
                  if (ok) nav.clearPoints(g.id);
                },
              ),
            ),
        ],
      ],
    );
  }
}

Future<bool> _confirm(BuildContext context, String title, String body) async =>
    await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog.adaptive(
        title: Text(title),
        content: Text(body),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            style: TextButton.styleFrom(foregroundColor: L360Colors.brick500),
            child: const Text('Delete'),
          ),
        ],
      ),
    ) ??
    false;

class _PointCard extends StatelessWidget {
  const _PointCard({
    required this.index,
    required this.point,
    required this.color,
    required this.onRename,
    required this.onCorner,
    required this.onRemove,
  });

  final int index;
  final SurveyPoint point;
  final Color color;
  final VoidCallback onRename;
  final VoidCallback onCorner;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final p = point;
    const label = TextStyle(fontSize: 10, fontWeight: FontWeight.w700, color: L360Colors.sand500, letterSpacing: 0.5);
    const value = TextStyle(fontSize: 12, fontFeatures: [FontFeature.tabularFigures()]);
    return Card(
      key: Key('point-card-$index'),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 6, 4, 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                CircleAvatar(
                  radius: 11,
                  backgroundColor: color,
                  child: Text(
                    '${index + 1}',
                    style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: Colors.black),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: GestureDetector(
                    onTap: onRename,
                    child: Text(
                      p.name ?? 'Point ${index + 1}',
                      style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700),
                    ),
                  ),
                ),
                IconButton(
                  tooltip: p.corner == PointCorner.sharp
                      ? 'Sharp corner (tap to curve)'
                      : 'Curve (tap for a sharp corner)',
                  visualDensity: VisualDensity.compact,
                  icon: Icon(p.corner == PointCorner.sharp ? Icons.turn_right : Icons.gesture, size: 18),
                  onPressed: onCorner,
                ),
                IconButton(
                  tooltip: 'Copy coordinates',
                  visualDensity: VisualDensity.compact,
                  icon: const Icon(Icons.copy, size: 18),
                  onPressed: () {
                    // Same text as the web's copy button
                    Clipboard.setData(
                      ClipboardData(
                        text:
                            'Lat: ${p.lat.toStringAsFixed(6)} (${toDMS(p.lat, isLat: true)})\n'
                            'Lng: ${p.lng.toStringAsFixed(6)} (${toDMS(p.lng, isLat: false)})\n'
                            'Elev: ${p.elevation.toStringAsFixed(1)} mdpl',
                      ),
                    );
                    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Coordinates copied')));
                  },
                ),
                IconButton(
                  tooltip: 'Remove point',
                  visualDensity: VisualDensity.compact,
                  icon: const Icon(Icons.delete_outline, size: 18, color: L360Colors.brick500),
                  onPressed: onRemove,
                ),
              ],
            ),
            Text('${p.lat.toStringAsFixed(5)}, ${p.lng.toStringAsFixed(5)}', style: value),
            const SizedBox(height: 4),
            Wrap(
              spacing: 16,
              runSpacing: 4,
              children: [
                _Field(
                  label: 'DMS',
                  value: '${toDMS(p.lat, isLat: true)}, ${toDMS(p.lng, isLat: false)}',
                  labelStyle: label,
                  valueStyle: value,
                ),
                _Field(label: 'UTM', value: toUTM(p.lat, p.lng), labelStyle: label, valueStyle: value),
                _Field(
                  label: 'ELEV',
                  value: '${p.elevation.toStringAsFixed(1)} mdpl',
                  labelStyle: label,
                  valueStyle: value,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _Field extends StatelessWidget {
  const _Field({required this.label, required this.value, required this.labelStyle, required this.valueStyle});

  final String label;
  final String value;
  final TextStyle labelStyle;
  final TextStyle valueStyle;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(label, style: labelStyle),
      Text(value, style: valueStyle),
    ],
  );
}

/// Between two points: azimuth, back azimuth, horizontal distance and slope (web's DataCard)
class _DataCard extends StatelessWidget {
  const _DataCard({required this.p1, required this.p2});

  final SurveyPoint p1;
  final SurveyPoint p2;

  @override
  Widget build(BuildContext context) {
    final d = getAzimuthData(p1.geo, p2.geo);
    Widget cell(String label, String value) => Expanded(
      child: Column(
        children: [
          Text(
            label,
            style: const TextStyle(fontSize: 9, fontWeight: FontWeight.w700, color: L360Colors.gold700),
          ),
          Text(
            value,
            style: const TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w700,
              fontFeatures: [FontFeature.tabularFigures()],
            ),
          ),
        ],
      ),
    );
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      padding: const EdgeInsets.symmetric(vertical: 8),
      decoration: BoxDecoration(color: L360Colors.gold50, borderRadius: BorderRadius.circular(10)),
      child: Row(
        children: [
          cell('Azimuth', formatDegrees(d.forwardAzimuth)),
          cell('Back Azimuth', formatDegrees(d.backAzimuth)),
          cell('Horiz Dist', formatDistance(d.horizontalDistance)),
          cell('Slope', '${d.slope.toStringAsFixed(1)}% (${d.slopeDegrees.toStringAsFixed(1)}°)'),
        ],
      ),
    );
  }
}

// --- Saved surveys -----------------------------------------------------------------------

Future<void> showSurveysSheet(BuildContext context, ValueChanged<SurveyDoc> onShowSurvey) => showModalBottomSheet<void>(
  context: context,
  isScrollControlled: true,
  useSafeArea: true,
  builder: (_) => DraggableScrollableSheet(
    expand: false,
    initialChildSize: 0.6,
    maxChildSize: 0.9,
    builder: (context, controller) => _SurveysList(controller: controller, onShowSurvey: onShowSurvey),
  ),
);

class _SurveysList extends ConsumerWidget {
  const _SurveysList({required this.controller, required this.onShowSurvey});

  final ScrollController controller;
  final ValueChanged<SurveyDoc> onShowSurvey;

  String _when(String iso) {
    final t = DateTime.tryParse(iso)?.toLocal();
    if (t == null) return '';
    String p(int n) => n.toString().padLeft(2, '0');
    return '${p(t.day)}/${p(t.month)}/${t.year} ${p(t.hour)}:${p(t.minute)}';
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(navigatorProvider);
    final nav = ref.read(navigatorProvider.notifier);
    final signedIn = ref.watch(authUserIdProvider).value != null;
    final plan = ref.watch(profileProvider).value;
    return ListView(
      controller: controller,
      padding: const EdgeInsets.fromLTRB(L360.gutter, 0, L360.gutter, 32),
      children: [
        Text('Surveys', style: Theme.of(context).textTheme.titleLarge),
        const SizedBox(height: 4),
        if (!signedIn) ...[
          const Text(
            'Your survey is kept on this phone. Sign in to save surveys to the cloud and open them on the web.',
            style: TextStyle(color: L360Colors.sand600),
          ),
          const SizedBox(height: 12),
          FilledButton(
            onPressed: () {
              Navigator.pop(context);
              context.push('/login');
            },
            child: const Text('Sign in'),
          ),
        ] else ...[
          Text(
            plan == null
                ? '${s.saved.length} saved'
                : '${s.saved.length} of ${surveyLimit(plan.isAdmin ? plan.plan : plan.plan)} saved in the cloud',
            style: const TextStyle(color: L360Colors.sand600),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  key: const Key('survey-new'),
                  icon: const Icon(Icons.add),
                  label: const Text('New survey'),
                  onPressed: () async {
                    await nav.saveNow();
                    nav.newSurvey();
                    if (context.mounted) Navigator.pop(context);
                  },
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: FilledButton.icon(
                  key: const Key('survey-save'),
                  icon: const Icon(Icons.cloud_upload_outlined),
                  label: const Text('Save'),
                  onPressed: s.doc.groups.isEmpty ? null : () => nav.saveNow(name: surveySaveName(s.doc.groups)),
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          for (final saved in s.saved)
            Card(
              margin: const EdgeInsets.only(bottom: 8),
              child: ListTile(
                key: Key('survey-${saved.id}'),
                leading: Icon(
                  saved.id == s.currentSurveyId ? Icons.edit_location_alt : Icons.map_outlined,
                  color: saved.id == s.currentSurveyId ? L360Colors.gold700 : L360Colors.forest700,
                ),
                title: Text(saved.name),
                subtitle: Text(saved.id == s.currentSurveyId ? 'Open now' : _when(saved.updatedAt)),
                onTap: () async {
                  final doc = await nav.loadSurvey(saved.id);
                  if (doc != null) onShowSurvey(doc);
                  if (context.mounted) Navigator.pop(context);
                },
                trailing: IconButton(
                  tooltip: 'Delete survey',
                  icon: const Icon(Icons.delete_outline, color: L360Colors.brick500),
                  onPressed: () async {
                    final ok = await _confirm(context, 'Delete "${saved.name}"?', 'It is removed from the cloud.');
                    if (ok) await nav.deleteSurvey(saved.id);
                  },
                ),
              ),
            ),
          if (s.saved.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 24),
              child: Text(
                'No saved surveys yet. Points you add are saved automatically.',
                textAlign: TextAlign.center,
                style: TextStyle(color: L360Colors.sand500),
              ),
            ),
        ],
      ],
    );
  }
}
