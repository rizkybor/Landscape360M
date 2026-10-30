import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/providers.dart';
import '../../core/theme/app_theme.dart';
import '../../domain/classic/classic_nav.dart';
import '../../domain/classic/classic_solve.dart';
import '../../domain/classic/field_work.dart';
import '../../domain/geo/spherical.dart' show LngLat;
import '../../domain/share/share_location.dart';
import '../../domain/survey/survey_utils.dart' show toDMS;
import 'classic_state.dart';
import 'compass_dial.dart';

// Classic (ClassicPanel.tsx): practise resection and intersection with a map and compass,
// every coordinate typed in degrees, minutes and seconds and every bearing in compass degrees.
// Each sighting goes position -> azimuth -> back azimuth, then the next one opens.

/// How tall the panel's scrolling body may be: about a third of the screen, so most of the
/// map (and the lines) stays in view while working
double classicBodyHeight(double screen) => (screen * 0.32).clamp(200, 360).toDouble();

String _cap(String t) => t.isEmpty ? t : '${t[0].toUpperCase()}${t.substring(1)}';
String _ll(LngLat p) => '${toDMS(p.$2, isLat: true)} · ${toDMS(p.$1, isLat: false)}';

const _small = TextStyle(fontSize: 11, color: L360Colors.sand600, height: 1.35);
const _tiny = TextStyle(fontSize: 10.5, color: L360Colors.sand500, height: 1.35);

class ClassicPanel extends ConsumerStatefulWidget {
  const ClassicPanel({super.key});

  @override
  ConsumerState<ClassicPanel> createState() => _ClassicPanelState();
}

class _ClassicPanelState extends ConsumerState<ClassicPanel> {
  bool _showSteps = false;
  bool _showDeclination = false;
  bool _showPoints = false;
  bool _shareOpen = false;
  bool _originHidden = false;
  bool _confirmDelete = false;
  bool _copied = false;
  final _hidden = <int>{};
  final _rename = TextEditingController();
  bool _renaming = false;

  ClassicController get _ctl => ref.read(classicProvider.notifier);

  @override
  void dispose() {
    _rename.dispose();
    super.dispose();
  }

  void _resetLocal() => setState(() {
    _renaming = false;
    _confirmDelete = false;
    _shareOpen = false;
    _hidden.clear();
  });

