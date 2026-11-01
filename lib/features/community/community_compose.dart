import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';

import '../../core/providers.dart';
import '../../core/theme/app_theme.dart';
import '../../core/ui/widgets.dart';
import '../../data/community/community_repository.dart';
import '../../data/community/photo_compress.dart';
import '../../domain/community/community.dart';
import '../../domain/community/community_attachments.dart';
import '../../domain/geo/spherical.dart';
import '../../domain/survey/survey_utils.dart' show toDMS;
import '../../domain/weather/villages.dart';
import '../map/map_tools_state.dart';
import '../tracks/track_recorder_state.dart' show onlineProvider;
import 'community_attach.dart';
import 'community_state.dart';
import 'community_widgets.dart';

// Writing a post (COMMUNITY_PRD.md 8.1, 8.4): trail report or story, conditions, the day it
// happened, where (GPS, map centre, picked on the map or the attachment's place), the place
// name from the nearest village, photos from the camera or gallery (compressed, metadata
// removed), map data (Pro and up) and who sees it (Everyone or one of my clubs). A trail
// report written without signal waits on the phone. Editing (24 hours) changes the text,
// conditions and place name only.

/// A photo from the camera or the gallery (bytes), or null when cancelled; tests replace it
typedef PhotoPicker = Future<Uint8List?> Function(ImageSource source);

final communityPhotoPickerProvider = Provider<PhotoPicker>(
  (ref) => (source) async {
    // The picker shrinks big photos natively first; the app then re-encodes them
    final file = await ImagePicker().pickImage(source: source, maxWidth: 2400, maxHeight: 2400, imageQuality: 95);
    return file?.readAsBytes();
  },
);

/// New post (or the draft back from picking on the map), or [editing] an existing one;
/// true once saved
Future<bool?> openCompose(BuildContext context, {CommunityPost? editing, ComposeDraft? draft}) =>
    Navigator.of(context, rootNavigator: true).push(
      MaterialPageRoute<bool>(
        fullscreenDialog: true,
        builder: (_) => CommunityComposePage(editing: editing, draft: draft),
      ),
    );

class CommunityComposePage extends ConsumerStatefulWidget {
  const CommunityComposePage({super.key, this.editing, this.draft});

  final CommunityPost? editing;
  final ComposeDraft? draft;

  @override
  ConsumerState<CommunityComposePage> createState() => _CommunityComposePageState();
}

class _CommunityComposePageState extends ConsumerState<CommunityComposePage> {
  late final ComposeDraft _start =
      widget.draft ?? ComposeDraft(happenedOn: dateOnly(ref.read(communityClockProvider)()));
  late PostKind _kind = widget.editing?.kind ?? _start.kind;
  late final _title = TextEditingController(text: widget.editing?.title ?? _start.title);
  late final _body = TextEditingController(text: widget.editing?.body ?? _start.body);
  late final _place = TextEditingController(text: widget.editing?.placeName ?? _start.placeName);
  late List<String> _conditions = [...(widget.editing?.conditions ?? _start.conditions)];
  late String _happenedOn = _start.happenedOn;
  late double? _lat = _start.lat;
  late double? _lng = _start.lng;
  late bool _placeEdited = widget.editing != null || _start.placeEdited;
  late List<CompressedPhoto> _photos = [..._start.photos];
  late Attachment? _attachment = _start.attachment;
  late String? _clubId = _start.clubId;
  LngLat? _gps; // where the phone is, for the "near you" warning
  bool _saving = false;
  bool _locating = false;
  bool _addingPhoto = false;
  String? _error;

  bool get _editing => widget.editing != null;

  @override
  void initState() {
    super.initState();
    if (_editing) return;
    // A new post starts at the map centre
    if (_lat == null) {
      final c = ref.read(mapCenterProvider);
      unawaited(_setLocation(c.lng, c.lat));
    } else if (!_placeEdited && _place.text.isEmpty) {
      unawaited(_setLocation(_lng!, _lat!));
    }
    unawaited(
      ref.read(communityGpsProvider)(ask: false).then((p) {
        if (mounted && p != null) setState(() => _gps = p);
      }, onError: (Object _) {}),
    );
  }

  @override
  void dispose() {
    for (final c in [_title, _body, _place]) {
      c.dispose();
    }
    super.dispose();
  }

