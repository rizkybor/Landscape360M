import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:geolocator/geolocator.dart' as geo;
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/providers.dart';
import '../../core/theme/app_theme.dart';
import '../../data/marked/marked_location_repository.dart';
import '../../domain/marked/marked_locations.dart';
import '../../domain/share/share_location.dart';
import '../../domain/util/js_compat.dart';
import '../map/map_tools_state.dart';
import '../tracks/track_recorder_panel.dart' show contactAdminLabel;
import 'marked_icons.dart';
import 'marked_state.dart';

// Marked Locations (MarkedLocationPanel.tsx, MarkedLocationShareManager.tsx,
// MarkedLocationLinkShare.tsx): the list (mine, shared with me, all accounts for admins),
// search, add / edit with the position picked on the map, from the map centre or the GPS,
// share with accounts or as a link, and GPX export.

/// What the list needs from the map
class MarkedHost {
  const MarkedHost({required this.mapCenter});

  /// Centre of the map (lng, lat)
  final ({double lng, double lat}) Function() mapCenter;
}

/// The map's side for the list: its centre
MarkedHost markedHost(WidgetRef ref) => MarkedHost(mapCenter: () => ref.read(mapCenterProvider));

// --- Form draft, kept while the position is picked on the map --------------------------------

class MarkedDraft {
  const MarkedDraft({
    this.editingId,
    this.name = '',
    this.category = MarkedLocationCategory.poi,
    this.lat = '',
    this.lng = '',
    this.elevation = '',
    this.address = '',
    this.contact = '',
    this.description = '',
    this.tags = '',
  });

  factory MarkedDraft.of(MarkedLocation l) => MarkedDraft(
    editingId: l.id,
    name: l.name,
    category: l.category,
    lat: jsNum(l.lat),
    lng: jsNum(l.lng),
    elevation: l.elevationM == null ? '' : jsNum(l.elevationM!),
    address: l.address ?? '',
    contact: l.contact ?? '',
    description: l.description ?? '',
    tags: l.tags.join(', '),
  );

  final String? editingId;
  final String name;
  final MarkedLocationCategory category;
  final String lat;
  final String lng;
  final String elevation;
  final String address;
  final String contact;
  final String description;
  final String tags;
}

class MarkedDraftController extends Notifier<MarkedDraft?> {
  @override
  MarkedDraft? build() => null;

  void set(MarkedDraft? d) => state = d;
}

/// The form waiting for a position picked on the map
final markedDraftProvider = NotifierProvider<MarkedDraftController, MarkedDraft?>(MarkedDraftController.new);

// --- List ------------------------------------------------------------------------------------

Future<void> showMarkedSheet(BuildContext context, MarkedHost host, {String? focusId}) => showModalBottomSheet<void>(
  context: context,
  isScrollControlled: true,
  useSafeArea: true,
  builder: (_) => DraggableScrollableSheet(
    expand: false,
    initialChildSize: 0.75,
    maxChildSize: 0.95,
    builder: (context, controller) => _MarkedList(controller: controller, host: host, focusId: focusId),
  ),
);

enum _Tab { mine, shared, all }

class _MarkedList extends ConsumerStatefulWidget {
  const _MarkedList({required this.controller, required this.host, this.focusId});

  final ScrollController controller;
  final MarkedHost host;
  final String? focusId;

  @override
  ConsumerState<_MarkedList> createState() => _MarkedListState();
}

class _MarkedListState extends ConsumerState<_MarkedList> {
  _Tab _tab = _Tab.mine;
  String _query = '';
  final _checked = <String>{};