  @override
  Widget build(BuildContext context) {
    final s = ref.watch(classicProvider);
    final sol = s.solution;
    final viewing = s.viewing;

    if (s.picking != null) return _pickingBar(s, sol);

    final maxBody = classicBodyHeight(MediaQuery.sizeOf(context).height);
    final lowered = s.minimized;
    void lower(bool v) => _ctl.setMinimized(v);
    final fix = sol.fix;
    final name = viewing?.name ?? s.fieldWork.name;
    final mode = viewing?.mode ?? s.mode;
    return Material(
      key: const Key('classic-panel'),
      color: Colors.white,
      elevation: 6,
      shadowColor: const Color(0x40000000),
      borderRadius: BorderRadius.circular(L360.radius),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Header: tap or drag down to lower it to one line, so the map can be seen
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => lower(!lowered),
            onVerticalDragEnd: (d) {
              final v = d.primaryVelocity ?? 0;
              if (v > 200 && !lowered) lower(true);
              if (v < -200 && lowered) lower(false);
            },
            child: Padding(
              padding: const EdgeInsets.fromLTRB(14, 8, 4, 6),
              child: Row(
                children: [
                  const Icon(Icons.architecture, size: 20, color: L360Colors.gold700),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            const Flexible(
                              child: Text(
                                'Classic',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700),
                              ),
                            ),
                            if (!lowered) ...[
                              const SizedBox(width: 6),
                              Flexible(child: _Badge(viewing != null ? 'Shared · view only' : 'Practice')),
                            ],
                          ],
                        ),
                        if (lowered)
                          Text(
                            '$name · ${fix != null ? _ll(fix.point) : '${_cap(mode.name)} · tap to continue'}',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: _tiny,
                          ),
                      ],
                    ),
                  ),
                  IconButton(
                    key: const Key('classic-minimize'),
                    tooltip: lowered ? 'Expand' : 'Minimize',
                    visualDensity: VisualDensity.compact,
                    icon: Icon(lowered ? Icons.expand_less : Icons.expand_more, size: 22),
                    onPressed: () => lower(!lowered),
                  ),
                  if (viewing == null)
                    IconButton(
                      key: const Key('classic-reset'),
                      tooltip: 'Start over',
                      visualDensity: VisualDensity.compact,
                      icon: const Icon(Icons.restart_alt, size: 20),
                      onPressed: () {
                        _ctl.resetExercise();
                        setState(_hidden.clear);
                      },
                    ),
                  IconButton(
                    key: const Key('classic-close'),
                    tooltip: 'Close',
                    visualDensity: VisualDensity.compact,
                    icon: const Icon(Icons.close, size: 20),
                    onPressed: () {
                      if (viewing != null) _ctl.closeViewing();
                      _ctl.setPanelOpen(false);
                    },
                  ),
                ],
              ),
            ),
          ),
          if (!lowered) ...[
            const Divider(height: 1),
            ConstrainedBox(
              constraints: BoxConstraints(maxHeight: maxBody),
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
                child: viewing != null ? _viewBody(viewing, sol) : _body(s, sol),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _pickingBar(ClassicState s, ClassicSolution sol) {
    final p = s.picking!;
    final what = p == pickOrigin ? 'your position' : sol.sightings[p].label;
    return Center(
      child: Material(
        key: const Key('classic-picking'),
        color: Colors.white,
        elevation: 6,
        shape: const StadiumBorder(side: BorderSide(color: L360Colors.gold400)),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 6, 4),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.my_location, size: 16, color: L360Colors.gold700),
              const SizedBox(width: 8),
              Flexible(
                child: Text(
                  'Tap the map to place $what',
                  style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700),
                ),
              ),
              TextButton(onPressed: _ctl.stopPicking, child: const Text('Cancel')),
            ],
          ),
        ),
      ),
    );
  }

  // --- A shared Field Work, read only

  Widget _viewBody(ViewedFieldWork v, ClassicSolution sol) {
    final resection = v.mode == ClassicMode.resection;
    final updated = MaterialLocalizations.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _Box(
          color: L360Colors.gold50,
          border: L360Colors.gold100,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'SHARED FIELD WORK · VIEW ONLY',
                style: TextStyle(
                  fontSize: 9.5,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 0.8,
                  color: L360Colors.gold700,
                ),
              ),
              const SizedBox(height: 2),
              Text(v.name, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
              Text(
                '${_cap(v.mode.name)} · shared by ${v.ownerName ?? 'a Landscape 360 user'} · updated '
                '${updated.formatMediumDate(v.updatedAt)} ${updated.formatTimeOfDay(TimeOfDay.fromDateTime(v.updatedAt))}',
                style: _tiny,
              ),
            ],
          ),
        ),
        const SizedBox(height: 8),
        if (resection && sol.origin != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Text.rich(
              TextSpan(
                children: [
                  const TextSpan(
                    text: 'Position (estimate): ',
                    style: TextStyle(fontWeight: FontWeight.w700),
                  ),
                  TextSpan(text: _ll(sol.origin!)),
                ],
              ),
              style: const TextStyle(fontSize: 12),
            ),
          ),
        for (final sg in sol.sightings) _summaryRow(sg, showPoint: !resection),
        if (!resection && sol.fix != null) ...[const SizedBox(height: 4), _fixBox(sol, copy: false)],
        for (final h in sol.review) _HintLine(h),
        _pointsHint(sol),
        const SizedBox(height: 8),
        OutlinedButton(
          key: const Key('classic-close-viewing'),
          onPressed: _ctl.closeViewing,
          child: const Text('Close and open my own Classic'),
        ),
      ],
    );
  }

  // --- My own Field Work

  Widget _body(ClassicState s, ClassicSolution sol) {
    final resection = s.mode == ClassicMode.resection;
    final allComplete = sol.sightings.every((x) => x.complete);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _modeTabs(s),
        const SizedBox(height: 8),
        _fieldWorks(s),
        const SizedBox(height: 8),
        _howItWorks(resection),
        const SizedBox(height: 8),
        if (resection) ...[_originCard(s, sol), const SizedBox(height: 8)],
        _declination(s, sol),
        const SizedBox(height: 8),
        for (final (i, sg) in sol.sightings.indexed) ...[_sightingCard(s, sg, i), const SizedBox(height: 8)],
        if (s.data.sightings.length < maxSightings)
          OutlinedButton.icon(
            key: const Key('classic-add-sighting'),
            onPressed: allComplete ? _ctl.addSighting : null,
            icon: const Icon(Icons.add, size: 18),
            label: Text('Add ${resection ? 'point' : 'position'} ${String.fromCharCode(65 + s.data.sightings.length)}'),
          ),
        const SizedBox(height: 8),
        resection ? _resectionResult(s, sol, allComplete) : _intersectionResult(s, sol),
      ],
    );
  }

  Widget _modeTabs(ClassicState s) => Container(
    padding: const EdgeInsets.all(4),
    decoration: BoxDecoration(color: L360Colors.sand100, borderRadius: BorderRadius.circular(L360.radiusSmall)),
    child: Row(
      children: [
        for (final m in ClassicMode.values)
          Expanded(
            child: GestureDetector(
              key: Key('classic-mode-${m.name}'),
              onTap: () {
                _ctl.setMode(m);
                _resetLocal();
              },
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 180),
                padding: const EdgeInsets.symmetric(vertical: 6),
                decoration: BoxDecoration(
                  color: s.mode == m ? Colors.white : Colors.transparent,
                  borderRadius: BorderRadius.circular(8),
                  boxShadow: s.mode == m ? const [BoxShadow(color: Color(0x1A000000), blurRadius: 4)] : null,
                ),
                child: Column(
                  children: [
                    Text(_cap(m.name), style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700)),
                    Text(
                      m == ClassicMode.resection ? 'Where am I on the map?' : 'Where is the object I see?',
                      style: _tiny,
                      textAlign: TextAlign.center,
                    ),
                  ],
                ),
              ),
            ),
          ),
      ],
    ),
  );

  Widget _fieldWorks(ClassicState s) {
    final limit = _ctl.limit;
    final canAdd = _ctl.canAddFieldWork;
    final fw = s.fieldWork;
    final count = s.modeFieldWorks.length;
    final signedIn = ref.watch(authUserIdProvider).value != null;
    final plan = ref.watch(profileProvider).value?.plan.value ?? 'Free';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(
            children: [
              for (final f in s.modeFieldWorks)
                Padding(
                  padding: const EdgeInsets.only(right: 6),
                  child: ChoiceChip(
                    key: Key('classic-fw-${f.id}'),
                    label: Text(f.name),
                    selected: f.id == fw.id,
                    showCheckmark: false,
                    selectedColor: L360Colors.forest800,
                    labelStyle: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                      color: f.id == fw.id ? Colors.white : L360Colors.sand700,
                    ),
                    visualDensity: VisualDensity.compact,
                    onSelected: (_) {
                      _ctl.selectFieldWork(f.id);
                      _resetLocal();
                    },
                  ),
                ),
              ActionChip(
                key: const Key('classic-fw-new'),
                avatar: Icon(canAdd ? Icons.add : Icons.lock_outline, size: 16),
                label: const Text('New', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700)),
                visualDensity: VisualDensity.compact,
                onPressed: canAdd
                    ? () {
                        _ctl.addFieldWork();
                        _resetLocal();
                      }
                    : null,
              ),
            ],
          ),
        ),
        const SizedBox(height: 4),
        if (_renaming)
          Row(
            children: [
              Expanded(
                child: TextField(
                  key: const Key('classic-rename-field'),
                  controller: _rename,
                  autofocus: true,
                  maxLength: 40,
                  decoration: const InputDecoration(isDense: true, counterText: '', labelText: 'Field Work name'),
                  onSubmitted: (_) => _saveName(fw.id),
                ),
              ),
              const SizedBox(width: 6),
              FilledButton(
                key: const Key('classic-rename-save'),
                style: FilledButton.styleFrom(minimumSize: const Size(0, 40)),
                onPressed: () => _saveName(fw.id),
                child: const Text('Save'),
              ),
              TextButton(onPressed: () => setState(() => _renaming = false), child: const Text('Cancel')),
            ],
          )
        else
          Row(
            children: [
              Expanded(
                child: Text.rich(
                  TextSpan(
                    children: [
                      TextSpan(
                        text: fw.name,
                        style: const TextStyle(fontWeight: FontWeight.w700, color: L360Colors.ink),
                      ),
                      TextSpan(
                        text:
                            ' · $count${limit == null ? '' : '/$limit'} Field Work${count == 1 && limit == 1 ? '' : 's'} '
                            'in ${_cap(s.mode.name)}',
                      ),
                    ],
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: _small,
                ),
              ),
              IconButton(
                key: const Key('classic-share'),
                tooltip: fw.shareToken != null ? 'Shared: link' : 'Share',
                visualDensity: VisualDensity.compact,
                icon: Icon(
                  Icons.share_outlined,
                  size: 18,
                  color: fw.shareToken != null ? L360Colors.forest600 : L360Colors.sand600,
                ),
                onPressed: () => setState(() => _shareOpen = !_shareOpen),
              ),
              IconButton(
                key: const Key('classic-rename'),
                tooltip: 'Rename',
                visualDensity: VisualDensity.compact,
                icon: const Icon(Icons.edit_outlined, size: 18, color: L360Colors.sand600),
                onPressed: () => setState(() {
                  _rename.text = fw.name;
                  _renaming = true;
                }),
              ),
              if (_confirmDelete) ...[
                Text(
                  count > 1 ? 'Delete?' : 'Clear it?',
                  style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: L360Colors.brick500),
                ),
                TextButton(
                  key: const Key('classic-delete-yes'),
                  style: TextButton.styleFrom(foregroundColor: L360Colors.brick500),
                  onPressed: () async {
                    await _ctl.deleteFieldWork(fw.id);
                    _resetLocal();
                  },
                  child: const Text('Yes'),
                ),
                TextButton(onPressed: () => setState(() => _confirmDelete = false), child: const Text('No')),
              ] else
                IconButton(
                  key: const Key('classic-delete'),
                  tooltip: count > 1 ? 'Delete' : 'Clear',
                  visualDensity: VisualDensity.compact,
                  icon: const Icon(Icons.delete_outline, size: 18, color: L360Colors.brick500),
                  onPressed: () => setState(() => _confirmDelete = true),
                ),
            ],
          ),
        if (!canAdd)
          Text(
            limit == 1
                ? 'Pro (5) and Enterprise (10) accounts can keep several Field Works in each mode; admin has no limit.'
                : 'Your $plan plan allows $limit Field Works in each mode. Delete one to add another.',
            style: _tiny,
          ),
        if (_shareOpen) _shareBox(s, fw, signedIn),
      ],
    );
  }

  void _saveName(String id) {
    _ctl.renameFieldWork(id, _rename.text);
    setState(() => _renaming = false);
  }

  Widget _shareBox(ClassicState s, FieldWork fw, bool signedIn) {
    final token = fw.shareToken;
    final url = token == null ? null : classicLinkUrl(token);
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: _Box(
        color: L360Colors.gold50,
        border: L360Colors.gold100,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text(
              'Anyone with the link can look at this Field Work, with or without an account. They cannot change it. '
              'The link always shows your latest version.',
              style: _small,
            ),
            const SizedBox(height: 8),
            if (!signedIn)
              const Text(
                'Sign in to share this Field Work.',
                style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700),
              )
            else if (url == null)
              FilledButton.icon(
                key: const Key('classic-share-create'),
                onPressed: s.shareStatus == ShareStatus.saving ? null : _ctl.startSharing,
                icon: const Icon(Icons.add_link, size: 18),
                label: Text(s.shareStatus == ShareStatus.saving ? 'Creating link…' : 'Create link'),
              )
            else ...[
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(8)),
                child: SelectableText(url, key: const Key('classic-share-url'), style: const TextStyle(fontSize: 12)),
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  OutlinedButton.icon(
                    style: OutlinedButton.styleFrom(minimumSize: const Size(0, 40)),
                    onPressed: () async {
                      await Clipboard.setData(ClipboardData(text: url));
                      setState(() => _copied = true);
                      Future<void>.delayed(const Duration(milliseconds: 1500), () {
                        if (mounted) setState(() => _copied = false);
                      });
                    },
                    icon: Icon(_copied ? Icons.check : Icons.copy, size: 16),
                    label: Text(_copied ? 'Copied' : 'Copy link'),
                  ),
                  FilledButton.icon(
                    style: FilledButton.styleFrom(
                      backgroundColor: const Color(0xFF25D366),
                      minimumSize: const Size(0, 40),
                    ),
                    onPressed: () => launchUrl(
                      Uri.parse(whatsappShareUrl(buildClassicShareText(name: fw.name, mode: s.mode.name, url: url))),
                      mode: LaunchMode.externalApplication,
                    ),
                    icon: const Icon(Icons.chat, size: 18),
                    label: const Text('WhatsApp'),
                  ),
                  TextButton(
                    key: const Key('classic-share-stop'),
                    style: TextButton.styleFrom(foregroundColor: L360Colors.brick500, minimumSize: const Size(0, 40)),
                    onPressed: _ctl.stopSharing,
                    child: const Text('Stop sharing'),
                  ),
                ],
              ),
            ],
            if (s.shareStatus != null)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(
                  switch (s.shareStatus!) {
                    ShareStatus.saving => 'Saving…',
                    ShareStatus.saved => 'Saved: the link shows this version.',
                    ShareStatus.error => s.shareError ?? 'Could not save the link.',
                  },
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                    color: s.shareStatus == ShareStatus.error ? L360Colors.brick500 : L360Colors.forest700,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _howItWorks(bool resection) {
    final steps = resection
        ? const [
            'Find your position on the map, once (pick it or type degrees, minutes and seconds).',
            'Sight point A with the compass and note the azimuth (e.g. 60°).',
            'Work out the back azimuth: under 180° add 180°, over 180° subtract 180° (60° + 180° = 240°).',
            'Both are drawn from your position: the azimuth toward point A, the back azimuth the opposite way.',
            'Repeat steps 2–4 for point B (and C, D… if you like): only the azimuth and back azimuth.',
          ]
        : const [
            'Make sure your position (position A) is known exactly on the map.',
            'Sight the object from position A with the compass and note the azimuth.',
            'Work out the back azimuth: under 180° add 180°, over 180° subtract 180°.',
            'Both are drawn from position A: the azimuth toward the object, the back azimuth the opposite way.',
            'Move to another position (position B), far enough away but with the object still in sight, and find it '
                'exactly on the map.',
            'Sight the object again from position B, note the azimuth and work out its back azimuth.',
            'Where the azimuth lines from A and B cross (X) is the object.',
          ];
    return _Box(
      color: L360Colors.sand50,
      border: L360Colors.sand200,
      padding: EdgeInsets.zero,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          InkWell(
            key: const Key('classic-how'),
            onTap: () => setState(() => _showSteps = !_showSteps),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              child: Row(
                children: [
                  const Expanded(
                    child: Text('How it works', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700)),
                  ),
                  Icon(_showSteps ? Icons.expand_less : Icons.expand_more, size: 20),
                ],
              ),
            ),
          ),
          if (_showSteps)
            Padding(
              padding: const EdgeInsets.fromLTRB(10, 0, 10, 10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    resection
                        ? 'Set your position on the map once, then sight each point with the compass. Its azimuth and '
                              'back azimuth are drawn as lines from where you stand.'
                        : 'Find where an object you see is on the map, by sighting it from two positions you know.',
                    style: _small,
                  ),
                  const SizedBox(height: 6),
                  for (final (i, step) in steps.indexed)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 3),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          SizedBox(
                            width: 18,
                            child: Text(
                              '${i + 1}.',
                              style: const TextStyle(
                                fontSize: 11,
                                fontWeight: FontWeight.w700,
                                color: L360Colors.gold700,
                              ),
                            ),
                          ),
                          Expanded(child: Text(step, style: _small)),
                        ],
                      ),
                    ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget _originCard(ClassicState s, ClassicSolution sol) {
    final origin = sol.origin;
    return _Box(
      key: const Key('classic-origin'),
      color: origin != null ? L360Colors.forest50 : Colors.white,
      border: origin != null ? L360Colors.forest200 : L360Colors.sand200,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _StepDot(done: origin != null, icon: Icons.place),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text.rich(
                      TextSpan(
                        children: [
                          TextSpan(text: 'Your position on the map '),
                          TextSpan(
                            text: '(estimate)',
                            style: TextStyle(fontWeight: FontWeight.w400, color: L360Colors.sand500),
                          ),
                        ],
                      ),
                      style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700),
                    ),
                    Text(
                      _originHidden
                          ? (origin == null ? 'Not set yet' : _ll(origin))
                          : 'Set once: every point\'s azimuth and back azimuth start here. It is only an estimate of '
                                'where you stand (from the map or GPS), so the lines are only as accurate as this point.',
                      style: _tiny,
                    ),
                  ],
                ),
              ),
              _HideButton(hidden: _originHidden, onTap: () => setState(() => _originHidden = !_originHidden)),
            ],
          ),
          if (!_originHidden) ...[
            const SizedBox(height: 6),
            _PointFields(
              keyPrefix: 'classic-origin',
              value: s.data.origin,
              onChanged: _ctl.setOrigin,
              onPick: () => _ctl.startPicking(pickOrigin),
              onClear: _ctl.clearOrigin,
              error: sol.originError,
            ),
          ],
        ],
      ),
    );
  }

  Widget _declination(ClassicState s, ClassicSolution sol) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      GestureDetector(
        key: const Key('classic-declination-toggle'),
        onTap: () => setState(() => _showDeclination = !_showDeclination),
        child: Text(
          'Magnetic declination: ${sol.declination.value == null ? '?' : formatNumber(sol.declination.value!)}°',
          style: const TextStyle(fontSize: 11.5, fontWeight: FontWeight.w700, color: L360Colors.gold700),
        ),
      ),
      if (_showDeclination) ...[
        const SizedBox(height: 6),
        Row(
          children: [
            const Text('Declination (east +, west −)', style: _small),
            const SizedBox(width: 8),
            SizedBox(
              width: 64,
              child: _SyncedField(
                key: const Key('classic-declination'),
                value: s.declination,
                onChanged: _ctl.setDeclination,
                signed: true,
              ),
            ),
            const Text('°'),
          ],
        ),
        const SizedBox(height: 4),
        const Text(
          'A compass points to magnetic north. True bearing = compass reading + declination. Across Indonesia it is '
          'within about 1°, so 0 is fine for practice; leave it at 0 if you read bearings off the map.',
          style: _tiny,
        ),
        if (sol.declination.error != null) _HintLine(Check(Verdict.off, sol.declination.error!)),
      ],
    ],
  );

  Widget _sightingCard(ClassicState s, SightingState sg, int i) {
    final raw = s.data.sightings[i];
    final resection = s.mode == ClassicMode.resection;
    final title = _cap(sg.label);
    final hidden = _hidden.contains(i);
    final azLabel = resection ? 'From you to ${sg.label}' : 'From ${sg.label} to the object';
    final backLabel = resection ? 'From ${sg.label} back to you' : 'From the object back to ${sg.label}';
    return IgnorePointer(
      ignoring: !sg.open,
      child: Opacity(
        opacity: sg.open ? 1 : 0.5,
        child: _Box(
          key: Key('classic-sighting-$i'),
          color: sg.complete ? L360Colors.forest50 : Colors.white,
          border: sg.complete ? L360Colors.forest200 : L360Colors.sand200,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _StepDot(done: sg.complete, letter: String.fromCharCode(65 + i)),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(title, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700)),
                        Text(
                          resection
                              ? 'Sight ${sg.label} with the compass from your position, then work out its back azimuth'
                              : i == 0
                              ? 'Where you stand, known exactly on the map'
                              : 'Another place, far enough away, with the same object still in sight',
                          style: _tiny,
                        ),
                      ],
                    ),
                  ),
                  _HideButton(hidden: hidden, onTap: () => setState(() => hidden ? _hidden.remove(i) : _hidden.add(i))),
                  if (s.data.sightings.length > minSightings)
                    IconButton(
                      key: Key('classic-remove-$i'),
                      tooltip: 'Remove ${sg.label}',
                      visualDensity: VisualDensity.compact,
                      icon: const Icon(Icons.delete_outline, size: 18, color: L360Colors.brick500),
                      onPressed: () {
                        _ctl.removeSighting(i);
                        setState(_hidden.clear);
                      },
                    ),
                ],
              ),
              if (hidden)
                Padding(
                  padding: const EdgeInsets.only(top: 4, left: 32),
                  child: Text.rich(
                    TextSpan(
                      children: [
                        if (!resection)
                          TextSpan(text: sg.point != null ? '${_ll(sg.point!)} · ' : 'No position yet · '),
                        TextSpan(text: 'Az ${sg.azimuth.value == null ? '—' : _bearing(sg.azimuth.value!)} · Back '),
                        TextSpan(text: sg.complete && sg.back.value != null ? _bearing(sg.back.value!) : '—'),
                      ],
                    ),
                    style: _small,
                  ),
                )
              else ...[
                if (!resection) ...[
                  const SizedBox(height: 8),
                  _SubStep(
                    n: '1',
                    title: 'Find ${sg.label} on the map',
                    done: sg.point != null,
                    child: _PointFields(
                      keyPrefix: 'classic-point-$i',
                      value: raw.point,
                      onChanged: (p) => _ctl.setSightingPoint(i, p),
                      onPick: () => _ctl.startPicking(i),
                      onClear: () =>
                          _ctl.setSightingPoint(i, raw.point.copyWith(lat: const DmsInput(), lng: const DmsInput())),
                      error: sg.pointError,
                    ),
                  ),
                ],
                const SizedBox(height: 8),
                _SubStep(
                  n: resection ? '1' : '2',
                  title: 'Azimuth',
                  done: sg.backOpen,
                  enabled: sg.azOpen,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          CompassDial(
                            key: Key('classic-az-dial-$i'),
                            value: sg.azimuth.value,
                            onChanged: (deg) => _ctl.setAzimuth(i, '$deg'),
                            label: '$title azimuth compass',
                            enabled: sg.azOpen,
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(azLabel, style: _small),
                                const SizedBox(height: 4),
                                _DegreeField(
                                  key: Key('classic-az-$i'),
                                  value: raw.azimuth,
                                  enabled: sg.azOpen,
                                  onChanged: (v) => _ctl.setAzimuth(i, v),
                                ),
                                const SizedBox(height: 4),
                                Text(
                                  resection
                                      ? 'Drawn as a red line from your position toward ${sg.label}.'
                                      : 'Drawn as a red line from ${sg.label} toward the object.',
                                  style: _tiny,
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 6),
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Expanded(
                            child: sg.azimuth.error != null
                                ? _HintLine(Check(Verdict.off, sg.azimuth.error!))
                                : const SizedBox.shrink(),
                          ),
                          _CheckButton(
                            key: Key('classic-az-check-$i'),
                            onPressed: sg.azimuth.value == null ? null : () => _ctl.checkAzimuth(i),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 8),
                _SubStep(
                  n: resection ? '2' : '3',
                  title: 'Back azimuth',
                  done: sg.complete,
                  enabled: sg.backOpen,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          // The azimuth stays on the dial, faint, so the half turn between them shows
                          CompassDial(
                            key: Key('classic-back-dial-$i'),
                            value: sg.back.value,
                            ghost: sg.backOpen ? sg.azimuth.value : null,
                            onChanged: (deg) => _ctl.setBack(i, '$deg'),
                            label: '$title back azimuth compass',
                            enabled: sg.backOpen,
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(backLabel, style: _small),
                                const SizedBox(height: 4),
                                _DegreeField(
                                  key: Key('classic-back-$i'),
                                  value: raw.back,
                                  enabled: sg.backOpen,
                                  onChanged: (v) => _ctl.setBack(i, v),
                                ),
                                const SizedBox(height: 4),
                                Text(
                                  'Drawn as a gold dashed line from ${resection ? 'your position' : sg.label}, '
                                  'the opposite way.',
                                  style: _tiny,
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 6),
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                if (sg.back.error != null)
                                  _HintLine(Check(Verdict.off, sg.back.error!))
                                else if (sg.backCheck != null)
                                  _HintLine(sg.backCheck!),
                                if (sg.backAnswer != null)
                                  Text.rich(
                                    TextSpan(
                                      children: [
                                        const TextSpan(text: 'Answer: '),
                                        TextSpan(
                                          text: formatCompass(sg.backAnswer!),
                                          style: const TextStyle(fontWeight: FontWeight.w700),
                                        ),
                                      ],
                                    ),
                                    key: Key('classic-answer-$i'),
                                    style: _small,
                                  ),
                                if (sg.backCheck == null && sg.back.error == null)
                                  const Text(
                                    'The opposite direction on the compass: add 180° to an azimuth under 180°, '
                                    'subtract 180° from one of 180° or more.',
                                    style: _tiny,
                                  ),
                              ],
                            ),
                          ),
                          const SizedBox(width: 8),
                          _CheckButton(
                            key: Key('classic-back-check-$i'),
                            onPressed: sg.back.value == null ? null : () => _ctl.checkBack(i),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  String _bearing(double deg) => '${formatCompass(deg)} ${compassPoint(deg)}';

  Widget _summaryRow(SightingState sg, {required bool showPoint}) => Container(
    margin: const EdgeInsets.only(bottom: 4),
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
    decoration: BoxDecoration(
      color: Colors.white,
      borderRadius: BorderRadius.circular(8),
      border: Border.all(color: L360Colors.sand200),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(_cap(sg.label), style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700)),
            ),
            Text.rich(
              TextSpan(
                children: [
                  const TextSpan(text: 'Az '),
                  TextSpan(
                    text: sg.azimuth.value == null ? '—' : _bearing(sg.azimuth.value!),
                    style: const TextStyle(fontWeight: FontWeight.w700, color: L360Colors.brick500),
                  ),
                  const TextSpan(text: ' · Back '),
                  TextSpan(
                    text: sg.complete && sg.back.value != null ? _bearing(sg.back.value!) : '—',
                    style: const TextStyle(fontWeight: FontWeight.w700, color: L360Colors.gold700),
                  ),
                ],
              ),
              style: const TextStyle(fontSize: 12, color: L360Colors.sand700),
            ),
          ],
        ),
        if (showPoint && sg.point != null) Text(_ll(sg.point!), style: _tiny),
      ],
    ),
  );

  Widget _fixBox(ClassicSolution sol, {required bool copy}) {
    final fix = sol.fix!;
    return _Box(
      key: const Key('classic-fix'),
      color: Colors.white,
      border: L360Colors.gold100,
      child: Column(
        children: [
          if (!copy)
            const Text(
              "X: the object's position",
              style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: L360Colors.sand600),
            ),
          Text(
            _ll(fix.point),
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700),
          ),
          if (copy)
            Text(
              '${fix.point.$2.toStringAsFixed(6)}, ${fix.point.$1.toStringAsFixed(6)} · ${sol.lines.length} lines · '
              'best cut ${fix.cutAngle.round()}°',
              style: _tiny,
              textAlign: TextAlign.center,
            ),
          const SizedBox(height: 2),
          Text(
            copy
                ? 'Most likely within ±${metresText(fixRadius(fix))} (the red circle, for a compass error of '
                      '±${compassErrorDeg.round()}°)'
                : 'Most likely within ±${metresText(fixRadius(fix))}',
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: L360Colors.brick500),
          ),
          if (copy)
            TextButton.icon(
              key: const Key('classic-copy'),
              onPressed: () async {
                await Clipboard.setData(
                  ClipboardData(text: '${toDMS(fix.point.$2, isLat: true)} ${toDMS(fix.point.$1, isLat: false)}'),
                );
                setState(() => _copied = true);
                Future<void>.delayed(const Duration(milliseconds: 1500), () {
                  if (mounted) setState(() => _copied = false);
                });
              },
              icon: Icon(_copied ? Icons.check : Icons.copy, size: 16),
              label: Text(_copied ? 'Copied' : 'Copy coordinates'),
            ),
        ],
      ),
    );
  }

  Widget _lengthNote(ClassicState s) => Wrap(
    crossAxisAlignment: WrapCrossAlignment.center,
    spacing: 8,
    children: [
      const Text('Drag the dot at the end of a line on the map to make it longer or shorter.', style: _tiny),
      if (s.data.lineLengths.isNotEmpty)
        GestureDetector(
          key: const Key('classic-reset-lengths'),
          onTap: _ctl.resetLineLengths,
          child: const Text(
            'Reset line lengths',
            style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: L360Colors.gold700),
          ),
        ),
    ],
  );

  Widget _resectionResult(ClassicState s, ClassicSolution sol, bool allComplete) => _Box(
    key: const Key('classic-result'),
    color: allComplete ? L360Colors.gold50 : Colors.white,
    border: allComplete ? L360Colors.gold100 : L360Colors.sand200,
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Text('Your sightings', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700)),
        if (sol.origin != null) Text('From ${_ll(sol.origin!)}', style: _tiny),
        const SizedBox(height: 6),
        for (final sg in sol.sightings) _summaryRow(sg, showPoint: false),
        Text(
          allComplete
              ? 'Every line starts at your position: red toward each point, gold the opposite way.'
              : 'Complete each point (azimuth, then back azimuth) to draw its lines.',
          style: _tiny,
        ),
        const SizedBox(height: 4),
        _lengthNote(s),
        _pointsHint(sol),
      ],
    ),
  );

  Widget _intersectionResult(ClassicState s, ClassicSolution sol) => _Box(
    key: const Key('classic-result'),
    color: sol.fix != null ? L360Colors.gold50 : Colors.white,
    border: sol.fix != null ? L360Colors.gold100 : L360Colors.sand200,
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Text("X: the object's position", style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700)),
        if (sol.problem != null) _HintLine(Check(Verdict.off, sol.problem!)),
        if (sol.fix != null) ...[
          const SizedBox(height: 6),
          _fixBox(sol, copy: true),
          for (final h in sol.review) _HintLine(h),
          const SizedBox(height: 4),
          _lengthNote(s),
          _pointsHint(sol),
        ] else if (sol.problem == null)
          const Text(
            'Complete at least two positions (position, azimuth and back azimuth): one line alone cannot tell where '
            'on it the object is; two lines cross at one point, X.',
            style: _tiny,
          ),
      ],
    ),
  );

  // What N, ENE, WSW… after a bearing mean, in Indonesian
  Widget _pointsHint(ClassicSolution sol) {
    bool used(String abbr) => sol.sightings.any(
      (x) =>
          (x.azimuth.value != null && compassPoint(x.azimuth.value!) == abbr) ||
          (x.complete && x.back.value != null && compassPoint(x.back.value!) == abbr),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            key: const Key('classic-points-hint'),
            style: TextButton.styleFrom(
              padding: EdgeInsets.zero,
              minimumSize: const Size(0, 32),
              foregroundColor: L360Colors.gold700,
            ),
            onPressed: () => setState(() => _showPoints = !_showPoints),
            icon: const Icon(Icons.lightbulb_outline, size: 16),
            label: const Text('Apa arti ENE, WSW…?', style: TextStyle(fontSize: 11.5)),
          ),
        ),
        if (_showPoints)
          _Box(
            color: Colors.white,
            border: L360Colors.gold100,
            child: Wrap(
              runSpacing: 2,
              children: [
                for (final p in compassPoints)
                  FractionallySizedBox(
                    widthFactor: 0.5,
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                      decoration: BoxDecoration(
                        color: used(p.abbr) ? L360Colors.gold100 : null,
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: Row(
                        children: [
                          SizedBox(
                            width: 34,
                            child: Text(p.abbr, style: const TextStyle(fontSize: 10.5, fontWeight: FontWeight.w700)),
                          ),
                          SizedBox(width: 38, child: Text('${formatNumber(p.deg)}°', style: _tiny)),
                          Expanded(child: Text(p.id, style: _tiny)),
                        ],
                      ),
                    ),
                  ),
              ],
            ),
          ),
      ],
    );
  }
}

