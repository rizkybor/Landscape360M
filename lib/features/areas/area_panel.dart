import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers.dart';
import '../../core/theme/app_theme.dart';
import '../../data/marked/marked_area_repository.dart';
import '../../domain/marked/area_contours.dart' show AreaContourMeta;
import '../../domain/marked/marked_areas.dart';
import '../../domain/share/share_location.dart';
import '../marked/marked_sheet.dart' show ShareLinkBox;
import '../tracks/track_recorder_panel.dart' show contactAdminLabel;
import 'area_state.dart';

// Marked Areas above the sheet (MarkedAreaPanel.tsx): the list with focus, edit, share as a
// link and delete; the form for a new or edited area; the bar while drawing a shape; and
// "Exit focus" while the map is darkened outside an area.

Color _hex(String hex) => Color(int.parse('FF${hex.replaceFirst('#', '')}', radix: 16));

class AreaPanel extends ConsumerWidget {
  const AreaPanel({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(areasProvider);
    final rec = ref.read(areasProvider.notifier);
    ref.watch(profileProvider);
    final policy = rec.policy;
    final atLimit = policy.limit != null && s.areas.length >= policy.limit!;
    final maxHeight = MediaQuery.sizeOf(context).height * 0.5;
    return Material(
      key: const Key('area-panel'),
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
                const Icon(Icons.hexagon_outlined, size: 20, color: L360Colors.gold700),
                const SizedBox(width: 8),
                const Expanded(
                  child: Text('Marked Areas', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700)),
                ),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                    color: atLimit ? L360Colors.brick50 : L360Colors.gold50,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Text(
                    policy.limit == null ? '${s.areas.length} · unlimited' : '${s.areas.length} / ${policy.limit}',
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                      color: atLimit ? L360Colors.brick600 : L360Colors.gold700,
                    ),
                  ),
                ),
                IconButton(
                  key: const Key('area-close'),
                  tooltip: 'Close',
                  visualDensity: VisualDensity.compact,
                  icon: const Icon(Icons.close, size: 20),
                  onPressed: () {
                    rec
                      ..closeForm()
                      ..setPanelOpen(false);
                  },
                ),
              ],
            ),
            if (s.error != null)
              Padding(
                padding: const EdgeInsets.only(right: 10, bottom: 4),
                child: Text(s.error!, style: const TextStyle(fontSize: 12, color: L360Colors.brick500)),
              ),
            ConstrainedBox(
              constraints: BoxConstraints(maxHeight: maxHeight),
              child: Padding(
                padding: const EdgeInsets.only(right: 10),
                child: s.form != null ? _AreaFormView(form: s.form!) : _AreaList(state: s, atLimit: atLimit),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _AreaList extends ConsumerWidget {
  const _AreaList({required this.state, required this.atLimit});

  final AreasState state;
  final bool atLimit;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final rec = ref.read(areasProvider.notifier);
    final plan = ref.watch(profileProvider).value?.plan.value ?? 'Free';
    return ListView(
      shrinkWrap: true,
      padding: EdgeInsets.zero,
      children: [
        const SizedBox(height: 4),
        FilledButton.icon(
          key: const Key('area-add'),
          style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(44)),
          onPressed: atLimit ? null : rec.newArea,
          icon: const Icon(Icons.add, size: 18),
          label: const Text('Add area'),
        ),
        if (atLimit)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(
              'Your $plan plan allows ${rec.policy.limit} areas. Delete one or $contactAdminLabel for more.',
              style: const TextStyle(fontSize: 12, color: L360Colors.brick600),
            ),
          ),
        const SizedBox(height: 8),
        if (state.areas.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 14),
            child: Text(
              state.loading ? 'Loading areas…' : 'No areas yet. Press Add area and tap the map to draw one.',
              textAlign: TextAlign.center,
              style: const TextStyle(color: L360Colors.sand500, fontSize: 13),
            ),
          ),
        for (final a in state.areas)
          _AreaTile(area: a, focused: a.id == state.focusId, selected: a.id == state.selectedId),
      ],
    );
  }
}

class _AreaTile extends ConsumerWidget {
  const _AreaTile({required this.area, required this.focused, required this.selected});