  MarkedController get _rec => ref.read(markedProvider.notifier);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      unawaited(_rec.loadMine());
      unawaited(_rec.loadShared());
      final s = ref.read(markedProvider);
      if (widget.focusId != null && !s.mine.any((l) => l.id == widget.focusId)) {
        setState(() => _tab = s.shared.any((o) => o.location.id == widget.focusId) ? _Tab.shared : _Tab.all);
      }
    });
  }

  void _switch(_Tab t) {
    setState(() {
      _tab = t;
      _checked.clear();
    });
    switch (t) {
      case _Tab.mine:
        unawaited(_rec.loadMine());
      case _Tab.shared:
        unawaited(_rec.loadShared());
      case _Tab.all:
        unawaited(_rec.loadAll());
    }
  }

  void _focus(MarkedLocation l) {
    _rec.select(l.id);
    ref.read(flyToProvider.notifier).go(l.lng, l.lat, zoom: 15);
    Navigator.pop(context);
  }

  Future<void> _export(List<MarkedLocation> items) async {
    if (items.isEmpty) return;
    final stamp = DateTime.now().toIso8601String().substring(0, 10);
    final name = 'landscape360-locations-$stamp.gpx';
    await SharePlus.instance.share(
      ShareParams(
        files: [
          XFile.fromData(
            utf8.encode(markedLocationsToGpx([for (final l in items) l.gpx])),
            mimeType: 'application/gpx+xml',
            name: name,
          ),
        ],
        fileNameOverrides: [name],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final s = ref.watch(markedProvider);
    final profile = ref.watch(profileProvider).value;
    final isAdmin = profile?.isAdmin ?? false;
    final policy = _rec.policy;
    final atLimit = policy.maxLocations != null && s.mine.length >= policy.maxLocations!;
    final List<(MarkedLocation, String?)> items = switch (_tab) {
      _Tab.mine => [for (final l in s.mine) (l, null)],
      _Tab.shared => [for (final o in s.shared) (o.location, o.owner)],
      _Tab.all => [for (final o in s.all) (o.location, o.owner)],
    };
    final shown = items.where((e) => e.$1.matches(_query)).toList();
    final checked = items.map((e) => e.$1).where((l) => _checked.contains(l.id)).toList();
    return ListView(
      controller: widget.controller,
      padding: const EdgeInsets.fromLTRB(L360.gutter, 0, L360.gutter, 32),
      children: [
        Row(
          children: [
            Expanded(child: Text('Marked Locations', style: Theme.of(context).textTheme.titleLarge)),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(
                color: atLimit ? L360Colors.brick50 : L360Colors.gold50,
                borderRadius: BorderRadius.circular(10),
              ),
              child: Text(
                policy.maxLocations == null
                    ? '${s.mine.length} · Unlimited'
                    : '${s.mine.length} / ${policy.maxLocations}',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  color: atLimit ? L360Colors.brick600 : L360Colors.gold700,
                ),
              ),
            ),
            IconButton(
              tooltip: 'Refresh',
              onPressed: s.loading ? null : () => _switch(_tab),
              icon: s.loading
                  ? const SizedBox.square(dimension: 18, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.refresh),
            ),
          ],
        ),
        const SizedBox(height: 8),
        SegmentedButton<_Tab>(
          showSelectedIcon: false,
          segments: [
            ButtonSegment(value: _Tab.mine, label: Text('Mine (${s.mine.length})')),
            ButtonSegment(value: _Tab.shared, label: Text('Shared (${s.shared.length})')),
            if (isAdmin) ButtonSegment(value: _Tab.all, label: Text(s.all.isEmpty ? 'All' : 'All (${s.all.length})')),
          ],
          selected: {_tab},
          onSelectionChanged: (v) => _switch(v.first),
        ),
        if (s.error != null)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(s.error!, style: const TextStyle(color: L360Colors.brick500)),
          ),
        const SizedBox(height: 10),
        Row(
          children: [
            Expanded(
              child: TextField(
                key: const Key('marked-search'),
                onChanged: (v) => setState(() => _query = v),
                decoration: const InputDecoration(
                  isDense: true,
                  prefixIcon: Icon(Icons.search, size: 20),
                  hintText: 'Search name, tag, area…',
                ),
              ),
            ),
            if (_tab == _Tab.mine) ...[
              const SizedBox(width: 8),
              FilledButton.icon(
                key: const Key('marked-add'),
                style: FilledButton.styleFrom(minimumSize: const Size(0, 44)),
                onPressed: atLimit ? null : () => openMarkedForm(context, widget.host, const MarkedDraft()),
                icon: const Icon(Icons.add_location_alt_outlined, size: 18),
                label: const Text('Add'),
              ),
            ],
          ],
        ),
        if (_tab == _Tab.mine && atLimit)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(
              'You have reached the ${policy.maxLocations}-location limit of your plan. Delete a location or '
              '$contactAdminLabel for more.',
              style: const TextStyle(fontSize: 12, color: L360Colors.brick600),
            ),
          ),
        if (_tab == _Tab.mine && !policy.canShare)
          const Padding(
            padding: EdgeInsets.only(top: 8),
            child: Text(
              'Sharing locations is available for Pro and Enterprise. $contactAdminLabel to enable it.',
              style: TextStyle(fontSize: 12, color: L360Colors.sand600),
            ),
          ),
        if (_tab == _Tab.all)
          SwitchListTile.adaptive(
            contentPadding: EdgeInsets.zero,
            title: const Text('Show every account’s locations on the map'),
            value: s.showAllOnMap,
            onChanged: _rec.setShowAllOnMap,
          ),
        const SizedBox(height: 6),
        Row(
          children: [
            Text(
              checked.isEmpty ? '${shown.length} shown' : '${checked.length} selected',
              style: const TextStyle(fontSize: 12, color: L360Colors.sand500),
            ),
            const Spacer(),
            if (checked.isNotEmpty && _tab == _Tab.mine && policy.canShare)
              TextButton.icon(
                onPressed: () => showMarkedShareSheet(context, [for (final l in checked) l.id]),
                icon: const Icon(Icons.group_add_outlined, size: 18),
                label: const Text('Share'),
              ),
            TextButton.icon(
              key: const Key('marked-gpx'),
              onPressed: shown.isEmpty
                  ? null
                  : () => _export(checked.isEmpty ? [for (final e in shown) e.$1] : checked),
              icon: const Icon(Icons.ios_share, size: 18),
              label: const Text('GPX'),
            ),
            if (checked.isNotEmpty)
              IconButton(
                tooltip: 'Clear selection',
                onPressed: () => setState(_checked.clear),
                icon: const Icon(Icons.close, size: 18),
              ),
          ],
        ),
        for (final (l, owner) in shown)
          _LocationTile(
            key: Key('marked-${l.id}'),
            location: l,
            owner: owner,
            checked: _checked.contains(l.id),
            highlighted: l.id == widget.focusId || l.id == s.selectedId,
            onChecked: (v) => setState(() => v ? _checked.add(l.id) : _checked.remove(l.id)),
            onTap: () => _focus(l),
            onMore: () => _actions(context, l, owner),
          ),
        if (shown.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 28),
            child: Text(
              _query.trim().isNotEmpty
                  ? 'No locations match your search'
                  : switch (_tab) {
                      _Tab.mine => 'No marked locations yet. Press Add to save your first place.',
                      _Tab.shared => 'Nobody has shared a location with you yet',
                      _Tab.all => 'No locations saved by any account yet',
                    },
              textAlign: TextAlign.center,
              style: const TextStyle(color: L360Colors.sand500),
            ),
          ),
      ],
    );
  }

  Future<void> _actions(BuildContext context, MarkedLocation l, String? owner) async {
    final userId = ref.read(markedProvider).userId;
    final isAdmin = ref.read(profileProvider).value?.isAdmin ?? false;
    final own = l.userId == userId;
    final policy = _rec.policy;
    final action = await showModalBottomSheet<String>(
      context: context,
      useSafeArea: true,
      builder: (context) => Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(L360.gutter, 4, L360.gutter, 8),
            child: Text(l.name, style: Theme.of(context).textTheme.titleMedium, overflow: TextOverflow.ellipsis),
          ),
          for (final (id, icon, label, danger) in [
            ('map', Icons.near_me, 'Show on map', false),
            if (own && policy.canShare) ('share', Icons.group_add_outlined, 'Share', false),
            if (own || isAdmin) ('edit', Icons.edit_outlined, 'Edit', false),
            if (_tab == _Tab.shared)
              ('leave', Icons.logout, 'Remove from my list', true)
            else if (own || isAdmin)
              ('delete', Icons.delete_outline, 'Delete', true),
          ])
            ListTile(
              key: Key('marked-action-$id'),
              leading: Icon(icon, color: danger ? L360Colors.brick500 : L360Colors.forest700),
              title: Text(label, style: TextStyle(color: danger ? L360Colors.brick500 : null)),
              onTap: () => Navigator.pop(context, id),
            ),
          const SizedBox(height: 8),
        ],
      ),
    );
    if (!context.mounted || action == null) return;
    switch (action) {
      case 'map':
        _focus(l);
      case 'share':
        await showMarkedShareSheet(context, [l.id]);
      case 'edit':
        await openMarkedForm(context, widget.host, MarkedDraft.of(l));
      case 'leave' || 'delete':
        final leave = action == 'leave';
        final ok = await _confirm(
          context,
          leave ? 'Remove "${l.name}" from your list?' : 'Delete "${l.name}"?',
          leave
              ? 'The owner keeps it.'
              : own
              ? 'It is deleted permanently. People you shared it with lose access.'
              : 'It is deleted from the owner’s account permanently.',
          leave ? 'Remove' : 'Delete',
        );
        if (!ok) return;
        try {
          leave ? await _rec.leaveShared(l.id) : await _rec.delete(l.id);
          setState(() => _checked.remove(l.id));
        } on Object catch (e) {
          if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
        }
    }
  }
}