/// 22.5 stays 22.5, 45.0 shows as 45
String formatNumber(double v) => v == v.roundToDouble() ? '${v.round()}' : '$v';

// --- Small parts

class _Badge extends StatelessWidget {
  const _Badge(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
    decoration: BoxDecoration(
      color: L360Colors.gold50,
      borderRadius: BorderRadius.circular(20),
      border: Border.all(color: L360Colors.gold100),
    ),
    child: Text(
      text,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: const TextStyle(fontSize: 9.5, color: L360Colors.gold700),
    ),
  );
}

class _Box extends StatelessWidget {
  const _Box({
    super.key,
    required this.color,
    required this.border,
    required this.child,
    this.padding = const EdgeInsets.all(10),
  });

  final Color color;
  final Color border;
  final Widget child;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) => Container(
    padding: padding,
    decoration: BoxDecoration(
      color: color,
      borderRadius: BorderRadius.circular(L360.radiusSmall),
      border: Border.all(color: border),
    ),
    child: child,
  );
}

class _StepDot extends StatelessWidget {
  const _StepDot({required this.done, this.letter, this.icon});
  final bool done;
  final String? letter;
  final IconData? icon;

  @override
  Widget build(BuildContext context) => Container(
    width: 24,
    height: 24,
    alignment: Alignment.center,
    decoration: BoxDecoration(color: done ? L360Colors.forest700 : L360Colors.gold100, shape: BoxShape.circle),
    child: done
        ? const Icon(Icons.check, size: 14, color: Colors.white)
        : icon != null
        ? Icon(icon, size: 14, color: L360Colors.gold700)
        : Text(
            letter ?? '',
            style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w800, color: L360Colors.gold700),
          ),
  );
}