  final MarkedArea area;
  final bool focused;
  final bool selected;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final rec = ref.read(areasProvider.notifier);
    final canShare = rec.policy.canShare;
    final contours = ref.watch(areasProvider.select((s) => s.contourMeta[area.id]));
    final contoursShown = ref.watch(areasProvider.select((s) => s.shownContours.containsKey(area.id)));
    return Container(
      key: Key('area-${area.id}'),
      margin: const EdgeInsets.only(bottom: 6),
      padding: const EdgeInsets.fromLTRB(10, 6, 2, 6),
      decoration: BoxDecoration(
        color: selected || focused ? L360Colors.gold50 : L360Colors.sand50,
        borderRadius: BorderRadius.circular(L360.radiusSmall),
        border: Border.all(color: selected || focused ? L360Colors.gold400 : L360Colors.sand200),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Container(
                width: 14,
                height: 14,
                decoration: BoxDecoration(
                  color: _hex(area.color),
                  borderRadius: BorderRadius.circular(4),
                  border: Border.all(color: L360Colors.sand300),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      area.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700),
                    ),
                    Text(
                      '${formatArea(area.areaM2)} · perimeter ${formatLength(area.perimeterM)}',
                      style: const TextStyle(fontSize: 12, color: L360Colors.sand600),
                    ),
                  ],
                ),
              ),
              IconButton(
                key: Key('area-focus-${area.id}'),
                tooltip: focused ? 'Exit focus' : 'Focus',
                visualDensity: VisualDensity.compact,
                icon: Icon(focused ? Icons.visibility_off_outlined : Icons.visibility_outlined, size: 20),
                onPressed: () => rec.focus(focused ? null : area.id),
              ),
              PopupMenuButton<String>(
                key: Key('area-more-${area.id}'),
                tooltip: 'More',
                icon: const Icon(Icons.more_horiz, size: 20),
                onSelected: (v) async {
                  switch (v) {
                    case 'edit':
                      rec.edit(area);
                    case 'share':
                      await showAreaLinkSheet(context, area);
                    case 'delete':
                      final ok = await showDialog<bool>(
                        context: context,
                        builder: (context) => AlertDialog.adaptive(
                          title: Text('Delete "${area.name}"?'),
                          content: const Text('It is deleted permanently. A share link stops working.'),
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
                        await rec.delete(area.id);
                      } on Object catch (e) {
                        if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
                      }
                  }
                },
                itemBuilder: (_) => [
                  const PopupMenuItem(value: 'edit', child: Text('Edit')),
                  if (canShare) const PopupMenuItem(value: 'share', child: Text('Share as a link')),
                  const PopupMenuItem(
                    value: 'delete',
                    child: Text('Delete', style: TextStyle(color: L360Colors.brick500)),
                  ),
                ],
              ),
            ],
          ),
          if (contours != null) _ContourRow(meta: contours, shown: contoursShown, areaId: area.id),
        ],
      ),
    );
  }
}

/// Contours uploaded to the area on the website: what they are, and show / hide on the map
class _ContourRow extends ConsumerWidget {
  const _ContourRow({required this.meta, required this.shown, required this.areaId});

  final AreaContourMeta meta;
  final bool shown;
  final String areaId;

  String _m(double v) => '${v.round()} m';

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final rec = ref.read(areasProvider.notifier);
    final details = [
      '${meta.lineCount} lines',
      if (meta.minElevation != null && meta.maxElevation != null) '${_m(meta.minElevation!)}–${_m(meta.maxElevation!)}',
      if (meta.intervalM != null) 'every ${formatInterval(meta.intervalM!)} m',
    ].join(' · ');
    return Padding(
      padding: const EdgeInsets.only(left: 24, top: 2),
      child: Row(
        children: [
          const Icon(Icons.terrain_outlined, size: 16, color: Color(0xFF8A5A2B)),
          const SizedBox(width: 6),
          Expanded(
            child: Text.rich(
              TextSpan(
                children: [
                  const TextSpan(
                    text: 'Contours ',
                    style: TextStyle(fontWeight: FontWeight.w700, color: L360Colors.ink),
                  ),
                  TextSpan(text: details),
                ],
              ),
              maxLines: 2,
              style: const TextStyle(fontSize: 12, color: L360Colors.sand600),
            ),
          ),
          IconButton(
            key: Key('area-contours-$areaId'),
            tooltip: shown ? 'Hide contours on map' : 'Show contours on map',
            visualDensity: VisualDensity.compact,
            icon: Icon(shown ? Icons.layers : Icons.layers_outlined, size: 20, color: const Color(0xFF8A5A2B)),
            onPressed: () async {
              if (shown) return rec.hideContours(areaId);
              try {
                await rec.showContours(areaId);
              } on Object catch (e) {
                if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
              }
            },
          ),
        ],
      ),
    );
  }
}