Future<bool> _confirm(BuildContext context, String title, String body, String action) async =>
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
            child: Text(action),
          ),
        ],
      ),
    ) ??
    false;

class _LocationTile extends StatelessWidget {
  const _LocationTile({
    super.key,
    required this.location,
    required this.owner,
    required this.checked,
    required this.highlighted,
    required this.onChecked,
    required this.onTap,
    required this.onMore,
  });

  final MarkedLocation location;
  final String? owner;
  final bool checked;
  final bool highlighted;
  final ValueChanged<bool> onChecked;
  final VoidCallback onTap;
  final VoidCallback onMore;

  @override
  Widget build(BuildContext context) {
    final l = location;
    final color = markedCategoryColor(l.category);
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      color: highlighted ? L360Colors.gold50 : null,
      child: InkWell(
        borderRadius: BorderRadius.circular(L360.radiusSmall),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(4, 8, 4, 8),
          child: Row(
            children: [
              Checkbox(value: checked, onChanged: (v) => onChecked(v ?? false)),
              Container(
                width: 30,
                height: 30,
                decoration: BoxDecoration(color: color, shape: BoxShape.circle),
                child: Icon(markedCategoryIcons[l.category], color: Colors.white, size: 16),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      l.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700),
                    ),
                    Text(
                      [
                        l.category.label,
                        if (l.elevationM != null) '${jsRoundStr(l.elevationM!)} mdpl',
                        if (owner != null) 'by $owner',
                      ].join(' · '),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 12, color: L360Colors.sand600),
                    ),
                    if (l.tags.isNotEmpty)
                      Text(
                        l.tags.join(' · '),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 11, color: L360Colors.sand500),
                      ),
                  ],
                ),
              ),
              IconButton(
                key: Key('marked-more-${l.id}'),
                tooltip: 'More',
                onPressed: onMore,
                icon: const Icon(Icons.more_horiz, color: L360Colors.sand600),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// --- Form ------------------------------------------------------------------------------------

Future<void> openMarkedForm(BuildContext context, MarkedHost host, MarkedDraft draft) =>
    Navigator.of(context, rootNavigator: true).push(
      MaterialPageRoute<void>(
        fullscreenDialog: true,
        builder: (_) => MarkedFormPage(draft: draft, host: host),
      ),
    );

class MarkedFormPage extends ConsumerStatefulWidget {
  const MarkedFormPage({super.key, required this.draft, required this.host});

  final MarkedDraft draft;
  final MarkedHost host;

  @override
  ConsumerState<MarkedFormPage> createState() => _MarkedFormPageState();
}

class _MarkedFormPageState extends ConsumerState<MarkedFormPage> {
  late final _name = TextEditingController(text: widget.draft.name);
  late final _lat = TextEditingController(text: widget.draft.lat);
  late final _lng = TextEditingController(text: widget.draft.lng);
  late final _elevation = TextEditingController(text: widget.draft.elevation);
  late final _address = TextEditingController(text: widget.draft.address);
  late final _contact = TextEditingController(text: widget.draft.contact);
  late final _description = TextEditingController(text: widget.draft.description);
  late final _tags = TextEditingController(text: widget.draft.tags);
  late MarkedLocationCategory _category = widget.draft.category;
  late bool _more = [
    widget.draft.address,
    widget.draft.contact,
    widget.draft.description,
    widget.draft.tags,
  ].any((s) => s.isNotEmpty);
  String? _error;
  bool _saving = false;
  bool _locating = false;

  @override
  void dispose() {
    for (final c in [_name, _lat, _lng, _elevation, _address, _contact, _description, _tags]) {
      c.dispose();
    }
    super.dispose();
  }

  MarkedDraft get _draft => MarkedDraft(
    editingId: widget.draft.editingId,
    name: _name.text,
    category: _category,
    lat: _lat.text,
    lng: _lng.text,
    elevation: _elevation.text,
    address: _address.text,
    contact: _contact.text,
    description: _description.text,
    tags: _tags.text,
  );

  /// Closes the form while the map is tapped; it opens again with the position filled in
  void _pickOnMap() {
    ref.read(markedDraftProvider.notifier).set(_draft);
    ref.read(markedProvider.notifier).startPicking();
    Navigator.of(context).popUntil((r) => r.isFirst);
  }

  void _fromCenter() {
    final c = widget.host.mapCenter();
    setState(() {
      _lat.text = roundCoord(c.lat);
      _lng.text = roundCoord(c.lng);
    });
  }

  Future<void> _fromGps() async {
    setState(() => _locating = true);
    try {
      var p = await geo.Geolocator.checkPermission();
      if (p == geo.LocationPermission.denied) p = await geo.Geolocator.requestPermission();
      final pos = await geo.Geolocator.getCurrentPosition(
        locationSettings: const geo.LocationSettings(
          accuracy: geo.LocationAccuracy.high,
          timeLimit: Duration(seconds: 15),
        ),
      );
      setState(() {
        _lat.text = roundCoord(pos.latitude);
        _lng.text = roundCoord(pos.longitude);
        if (pos.altitudeAccuracy > 0) _elevation.text = '${pos.altitude.round()}';
      });
    } on Object catch (e) {
      setState(() => _error = 'Could not get your location: $e');
    } finally {
      if (mounted) setState(() => _locating = false);
    }
  }

  Future<void> _save() async {
    final problem = markedFormError(name: _name.text, lat: _lat.text, lng: _lng.text, elevation: _elevation.text);
    if (problem != null) {
      setState(() => _error = problem);
      return;
    }
    final input = MarkedLocationInput(
      name: _name.text,
      category: _category,
      lat: double.parse(_lat.text.trim()),
      lng: double.parse(_lng.text.trim()),
      elevationM: _elevation.text.trim().isEmpty ? null : double.parse(_elevation.text.trim()),
      address: _address.text,
      contact: _contact.text,
      description: _description.text,
      tags: parseTags(_tags.text),
    );
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final rec = ref.read(markedProvider.notifier);
      final id = widget.draft.editingId;
      final saved = id == null ? await rec.create(input) : await rec.update(id, input);
      ref.read(markedDraftProvider.notifier).set(null);
      rec.select(saved.id);
      ref.read(flyToProvider.notifier).go(saved.lng, saved.lat, zoom: 15);
      if (mounted) Navigator.of(context).popUntil((r) => r.isFirst);
    } on Object catch (e) {
      setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final editing = widget.draft.editingId != null;
    return Scaffold(
      appBar: AppBar(
        title: Text(editing ? 'Edit location' : 'New location'),
        leading: IconButton(
          tooltip: 'Cancel',
          icon: const Icon(Icons.close),
          onPressed: () {
            ref.read(markedDraftProvider.notifier).set(null);
            Navigator.pop(context);
          },
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(L360.gutter, 8, L360.gutter, 32),
        children: [
          TextField(
            key: const Key('marked-name'),
            controller: _name,
            maxLength: 120,
            textCapitalization: TextCapitalization.sentences,
            decoration: const InputDecoration(labelText: 'Name', hintText: 'e.g. Pos 3 Gunung Gede', counterText: ''),
          ),
          const SizedBox(height: 14),
          const Text(
            'Category',
            style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: L360Colors.sand600),
          ),
          const SizedBox(height: 6),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (final c in MarkedLocationCategory.values)
                ChoiceChip(
                  key: Key('marked-cat-${c.name}'),
                  showCheckmark: false,
                  avatar: Icon(markedCategoryIcons[c], size: 16, color: markedCategoryColor(c)),
                  label: Text(c.label, style: const TextStyle(fontSize: 12)),
                  selected: _category == c,
                  onSelected: (_) => setState(() => _category = c),
                ),
            ],
          ),
          const SizedBox(height: 16),
          const Text(
            'Position',
            style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: L360Colors.sand600),
          ),
          const SizedBox(height: 6),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              FilledButton.tonalIcon(
                style: const ButtonStyle(minimumSize: WidgetStatePropertyAll(Size(0, 44))),
                key: const Key('marked-pick'),
                onPressed: _pickOnMap,
                icon: const Icon(Icons.my_location, size: 18),
                label: const Text('Pick on map'),
              ),
              OutlinedButton.icon(
                style: const ButtonStyle(minimumSize: WidgetStatePropertyAll(Size(0, 44))),
                onPressed: _fromCenter,
                icon: const Icon(Icons.center_focus_strong, size: 18),
                label: const Text('Map center'),
              ),
              OutlinedButton.icon(
                style: const ButtonStyle(minimumSize: WidgetStatePropertyAll(Size(0, 44))),
                onPressed: _locating ? null : _fromGps,
                icon: _locating
                    ? const SizedBox.square(dimension: 16, child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.gps_fixed, size: 18),
                label: const Text('My GPS'),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(child: _num(_lat, 'Latitude', const Key('marked-lat'))),
              const SizedBox(width: 8),
              Expanded(child: _num(_lng, 'Longitude', const Key('marked-lng'))),
              const SizedBox(width: 8),
              SizedBox(width: 96, child: _num(_elevation, 'Elev. (m)', const Key('marked-elev'))),
            ],
          ),
          const SizedBox(height: 8),
          TextButton.icon(
            onPressed: () => setState(() => _more = !_more),
            icon: Icon(_more ? Icons.expand_less : Icons.expand_more),
            label: Text(_more ? 'Fewer details' : 'More details (address, contact, notes, tags)'),
          ),
          if (_more) ...[
            TextField(
              controller: _address,
              decoration: const InputDecoration(labelText: 'Address / area', hintText: 'Village, district'),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: _contact,
              decoration: const InputDecoration(labelText: 'Contact', hintText: 'Ranger, phone'),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: _description,
              minLines: 3,
              maxLines: 6,
              decoration: const InputDecoration(
                labelText: 'Notes',
                hintText: 'Access, conditions, water availability, notes…',
              ),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: _tags,
              decoration: const InputDecoration(
                labelText: 'Tags',
                hintText: 'Comma separated, e.g. basecamp, water, 2024',
              ),
            ),
          ],
          if (_error != null) ...[
            const SizedBox(height: 12),
            Text(
              _error!,
              key: const Key('marked-error'),
              style: const TextStyle(color: L360Colors.brick500),
            ),
          ],
          const SizedBox(height: 18),
          FilledButton(
            key: const Key('marked-save'),
            style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(50)),
            onPressed: _saving ? null : _save,
            child: _saving
                ? const SizedBox.square(
                    dimension: 20,
                    child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                  )
                : Text(editing ? 'Save Changes' : 'Save Location'),
          ),
        ],
      ),
    );
  }

  Widget _num(TextEditingController c, String label, Key key) => TextField(
    key: key,
    controller: c,
    keyboardType: const TextInputType.numberWithOptions(decimal: true, signed: true),
    inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[-0-9.]'))],
    decoration: InputDecoration(labelText: label, isDense: true),
  );
}