class _HideButton extends StatelessWidget {
  const _HideButton({required this.hidden, required this.onTap});
  final bool hidden;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => IconButton(
    tooltip: hidden ? 'Show' : 'Hide',
    visualDensity: VisualDensity.compact,
    icon: Icon(hidden ? Icons.expand_more : Icons.expand_less, size: 20),
    onPressed: onTap,
  );
}

class _SubStep extends StatelessWidget {
  const _SubStep({required this.n, required this.title, required this.done, required this.child, this.enabled = true});

  final String n;
  final String title;
  final bool done;
  final bool enabled;
  final Widget child;

  @override
  Widget build(BuildContext context) => IgnorePointer(
    ignoring: !enabled,
    child: Opacity(
      opacity: enabled ? 1 : 0.45,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Container(
                width: 16,
                height: 16,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: done ? L360Colors.forest700 : L360Colors.sand100,
                  shape: BoxShape.circle,
                ),
                child: done
                    ? const Icon(Icons.check, size: 10, color: Colors.white)
                    : Text(
                        n,
                        style: const TextStyle(fontSize: 9, fontWeight: FontWeight.w800, color: L360Colors.sand700),
                      ),
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(title, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700)),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Padding(padding: const EdgeInsets.only(left: 22), child: child),
        ],
      ),
    ),
  );
}