  /// Sets the location; the place name follows the nearest village unless typed
  Future<void> _setLocation(double lng, double lat) async {
    setState(() {
      _lat = double.parse(lat.toStringAsFixed(6));
      _lng = double.parse(lng.toStringAsFixed(6));
    });
    if (_placeEdited) return;
    try {
      final index = await ref.read(villageIndexProvider.future);
      final v = index.nearest(lat, lng, count: 1);
      if (!mounted || _placeEdited || _lat != double.parse(lat.toStringAsFixed(6))) return;
      setState(() => _place.text = v.isEmpty ? '' : villagePlaceName(v.first.name, v.first.kecamatan));
    } on Object {
      // No village list: the name stays empty to type
    }
  }

  ComposeDraft get _draft => ComposeDraft(
    kind: _kind,
    title: _title.text,
    body: _body.text,
    conditions: _conditions,
    happenedOn: _happenedOn,
    lat: _lat,
    lng: _lng,
    placeName: _place.text,
    placeEdited: _placeEdited,
    photos: _photos,
    attachment: _attachment,
    clubId: _clubId,
  );

  Future<void> _fromGps() async {
    setState(() {
      _locating = true;
      _error = null;
    });
    try {
      final p = await ref.read(communityGpsProvider)(ask: true);
      if (p == null) throw const CommunityException('No GPS fix yet. Try again under open sky.');
      _gps = p;
      await _setLocation(p.$1, p.$2);
    } on Object catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _locating = false);
    }
  }

  void _fromCenter() {
    final c = ref.read(mapCenterProvider);
    unawaited(_setLocation(c.lng, c.lat));
  }

  /// Closes the form while the map is tapped; it opens again with the location set
  void _pickOnMap() {
    ref.read(communityPickProvider.notifier).start(_draft);
    Navigator.of(context).popUntil((r) => r.isFirst);
  }

  Future<void> _addPhoto(ImageSource source) async {
    setState(() {
      _addingPhoto = true;
      _error = null;
    });
    try {
      final raw = await ref.read(communityPhotoPickerProvider)(source);
      if (raw == null) return;
      final photo = await ref.read(communityCompressorProvider)(raw);
      if (mounted) setState(() => _photos = [..._photos, photo]);
    } on Object catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _addingPhoto = false);
    }
  }

  Future<void> _attach() async {
    final a = await pickAttachment(context);
    if (a == null || !mounted) return;
    setState(() => _attachment = a);
  }

  Future<void> _pickDate() async {
    final now = ref.read(communityClockProvider)();
    final today = DateTime(now.year, now.month, now.day);
    final d = await showDatePicker(
      context: context,
      initialDate: parseDateOnly(_happenedOn) ?? today,
      firstDate: today.subtract(const Duration(days: 365)),
      lastDate: today,
    );
    if (d != null) setState(() => _happenedOn = dateOnly(d));
  }

  void _toggleCondition(String id, bool on) {
    setState(() {
      if (!on) {
        _conditions = _conditions.where((c) => c != id).toList();
      } else if (_conditions.length < maxConditions) {
        _conditions = [..._conditions, id];
      } else {
        _error = 'Choose at most $maxConditions conditions.';
      }
    });
  }

  Future<void> _save() async {
    final now = ref.read(communityClockProvider)();
    final problem = postInputError(
      kind: _kind,
      body: _body.text,
      title: _title.text,
      conditions: _conditions,
      happenedOn: _editing ? dateOnly(now) : _happenedOn,
      lat: _editing ? widget.editing!.lat : _lat,
      lng: _editing ? widget.editing!.lng : _lng,
      now: now,
    );
    if (problem != null) {
      setState(() => _error = problem);
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    final repo = ref.read(communityRepositoryProvider);
    try {
      final editing = widget.editing;
      if (editing != null) {
        await repo.update(
          editing.id,
          title: _title.text,
          body: _body.text,
          conditions: _conditions,
          placeName: _place.text,
        );
        ref
            .read(communityFeedProvider.notifier)
            .replace(
              editing.copyWith(
                title: () => _title.text.trim().isEmpty ? null : _title.text.trim(),
                body: _body.text.trim(),
                conditions: _conditions,
                placeName: () => _place.text.trim().isEmpty ? null : _place.text.trim(),
                editedAt: now,
              ),
            );
        if (mounted) Navigator.pop(context, true);
        return;
      }
      final post = NewPost(
        kind: _kind,
        title: _title.text,
        body: _body.text,
        conditions: _conditions,
        happenedOn: _happenedOn,
        lat: _lat!,
        lng: _lng!,
        placeName: _place.text,
        attachment: _attachment,
        clubId: _clubId,
      );
      final userId = ref.read(authUserIdProvider).value;
      if (userId == null) throw const CommunityException('Sign in to post in Community');
      final online = ref.read(onlineProvider).value ?? true;
      if (_kind == PostKind.report && !online) {
        await _queue(post);
        return;
      }
      try {
        await repo.createWithPhotos(userId, post, _photos);
      } on CommunityException catch (e) {
        // No signal: a trail report waits on the phone; a story needs the connection
        if (e.offline && _kind == PostKind.report) {
          await _queue(post);
          return;
        }
        rethrow;
      }
      ref.invalidate(communityLimitsProvider);
      unawaited(ref.read(communityFeedProvider.notifier).load());
      if (mounted) {
        showSnack(context, 'Posted to Community.');
        Navigator.pop(context, true);
      }
    } on Object catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _queue(NewPost post) async {
    await ref.read(communityOutboxProvider.notifier).queue(post, _photos);
    if (mounted) {
      showSnack(context, 'No connection. The report is saved on this phone and sent when you are online.');
      Navigator.pop(context, true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final limits = ref.watch(communityLimitsProvider).value;
    final clubs = ref.watch(myClubsProvider).value ?? const <CommunityClub>[];
    final left = limits?.leftFor(_kind);
    final atLimit = !_editing && left != null && left <= 0;
    final banned = limits?.banned ?? false;
    final maxPhotos = limits?.photos ?? 1;
    final nearMe =
        !_editing &&
        _gps != null &&
        _lat != null &&
        VillageIndex.distanceKm(_gps!.$2, _gps!.$1, _lat!, _lng!) * 1000 < nearMeMeters;
    final center = _attachment?.center;
    const label = TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: L360Colors.sand600);
    return Scaffold(
      appBar: AppBar(
        title: Text(_editing ? 'Edit post' : 'New post'),
        leading: IconButton(tooltip: 'Cancel', icon: const Icon(Icons.close), onPressed: () => Navigator.pop(context)),
      ),
      body: ListView(
        key: const Key('compose-form'),
        padding: const EdgeInsets.fromLTRB(L360.gutter, 8, L360.gutter, 32),
        children: [
          if (banned) ...[
            const ErrorBanner('You cannot post in Community at the moment. Contact us if you think this is a mistake.'),
            const SizedBox(height: 12),
          ],
          if (!_editing) ...[
            SegmentedButton<PostKind>(
              key: const Key('compose-kind'),
              showSelectedIcon: false,
              segments: const [
                ButtonSegment(value: PostKind.report, label: Text('Trail report'), icon: Icon(Icons.hiking, size: 16)),
                ButtonSegment(
                  value: PostKind.story,
                  label: Text('Story'),
                  icon: Icon(Icons.auto_stories_outlined, size: 16),
                ),
              ],
              selected: {_kind},
              onSelectionChanged: (v) => setState(() => _kind = v.first),
            ),
            if (limits != null)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(
                  atLimit
                      ? "You have reached today's limit of ${_kind == PostKind.report ? 'trail reports' : 'stories'} for your plan. Try again tomorrow."
                      : limits.summary,
                  key: const Key('compose-limits'),
                  style: TextStyle(fontSize: 12, color: atLimit ? L360Colors.brick600 : L360Colors.sand600),
                ),
              ),
            const SizedBox(height: 12),
          ],
          TextField(
            key: const Key('compose-title'),
            controller: _title,
            maxLength: titleLimit,
            textCapitalization: TextCapitalization.sentences,
            decoration: InputDecoration(
              labelText: _kind == PostKind.report ? 'Title (optional)' : 'Title',
              hintText: _kind == PostKind.report ? 'e.g. Kandang Badak water source' : 'e.g. Three days on Rinjani',
            ),
          ),
          const SizedBox(height: 4),
          TextField(
            key: const Key('compose-body'),
            controller: _body,
            minLines: _kind == PostKind.report ? 3 : 6,
            maxLines: _kind == PostKind.report ? 6 : 14,
            maxLength: bodyLimit[_kind],
            textCapitalization: TextCapitalization.sentences,
            decoration: InputDecoration(
              labelText: _kind == PostKind.report ? 'What is the trail like?' : 'Your story',
              alignLabelWithHint: true,
            ),
          ),
          const SizedBox(height: 12),
          Text(
            _kind == PostKind.report ? 'Trail conditions (at least one)' : 'Trail conditions (optional)',
            style: label,
          ),
          const SizedBox(height: 6),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (final c in trailConditions)
                FilterChip(
                  key: Key('compose-cond-${c.id}'),
                  showCheckmark: false,
                  avatar: Icon(conditionIcon(c.id), size: 16, color: hexColor(c.color)),
                  label: Text(c.label, style: const TextStyle(fontSize: 12)),
                  selected: _conditions.contains(c.id),
                  onSelected: (on) => _toggleCondition(c.id, on),
                ),
            ],
          ),
          if (!_editing) ...[
            const SizedBox(height: 16),
            Text(_kind == PostKind.report ? 'When did you see it?' : 'When was it?', style: label),
            const SizedBox(height: 4),
            OutlinedButton.icon(
              key: const Key('compose-date'),
              onPressed: _pickDate,
              icon: const Icon(Icons.event, size: 18),
              label: Text(
                parseDateOnly(_happenedOn) == null ? 'Choose the date' : formatDay(parseDateOnly(_happenedOn)!),
              ),
            ),
            const SizedBox(height: 16),
            const Text('Location', style: label),
            const SizedBox(height: 6),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                OutlinedButton.icon(
                  key: const Key('compose-gps'),
                  onPressed: _locating ? null : _fromGps,
                  icon: _locating
                      ? const SizedBox.square(dimension: 16, child: CircularProgressIndicator(strokeWidth: 2))
                      : const Icon(Icons.gps_fixed, size: 18),
                  label: const Text('My GPS'),
                ),
                OutlinedButton.icon(
                  key: const Key('compose-center'),
                  onPressed: _fromCenter,
                  icon: const Icon(Icons.center_focus_strong, size: 18),
                  label: const Text('Map center'),
                ),
                FilledButton.tonalIcon(
                  key: const Key('compose-pick'),
                  onPressed: _pickOnMap,
                  icon: const Icon(Icons.my_location, size: 18),
                  label: const Text('Pick on map'),
                ),
                if (center != null)
                  OutlinedButton.icon(
                    key: const Key('compose-from-attachment'),
                    onPressed: () => _setLocation(center.$1, center.$2),
                    icon: const Icon(Icons.attach_file, size: 18),
                    label: const Text('From attachment'),
                  ),
              ],
            ),
            if (_lat != null)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(
                  '${toDMS(_lat!, isLat: true)} ${toDMS(_lng!, isLat: false)}',
                  key: const Key('compose-coords'),
                  style: const TextStyle(fontSize: 12, color: L360Colors.sand700),
                ),
              ),
            if (nearMe)
              Container(
                key: const Key('compose-near-me'),
                margin: const EdgeInsets.only(top: 8),
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: L360Colors.gold50,
                  borderRadius: BorderRadius.circular(L360.radiusSmall),
                ),
                child: const Row(
                  children: [
                    Icon(Icons.warning_amber_rounded, size: 18, color: L360Colors.gold700),
                    SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'You are sharing where you are now.',
                        style: TextStyle(fontSize: 12, color: L360Colors.gold700, fontWeight: FontWeight.w600),
                      ),
                    ),
                  ],
                ),
              ),
          ],
          const SizedBox(height: 10),
          TextField(
            key: const Key('compose-place'),
            controller: _place,
            maxLength: placeNameLimit,
            onChanged: (_) => _placeEdited = true,
            decoration: const InputDecoration(labelText: 'Place name', hintText: 'Village, district, or trail post'),
          ),
          if (!_editing) ...[
            const SizedBox(height: 8),
            Text('Photos (${_photos.length} / $maxPhotos)', style: label),
            const SizedBox(height: 6),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                for (final (i, ph) in _photos.indexed)
                  Stack(
                    children: [
                      ClipRRect(
                        borderRadius: BorderRadius.circular(8),
                        child: Image.memory(ph.bytes, width: 72, height: 72, fit: BoxFit.cover),
                      ),
                      Positioned(
                        right: 0,
                        top: 0,
                        child: GestureDetector(
                          onTap: () => setState(() => _photos = [..._photos]..removeAt(i)),
                          child: Container(
                            decoration: const BoxDecoration(color: Colors.black54, shape: BoxShape.circle),
                            padding: const EdgeInsets.all(2),
                            child: const Icon(Icons.close, size: 16, color: Colors.white),
                          ),
                        ),
                      ),
                    ],
                  ),
                if (_addingPhoto)
                  const SizedBox.square(dimension: 24, child: CircularProgressIndicator(strokeWidth: 2))
                else if (_photos.length < maxPhotos) ...[
                  OutlinedButton.icon(
                    key: const Key('compose-camera'),
                    onPressed: () => _addPhoto(ImageSource.camera),
                    icon: const Icon(Icons.photo_camera_outlined, size: 18),
                    label: const Text('Camera'),
                  ),
                  OutlinedButton.icon(
                    key: const Key('compose-gallery'),
                    onPressed: () => _addPhoto(ImageSource.gallery),
                    icon: const Icon(Icons.photo_library_outlined, size: 18),
                    label: const Text('Gallery'),
                  ),
                ],
              ],
            ),
            const SizedBox(height: 16),
            const Text('Map data', style: label),
            const SizedBox(height: 6),
            if (_attachment != null)
              Container(
                key: const Key('compose-attachment'),
                padding: const EdgeInsets.fromLTRB(12, 4, 4, 4),
                decoration: BoxDecoration(
                  color: L360Colors.sand50,
                  borderRadius: BorderRadius.circular(L360.radiusSmall),
                  border: Border.all(color: L360Colors.sand200),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.attach_file, size: 18, color: L360Colors.forest700),
                    const SizedBox(width: 8),
                    Expanded(child: Text('${_attachment!.label}: ${_attachment!.name}')),
                    IconButton(
                      tooltip: 'Remove',
                      icon: const Icon(Icons.close, size: 18),
                      onPressed: () => setState(() => _attachment = null),
                    ),
                  ],
                ),
              )
            else if (limits?.attachments ?? false)
              OutlinedButton.icon(
                key: const Key('compose-attach'),
                onPressed: _attach,
                icon: const Icon(Icons.attach_file, size: 18),
                label: const Text('Attach a track, area, location or Field Work'),
              )
            else
              const Text(
                'Attaching your tracks, areas, locations and Field Works is for Pro and Enterprise accounts.',
                key: Key('compose-attach-locked'),
                style: TextStyle(fontSize: 12, color: L360Colors.sand500),
              ),
            if (clubs.isNotEmpty) ...[
              const SizedBox(height: 16),
              DropdownButtonFormField<String?>(
                isExpanded: true,
                key: const Key('compose-audience'),
                initialValue: clubs.any((c) => c.id == _clubId) ? _clubId : null,
                decoration: const InputDecoration(labelText: 'Audience'),
                items: [
                  const DropdownMenuItem<String?>(value: null, child: Text(everyoneLabel)),
                  for (final c in clubs)
                    DropdownMenuItem<String?>(value: c.id, child: Text('Club: ${c.name} · $membersOnlyLabel')),
                ],
                onChanged: (v) => setState(() => _clubId = v),
              ),
            ],
          ],
          if (_error != null) ...[const SizedBox(height: 12), ErrorBanner(_error!)],
          const SizedBox(height: 18),
          FilledButton(
            key: const Key('compose-save'),
            style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(50)),
            onPressed: _saving || banned || atLimit ? null : _save,
            child: _saving
                ? const SizedBox.square(
                    dimension: 20,
                    child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                  )
                : Text(_editing ? 'Save changes' : 'Post'),
          ),
          if (!_editing)
            const Padding(
              padding: EdgeInsets.only(top: 8),
              child: Text(
                'Posts to Everyone can be read by anyone, also without an account. Photo location data is removed.',
                style: TextStyle(fontSize: 11, color: L360Colors.sand500),
              ),
            ),
        ],
      ),
    );
  }
}