// --- Sharing ---------------------------------------------------------------------------------

Future<void> showMarkedShareSheet(BuildContext context, List<String> ids) => showModalBottomSheet<void>(
  context: context,
  isScrollControlled: true,
  useSafeArea: true,
  builder: (context) => Padding(
    padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
    child: DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.7,
      maxChildSize: 0.95,
      builder: (context, controller) => _ShareSheet(ids: ids, controller: controller),
    ),
  ),
);

class _ShareSheet extends ConsumerStatefulWidget {
  const _ShareSheet({required this.ids, required this.controller});

  final List<String> ids;
  final ScrollController controller;

  @override
  ConsumerState<_ShareSheet> createState() => _ShareSheetState();
}

class _ShareSheetState extends ConsumerState<_ShareSheet> {
  final _recipient = TextEditingController();
  List<LocationShare> _shares = const [];
  List<ShareSuggestion> _suggestions = const [];
  String? _suggestionsFor;
  bool _searching = false;
  bool _sharing = false;
  String? _error;
  String? _notice;
  Timer? _debounce;

  String? get _single => widget.ids.length == 1 ? widget.ids.first : null;
  MarkedLocationBackend get _cloud => ref.read(markedBackendProvider);

  @override
  void initState() {
    super.initState();
    unawaited(_loadShares());
    _search('');
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _recipient.dispose();
    super.dispose();
  }