class _CheckButton extends StatelessWidget {
  const _CheckButton({super.key, required this.onPressed});
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) => FilledButton(
    style: FilledButton.styleFrom(
      backgroundColor: L360Colors.forest800,
      minimumSize: const Size(0, 34),
      padding: const EdgeInsets.symmetric(horizontal: 14),
      textStyle: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700),
    ),
    onPressed: onPressed == null
        ? null
        : () {
            HapticFeedback.selectionClick();
            onPressed!();
          },
    child: const Text('Check'),
  );
}

class _HintLine extends StatelessWidget {
  const _HintLine(this.hint);
  final Check hint;

  @override
  Widget build(BuildContext context) {
    final (color, icon) = switch (hint.verdict) {
      Verdict.ok => (L360Colors.forest700, Icons.check_circle_outline),
      Verdict.close => (L360Colors.gold700, Icons.lightbulb_outline),
      Verdict.off => (L360Colors.brick500, Icons.warning_amber_outlined),
    };
    return Padding(
      padding: const EdgeInsets.only(top: 3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 14, color: color),
          const SizedBox(width: 4),
          Expanded(
            child: Text(
              hint.message,
              style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: color, height: 1.35),
            ),
          ),
        ],
      ),
    );
  }
}

/// A text field that follows its value when it changes elsewhere (a map pick, a dial drag)
class _SyncedField extends StatefulWidget {
  const _SyncedField({
    super.key,
    required this.value,
    required this.onChanged,
    this.enabled = true,
    this.hint,
    this.signed = false,
    this.style,
  });