/// 12.5 stays 12.5, 25.0 shows as 25
String formatInterval(double v) => v == v.roundToDouble() ? '${v.round()}' : '$v';

class _AreaFormView extends ConsumerStatefulWidget {
  const _AreaFormView({required this.form});

  final AreaForm form;

  @override
  ConsumerState<_AreaFormView> createState() => _AreaFormViewState();
}

class _AreaFormViewState extends ConsumerState<_AreaFormView> {
  late final _name = TextEditingController(text: widget.form.name);
  late final _notes = TextEditingController(text: widget.form.notes);
  String? _error;
  bool _saving = false;

  @override
  void dispose() {
    _name.dispose();
    _notes.dispose();
    super.dispose();
  }

  AreasController get _rec => ref.read(areasProvider.notifier);
  AreaForm get _current => ref.read(areasProvider).form!.copyWith(name: _name.text, notes: _notes.text);

  Future<void> _save() async {
    _rec.updateForm(_current);
    setState(() {
      _saving = true;
      _error = null;
    });
    final problem = await _rec.save();
    if (!mounted) return;
    setState(() {
      _saving = false;
      _error = problem;
    });
  }

  @override
  Widget build(BuildContext context) {
    final f = widget.form;
    return ListView(
      shrinkWrap: true,
      padding: EdgeInsets.zero,
      children: [
        Row(
          children: [
            Expanded(
              child: Text.rich(
                TextSpan(
                  children: [
                    TextSpan(text: '${f.ring.length} points · '),
                    TextSpan(
                      text: formatArea(ringArea(f.ring)),
                      style: const TextStyle(fontWeight: FontWeight.w700),
                    ),
                    TextSpan(text: ' · perimeter ${formatLength(ringPerimeter(f.ring))}'),
                  ],
                ),
                style: const TextStyle(fontSize: 12, color: L360Colors.sand700),
              ),
            ),
            TextButton.icon(
              key: const Key('area-redraw'),
              style: TextButton.styleFrom(minimumSize: const Size(0, 36)),
              onPressed: () {
                _rec
                  ..updateForm(_current)
                  ..startDrawing(from: f.ring);
              },
              icon: const Icon(Icons.edit_outlined, size: 16),
              label: const Text('Redraw'),
            ),
          ],
        ),
        const SizedBox(height: 6),
        TextField(
          key: const Key('area-name'),
          controller: _name,
          maxLength: 120,
          textCapitalization: TextCapitalization.sentences,
          decoration: const InputDecoration(
            isDense: true,
            counterText: '',
            labelText: 'Name',
            hintText: 'e.g. Camp ground Surya Kencana',
          ),
        ),
        const SizedBox(height: 10),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final c in areaColors)
              GestureDetector(
                key: Key('area-color-$c'),
                onTap: () {
                  HapticFeedback.selectionClick();
                  _rec.updateForm(_current.copyWith(color: c));
                },
                child: Container(
                  width: 30,
                  height: 30,
                  decoration: BoxDecoration(
                    color: _hex(c),
                    shape: BoxShape.circle,
                    border: Border.all(
                      color: f.color == c ? L360Colors.ink : L360Colors.sand300,
                      width: f.color == c ? 3 : 1,
                    ),
                  ),
                ),
              ),
          ],
        ),
        const SizedBox(height: 10),
        TextField(
          controller: _notes,
          maxLength: 2000,
          minLines: 2,
          maxLines: 4,
          decoration: const InputDecoration(
            isDense: true,
            counterText: '',
            labelText: 'Notes',
            hintText: 'Access, rules, water, hazards…',
          ),
        ),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(
              _error!,
              key: const Key('area-error'),
              style: const TextStyle(color: L360Colors.brick500),
            ),
          ),
        const SizedBox(height: 10),
        Row(
          children: [
            Expanded(
              child: OutlinedButton(
                style: OutlinedButton.styleFrom(minimumSize: const Size(0, 44)),
                onPressed: _rec.closeForm,
                child: const Text('Cancel'),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: FilledButton(
                key: const Key('area-save'),
                style: FilledButton.styleFrom(minimumSize: const Size(0, 44)),
                onPressed: _saving ? null : _save,
                child: Text(f.editingId == null ? 'Save area' : 'Save changes'),
              ),
            ),
          ],
        ),
      ],
    );
  }
}