  Future<void> _loadShares() async {
    final id = _single;
    if (id == null) return;
    try {
      final list = await _cloud.shares(id);
      if (mounted) setState(() => _shares = list);
    } on Object catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
  }

  // Recent recipients while empty, matching accounts as you type (debounced)
  void _search(String text) {
    final q = text.trim();
    _debounce?.cancel();
    if (q.length == 1) return;
    _debounce = Timer(Duration(milliseconds: q.isEmpty ? 0 : 300), () async {
      setState(() => _searching = true);
      try {
        final list = await _cloud.suggestions(q);
        if (mounted) {
          setState(() {
            _suggestions = list;
            _suggestionsFor = q;
          });
        }
      } on Object {
        if (mounted) setState(() => _suggestions = const []);
      } finally {
        if (mounted) setState(() => _searching = false);
      }
    });
  }

  Future<void> _shareWith(String value) async {
    if (value.trim().isEmpty) return;
    setState(() {
      _sharing = true;
      _error = null;
      _notice = null;
    });
    try {
      final r = await _cloud.share(widget.ids, value.trim());
      setState(() {
        _notice = r.sharedCount == 0
            ? '${r.label} already has access'
            : 'Shared ${widget.ids.length == 1 ? 'location' : '${r.sharedCount} locations'} with ${r.label}';
        _recipient.clear();
      });
      _search('');
      await _loadShares();
    } on Object catch (e) {
      setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _sharing = false);
    }
  }

  Future<void> _revoke(LocationShare share) async {
    if (!await _confirm(
      context,
      'Remove access for ${share.label}?',
      'They can no longer see this location.',
      'Remove',
    )) {
      return;
    }
    try {
      await _cloud.removeShare(_single!, share.userId);
      setState(() {
        _shares = _shares.where((s) => s.userId != share.userId).toList();
        _notice = 'Access removed for ${share.label}';
      });
    } on Object catch (e) {
      setState(() => _error = '$e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final q = _recipient.text.trim();
    final hasAccess = {for (final s in _shares) s.userId};
    final list = _suggestions.where((s) => !hasAccess.contains(s.userId)).toList();
    final location = _single == null
        ? null
        : ref.watch(markedProvider.select((s) => s.mine.where((l) => l.id == _single).firstOrNull));
    return ListView(
      controller: widget.controller,
      padding: const EdgeInsets.fromLTRB(L360.gutter, 0, L360.gutter, 24),
      children: [
        Text(
          _single != null ? 'Share location' : 'Share ${widget.ids.length} locations',
          style: Theme.of(context).textTheme.titleLarge,
        ),
        if (location != null) Text(location.name, style: const TextStyle(color: L360Colors.sand600)),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(
              child: TextField(
                key: const Key('marked-recipient'),
                controller: _recipient,
                autocorrect: false,
                textInputAction: TextInputAction.send,
                onChanged: (v) {
                  setState(() {});
                  _search(v);
                },
                onSubmitted: _shareWith,
                decoration: const InputDecoration(isDense: true, hintText: 'Name or email'),
              ),
            ),
            const SizedBox(width: 8),
            FilledButton(
              // Beside the field: not the theme's full width
              style: FilledButton.styleFrom(minimumSize: const Size(0, 44)),
              onPressed: _sharing ? null : () => _shareWith(_recipient.text),
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
        if (q.isEmpty && list.isNotEmpty)
          const Text(
            'Recent',
            style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: L360Colors.sand500),
          ),
        if (q.isNotEmpty && _suggestionsFor == q && !_searching && list.isEmpty)
          const Text(
            'No matching account. You can still type the full email and press Share.',
            style: TextStyle(fontSize: 12, color: L360Colors.sand500),
          ),
        for (final s in list)
          ListTile(
            contentPadding: EdgeInsets.zero,
            dense: true,
            leading: Icon(s.recent ? Icons.history : Icons.person_add_alt, size: 20),
            title: Text(s.label),
            onTap: _sharing ? null : () => _shareWith(s.userId),
          ),
        if (_error != null || _notice != null)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(
              _error ?? _notice!,
              style: TextStyle(color: _error != null ? L360Colors.brick500 : L360Colors.forest700),
            ),
          ),
        if (_single != null) ...[
          const SizedBox(height: 12),
          Text(
            _shares.isEmpty ? 'Not shared with anyone yet' : 'Has access (${_shares.length})',
            style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: L360Colors.sand600),
          ),
          for (final s in _shares)
            ListTile(
              contentPadding: EdgeInsets.zero,
              dense: true,
              leading: const Icon(Icons.person_outline, size: 20),
              title: Text(s.label),
              trailing: IconButton(
                tooltip: 'Remove access',
                icon: const Icon(Icons.person_remove_outlined, color: L360Colors.brick500),
                onPressed: () => _revoke(s),
              ),
            ),
          if (location != null) ...[
            const Divider(height: 28),
            ShareLinkBox(
              what: 'this location',
              getToken: () => _cloud.link(location.id),
              createToken: () => _cloud.createLink(location.id),
              revoke: () => _cloud.revokeLink(location.id),
              urlFor: placeLinkUrl,
              messageFor: (url) => buildPlaceShareText(
                name: location.name,
                categoryLabel: location.category.label,
                lat: location.lat,
                lng: location.lng,
                elevationM: location.elevationM,
                url: url,
              ),
            ),
          ],
        ],
      ],
    );
  }
}