  final String value;
  final ValueChanged<String> onChanged;
  final bool enabled;
  final String? hint;
  final bool signed;
  final TextStyle? style;

  @override
  State<_SyncedField> createState() => _SyncedFieldState();
}

class _SyncedFieldState extends State<_SyncedField> {
  late final _c = TextEditingController(text: widget.value);

  @override
  void didUpdateWidget(_SyncedField old) {
    super.didUpdateWidget(old);
    if (widget.value != _c.text) {
      _c.value = TextEditingValue(
        text: widget.value,
        selection: TextSelection.collapsed(offset: widget.value.length),
      );
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => TextField(
    controller: _c,
    enabled: widget.enabled,
    onChanged: widget.onChanged,
    textAlign: TextAlign.right,
    keyboardType: TextInputType.numberWithOptions(decimal: true, signed: widget.signed),
    style: widget.style ?? const TextStyle(fontSize: 13, fontFeatures: [FontFeature.tabularFigures()]),
    decoration: InputDecoration(
      isDense: true,
      hintText: widget.hint ?? '0',
      contentPadding: const EdgeInsets.symmetric(horizontal: 6, vertical: 8),
    ),
  );
}

class _DegreeField extends StatelessWidget {
  const _DegreeField({super.key, required this.value, required this.onChanged, required this.enabled});

  final String value;
  final ValueChanged<String> onChanged;
  final bool enabled;

  @override
  Widget build(BuildContext context) => Row(
    children: [
      SizedBox(
        width: 96,
        child: _SyncedField(
          value: value,
          onChanged: onChanged,
          enabled: enabled,
          hint: '0–360',
          style: const TextStyle(
            fontSize: 15,
            fontWeight: FontWeight.w700,
            fontFeatures: [FontFeature.tabularFigures()],
          ),
        ),
      ),
      const SizedBox(width: 4),
      const Text('°', style: TextStyle(fontSize: 15, color: L360Colors.sand600)),
    ],
  );
}

/// Latitude and longitude in degrees, minutes and seconds, with N/S and E/W, Pick on map and clear
class _PointFields extends StatelessWidget {
  const _PointFields({
    required this.keyPrefix,
    required this.value,
    required this.onChanged,
    required this.onPick,
    required this.onClear,
    this.error,
  });

  final String keyPrefix;
  final PointInput value;
  final ValueChanged<PointInput> onChanged;
  final VoidCallback onPick;
  final VoidCallback onClear;
  final String? error;

  Widget _dms(String key, DmsInput v, ValueChanged<DmsInput> changed, {required bool wide}) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      for (final (part, mark, width) in [('d', '°', wide ? 54.0 : 44.0), ('m', "'", 42.0), ('s', '"', 66.0)]) ...[
        SizedBox(
          width: width,
          child: _SyncedField(
            key: Key('$key-$part'),
            value: switch (part) {
              'd' => v.d,
              'm' => v.m,
              _ => v.s,
            },
            onChanged: (t) => changed(switch (part) {
              'd' => v.copyWith(d: t),
              'm' => v.copyWith(m: t),
              _ => v.copyWith(s: t),
            }),
          ),
        ),
        SizedBox(
          width: 8,
          child: Text(mark, style: const TextStyle(fontSize: 12, color: L360Colors.sand500)),
        ),
      ],
    ],
  );