/// While drawing: how far the shape is, Undo, Cancel and Done
class AreaDrawingBar extends ConsumerWidget {
  const AreaDrawingBar({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final draft = ref.watch(areasProvider.select((s) => s.draft));
    final rec = ref.read(areasProvider.notifier);
    return Material(
      key: const Key('area-drawing'),
      color: Colors.white,
      elevation: 6,
      shadowColor: const Color(0x40000000),
      borderRadius: BorderRadius.circular(L360.radius),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              draft.length < 3
                  ? 'Tap the map to add the corners of the area'
                  : '${draft.length} points · ${formatArea(ringArea(draft))}',
              style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    key: const Key('area-undo'),
                    style: OutlinedButton.styleFrom(minimumSize: const Size(0, 42)),
                    onPressed: draft.isEmpty ? null : rec.undoPoint,
                    icon: const Icon(Icons.undo, size: 18),
                    label: const Text('Undo'),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: OutlinedButton(
                    key: const Key('area-cancel'),
                    style: OutlinedButton.styleFrom(minimumSize: const Size(0, 42)),
                    onPressed: rec.cancelDrawing,
                    child: const Text('Cancel'),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: FilledButton.icon(
                    key: const Key('area-done'),
                    style: FilledButton.styleFrom(minimumSize: const Size(0, 42)),
                    onPressed: draft.length < 3 ? null : rec.finishDrawing,
                    icon: const Icon(Icons.check, size: 18),
                    label: const Text('Done'),
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

/// "Exit focus" while the map is darkened outside an area
class AreaFocusPill extends ConsumerWidget {
  const AreaFocusPill({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final a = ref.watch(areasProvider.select((s) => s.focused));
    if (a == null) return const SizedBox.shrink();
    return Center(
      child: Material(
        key: const Key('area-focus-pill'),
        color: Colors.white,
        elevation: 4,
        shape: const StadiumBorder(),
        child: InkWell(
          customBorder: const StadiumBorder(),
          onTap: () => ref.read(areasProvider.notifier).focus(null),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 10,
                  height: 10,
                  decoration: BoxDecoration(color: _hex(a.color), borderRadius: BorderRadius.circular(3)),
                ),
                const SizedBox(width: 8),
                Flexible(
                  child: Text(
                    a.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 13),
                  ),
                ),
                const SizedBox(width: 10),
                const Icon(Icons.close, size: 16),
                const Text(' Exit focus', style: TextStyle(fontSize: 13)),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

Future<void> showAreaLinkSheet(BuildContext context, MarkedArea area) => showModalBottomSheet<void>(
  context: context,
  useSafeArea: true,
  isScrollControlled: true,
  builder: (context) => Consumer(
    builder: (context, ref, _) {
      final cloud = ref.read(areaBackendProvider);
      return Padding(
        padding: const EdgeInsets.fromLTRB(L360.gutter, 0, L360.gutter, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('Share area', style: Theme.of(context).textTheme.titleLarge),
            Text(area.name, style: const TextStyle(color: L360Colors.sand600)),
            const SizedBox(height: 12),
            ShareLinkBox(
              what: 'this area',
              getToken: () => cloud.link(area.id),
              createToken: () => cloud.createLink(area.id),
              revoke: () => cloud.revokeLink(area.id),
              urlFor: areaLinkUrl,
              messageFor: (url) => buildAreaShareText(
                name: area.name,
                size: formatArea(area.areaM2),
                perimeter: formatLength(area.perimeterM),
                url: url,
              ),
            ),
          ],
        ),
      );
    },
  ),
);