/// "Share as a link" (ShareLinkBox.tsx): a link anyone can open without signing in, sent on
/// WhatsApp or copied, and turned off when no longer wanted. Used for locations and areas.
class ShareLinkBox extends StatefulWidget {
  const ShareLinkBox({
    super.key,
    required this.what,
    required this.getToken,
    required this.createToken,
    required this.revoke,
    required this.urlFor,
    required this.messageFor,
  });

  final String what;
  final Future<String?> Function() getToken;
  final Future<String> Function() createToken;
  final Future<void> Function() revoke;
  final String Function(String token) urlFor;
  final String Function(String url) messageFor;

  @override
  State<ShareLinkBox> createState() => _ShareLinkBoxState();
}

class _ShareLinkBoxState extends State<ShareLinkBox> {
  String? _token;
  bool _loading = true;
  bool _busy = false;
  bool _copied = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    widget
        .getToken()
        .then((t) {
          if (mounted) setState(() => _token = t);
        })
        .catchError((Object e) {
          if (mounted) setState(() => _error = '$e');
        })
        .whenComplete(() {
          if (mounted) setState(() => _loading = false);
        });
  }

  Future<void> _run(Future<void> Function() fn) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await fn();
    } on Object catch (e) {
      setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final token = _token;
    final url = token == null ? '' : widget.urlFor(token);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Row(
          children: [
            Icon(Icons.link, size: 18, color: L360Colors.forest700),
            SizedBox(width: 6),
            Text('Share as a link', style: TextStyle(fontWeight: FontWeight.w700)),
          ],
        ),
        const SizedBox(height: 4),
        Text(
          'Anyone who opens the link can see ${widget.what}, no sign-in needed. Send it on WhatsApp.',
          style: const TextStyle(fontSize: 12, color: L360Colors.sand600),
        ),
        const SizedBox(height: 10),
        if (_loading)
          const Center(child: SizedBox.square(dimension: 20, child: CircularProgressIndicator(strokeWidth: 2)))
        else if (token == null)
          OutlinedButton.icon(
            key: const Key('link-create'),
            onPressed: _busy
                ? null
                : () => _run(() async {
                    final t = await widget.createToken();
                    setState(() => _token = t);
                  }),
            icon: const Icon(Icons.add_link, size: 18),
            label: const Text('Create link'),
          )
        else ...[
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            decoration: BoxDecoration(color: L360Colors.sand50, borderRadius: BorderRadius.circular(10)),
            child: SelectableText(url, style: const TextStyle(fontSize: 12)),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              FilledButton.icon(
                style: FilledButton.styleFrom(backgroundColor: const Color(0xFF25D366), minimumSize: const Size(0, 40)),
                onPressed: () => launchUrl(
                  Uri.parse(whatsappShareUrl(widget.messageFor(url))),
                  mode: LaunchMode.externalApplication,
                ),
                icon: const Icon(Icons.chat, size: 18),
                label: const Text('Send to WhatsApp'),
              ),
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
                label: Text(_copied ? 'Copied' : 'Copy'),
              ),
              TextButton.icon(
                key: const Key('link-off'),
                style: TextButton.styleFrom(foregroundColor: L360Colors.brick500, minimumSize: const Size(0, 40)),
                onPressed: _busy
                    ? null
                    : () async {
                        if (!await _confirm(
                          context,
                          'Turn the link off?',
                          'People who have it can no longer open ${widget.what}.',
                          'Turn off',
                        )) {
                          return;
                        }
                        await _run(() async {
                          await widget.revoke();
                          setState(() => _token = null);
                        });
                      },
                icon: const Icon(Icons.link_off, size: 18),
                label: const Text('Turn off'),
              ),
            ],
          ),
        ],
        if (_error != null)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(_error!, style: const TextStyle(fontSize: 12, color: L360Colors.brick500)),
          ),
      ],
    );
  }
}