  Widget _toggle(String key, (String, String) labels, bool second, ValueChanged<bool> changed) => Container(
    decoration: BoxDecoration(
      border: Border.all(color: L360Colors.sand200),
      borderRadius: BorderRadius.circular(8),
    ),
    clipBehavior: Clip.antiAlias,
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final (i, l) in [labels.$1, labels.$2].indexed)
          GestureDetector(
            key: Key('$key-$l'),
            onTap: () => changed(i == 1),
            child: Container(
              width: 26,
              height: 32,
              alignment: Alignment.center,
              color: second == (i == 1) ? L360Colors.forest800 : Colors.white,
              child: Text(
                l,
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                  color: second == (i == 1) ? Colors.white : L360Colors.sand600,
                ),
              ),
            ),
          ),
      ],
    ),
  );

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      // Wraps on a narrow card with large text
      Wrap(
        alignment: WrapAlignment.end,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          ActionChip(
            key: Key('$keyPrefix-pick'),
            avatar: const Icon(Icons.place_outlined, size: 16),
            label: const Text('Pick on map', style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w700)),
            visualDensity: VisualDensity.compact,
            onPressed: onPick,
          ),
          IconButton(
            tooltip: 'Clear',
            visualDensity: VisualDensity.compact,
            icon: const Icon(Icons.close, size: 16),
            onPressed: onClear,
          ),
        ],
      ),
      // Narrow phones and large text: the row shrinks instead of overflowing
      FittedBox(
        fit: BoxFit.scaleDown,
        alignment: Alignment.centerLeft,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const SizedBox(width: 30, child: Text('Lat', style: _small)),
                _dms('$keyPrefix-lat', value.lat, (lat) => onChanged(value.copyWith(lat: lat)), wide: false),
                const SizedBox(width: 6),
                _toggle('$keyPrefix-ns', ('N', 'S'), value.south, (south) => onChanged(value.copyWith(south: south))),
              ],
            ),
            const SizedBox(height: 6),
            Row(
              children: [
                const SizedBox(width: 30, child: Text('Long', style: _small)),
                _dms('$keyPrefix-lng', value.lng, (lng) => onChanged(value.copyWith(lng: lng)), wide: true),
                const SizedBox(width: 6),
                _toggle('$keyPrefix-ew', ('E', 'W'), value.west, (west) => onChanged(value.copyWith(west: west))),
              ],
            ),
          ],
        ),
      ),
      if (error != null) _HintLine(Check(Verdict.off, error!)),
    ],
  );
}
