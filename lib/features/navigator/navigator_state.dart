import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/providers.dart';
import '../../data/survey/survey_repository.dart';
import '../../domain/account/profile.dart';
import '../../domain/survey/survey_model.dart';
import '../../domain/survey/survey_utils.dart';

// The Navigator: the survey being drawn, its sheets and points, kept on the phone after
// every change and saved to the cloud when signed in (like useSurveyStore on the web,
// which saves after every action).

final surveyBackendProvider = Provider<SurveyBackend>(
  (ref) => SupabaseSurveyBackend(ref.watch(supabaseClientProvider)),
);

final surveyPrefsProvider = Provider<SharedPreferencesAsync>((ref) => SharedPreferencesAsync());

class SurveyNavigatorState {
  const SurveyNavigatorState({
    this.enabled = false,
    this.doc = const SurveyDoc(),
    this.currentSurveyId,
    this.straight = false,
    this.angleStep = 0,
    this.selectedPointId,
    this.saved = const [],
    this.syncing = false,
    this.dirty = false,
    this.error,
  });

  final bool enabled; // plot mode: taps on the map add points
  final SurveyDoc doc;
  final String? currentSurveyId; // cloud row being edited; null = not saved yet
  final bool straight;
  final int angleStep;
  final String? selectedPointId; // point whose curve handles are shown
  final List<SavedSurvey> saved;
  final bool syncing;
  final bool dirty; // changes not in the cloud yet (offline or failed)
  final String? error;

  SurveyNavigatorState copyWith({
    bool? enabled,
    SurveyDoc? doc,
    String? Function()? currentSurveyId,
    bool? straight,
    int? angleStep,
    String? Function()? selectedPointId,
    List<SavedSurvey>? saved,
    bool? syncing,
    bool? dirty,
    String? Function()? error,
  }) => SurveyNavigatorState(
    enabled: enabled ?? this.enabled,
    doc: doc ?? this.doc,
    currentSurveyId: currentSurveyId == null ? this.currentSurveyId : currentSurveyId(),
    straight: straight ?? this.straight,
    angleStep: angleStep ?? this.angleStep,
    selectedPointId: selectedPointId == null ? this.selectedPointId : selectedPointId(),
    saved: saved ?? this.saved,
    syncing: syncing ?? this.syncing,
    dirty: dirty ?? this.dirty,
    error: error == null ? this.error : error(),
  );

  Map<String, dynamic> toJson() => {
    'groups': surveyToJson(doc.groups),
    'activeGroupId': doc.activeGroupId,
    'currentSurveyId': currentSurveyId,
    'isStraightMode': straight,
    'angleStep': angleStep,
    'savedSurveys': [for (final s in saved) s.toJson()],
    'dirty': dirty,
  };

  static SurveyNavigatorState fromJson(Map<String, dynamic> j) => SurveyNavigatorState(
    doc: SurveyDoc(groups: surveyFromJson(j['groups']), activeGroupId: j['activeGroupId'] as String?),
    currentSurveyId: j['currentSurveyId'] as String?,
    straight: j['isStraightMode'] == true,
    angleStep: angleSteps.contains(j['angleStep']) ? j['angleStep'] as int : 0,
    saved: [
      for (final s in (j['savedSurveys'] as List? ?? const []))
        if (s is Map) SavedSurvey.fromRow(Map<String, dynamic>.from(s)),
    ],
    dirty: j['dirty'] == true,
  );
}

class NavigatorController extends Notifier<SurveyNavigatorState> {
  static const _prefsKey = 'l360-survey-store';
  static const saveDelay = Duration(milliseconds: 800);
  Timer? _saveTimer;
  Future<void>? _saving;

  @override
  SurveyNavigatorState build() {
    ref.onDispose(() => _saveTimer?.cancel());
    // Signing out clears the survey from the phone (like the web)
    ref.listen(authUserIdProvider, (prev, next) {
      final was = prev?.value, now = next.value;
      if (was != null && now == null) {
        _saveTimer?.cancel();
        state = const SurveyNavigatorState();
        unawaited(_persist());
      } else if (now != null && now != was) {
        unawaited(refreshSaved());
        if (state.dirty) _scheduleSave();
      }
    });
    unawaited(_restore());
    return const SurveyNavigatorState();
  }

  SharedPreferencesAsync get _prefs => ref.read(surveyPrefsProvider);

  Future<void> _restore() async {
    try {
      final raw = await _prefs.getString(_prefsKey);
      if (raw == null) return;
      final saved = SurveyNavigatorState.fromJson(jsonDecode(raw) as Map<String, dynamic>);
      state = saved.copyWith(enabled: state.enabled);
      if (saved.dirty) _scheduleSave();
    } on Object {
      // Unreadable: start empty
    }
  }

  Future<void> _persist() async {
    try {
      await _prefs.setString(_prefsKey, jsonEncode(state.toJson()));
    } on Object {
      // Storage unavailable: the survey stays in memory
    }
  }

  String? get _userId => ref.read(authUserIdProvider).value;
  AccountProfile? get _profile => ref.read(profileProvider).value;

  /// A change to the drawing: kept on the phone now, saved to the cloud shortly after
  void _edit(SurveyDoc doc, {String? Function()? selected}) {
    state = state.copyWith(doc: doc, dirty: true, error: () => null, selectedPointId: selected);
    unawaited(_persist());
    _scheduleSave();
  }

  void _scheduleSave() {
    _saveTimer?.cancel();
    if (_userId == null) return; // signed out: nothing to send; saved when the user signs in
    _saveTimer = Timer(saveDelay, () => unawaited(saveNow()));
  }

  /// Saves to the cloud now (signed in only). New surveys respect the plan's limit.
  Future<void> saveNow({String? name}) {
    _saveTimer?.cancel();
    final running = _saving;
    if (running != null) return running.then((_) => saveNow(name: name));
    final future = _save(name);
    _saving = future;
    return future.whenComplete(() => _saving = null);
  }

  Future<void> _save(String? name) async {
    final userId = _userId;
    if (userId == null) return; // signed out: the survey lives on this phone only
    final s = state;
    // Nothing new to save; and an empty survey never becomes a cloud row (it would use up
    // one of the plan's surveys)
    if (!s.dirty && name == null) return;
    if (s.currentSurveyId == null && s.doc.groups.isEmpty) return;
    if (s.currentSurveyId == null) {
      final limit = surveyLimit(_profile?.isAdmin == true ? Plan.enterprise : _profile?.plan ?? Plan.free);
      if (s.saved.length >= limit) {
        final plan = (_profile?.isAdmin == true ? Plan.enterprise : _profile?.plan ?? Plan.free).value;
        state = state.copyWith(error: () => 'Survey limit reached for "$plan plan" (max : $limit).');
        return;
      }
    }
    state = state.copyWith(syncing: true);
    try {
      final saved = await ref
          .read(surveyBackendProvider)
          .save(userId: userId, id: s.currentSurveyId, name: surveySaveName(s.doc.groups, name), groups: s.doc.groups);
      // Only clean if nothing changed while saving
      final unchanged = identical(state.doc, s.doc);
      state = state.copyWith(
        currentSurveyId: () => saved.id,
        saved: [
          saved,
          for (final x in state.saved)
            if (x.id != saved.id) x,
        ],
        syncing: false,
        dirty: !unchanged,
      );
      if (!unchanged) _scheduleSave();
    } on SurveyException catch (e) {
      state = state.copyWith(syncing: false, error: () => e.message);
    } on Object {
      // Offline or the server said no: kept on the phone, tried again on the next change
      state = state.copyWith(syncing: false, dirty: true);
    }
    unawaited(_persist());
  }

  Future<void> refreshSaved() async {
    final userId = _userId;
    if (userId == null) return;
    try {
      final list = await ref.read(surveyBackendProvider).list(userId);
      state = state.copyWith(saved: list);
      unawaited(_persist());
    } on Object {
      // Offline: keep the list we have
    }
  }

  // --- Plot mode ------------------------------------------------------------------------

  void open() {
    state = state.copyWith(enabled: true);
    unawaited(refreshSaved());
  }

  void close() => state = state.copyWith(enabled: false, selectedPointId: () => null);

  void setStraight(bool straight) {
    state = state.copyWith(straight: straight);
    unawaited(_persist());
  }

  void setAngleStep(int step) {
    state = state.copyWith(angleStep: angleSteps.contains(step) ? step : 0);
    unawaited(_persist());
  }

  void select(String? pointId) => state = state.copyWith(selectedPointId: () => pointId);

  // --- Drawing --------------------------------------------------------------------------

  /// Tap on the map: a new point of the active sheet (straight mode snaps it and sharpens
  /// the corner it turns from). [elevationAt] gives the terrain height of the final spot.
  Future<void> addPointAt(double lng, double lat, Future<double> Function(double lng, double lat) elevationAt) {
    // Taps are handled one after the other: a quick second tap waits for the first point,
    // so the order and the angle snap (which looks at the last point) stay right
    final next = _adding.then((_) => _addPoint(lng, lat, elevationAt));
    _adding = next.catchError((Object _) {});
    return next;
  }

  Future<void> _adding = Future.value();

  Future<void> _addPoint(double lng, double lat, Future<double> Function(double lng, double lat) elevationAt) async {
    if (!state.enabled) return;
    final place = placeNewPoint(
      state.doc.activeGroup,
      (lng, lat),
      straightMode: state.straight,
      angleStep: state.angleStep,
    );
    final elevation = await elevationAt(place.coords.$1, place.coords.$2);
    _edit(
      state.doc.addPoint(lng: place.coords.$1, lat: place.coords.$2, elevation: elevation, sharpenLast: place.straight),
    );
  }

  void movePoint(String groupId, String pointId, {required double lat, required double lng, double? elevation}) =>
      _edit(state.doc.movePoint(groupId, pointId, lat: lat, lng: lng, elevation: elevation));

  void setHandle(String groupId, String pointId, SurveyHandle? handle) =>
      _edit(state.doc.setHandle(groupId, pointId, handle == null || isHandleTooShort(handle) ? null : handle));

  void setCorner(String groupId, String pointId, PointCorner corner) =>
      _edit(state.doc.setCorner(groupId, pointId, corner));

  void setGroupCorners(String groupId, PointCorner corner) => _edit(state.doc.setGroupCorners(groupId, corner));

  void renamePoint(String groupId, String pointId, String name) => _edit(state.doc.renamePoint(groupId, pointId, name));

  void removePoint(String groupId, String pointId) =>
      _edit(state.doc.removePoint(groupId, pointId), selected: state.selectedPointId == pointId ? () => null : null);

  void clearPoints(String groupId) => _edit(state.doc.clearPoints(groupId), selected: () => null);

  void createGroup() => _edit(state.doc.createGroup());

  void deleteGroup(String id) => _edit(state.doc.deleteGroup(id), selected: () => null);

  void setActiveGroup(String id) {
    state = state.copyWith(doc: state.doc.setActive(id), selectedPointId: () => null);
    unawaited(_persist());
  }

  void renameGroup(String id, String name) => _edit(state.doc.renameGroup(id, name));

  // --- Saved surveys --------------------------------------------------------------------

  /// Starts an empty survey (the current one stays saved in the cloud)
  void newSurvey() {
    _saveTimer?.cancel();
    state = state.copyWith(
      doc: const SurveyDoc(),
      currentSurveyId: () => null,
      selectedPointId: () => null,
      dirty: false,
    );
    unawaited(_persist());
  }

  /// Opens a saved survey; returns its bounds so the map can show it
  Future<SurveyDoc?> loadSurvey(String id) async {
    await saveNow(); // do not lose unsaved edits of the current survey
    state = state.copyWith(syncing: true, error: () => null);
    try {
      final (_, groups) = await ref.read(surveyBackendProvider).load(id);
      final doc = SurveyDoc(groups: groups, activeGroupId: groups.isEmpty ? null : groups.first.id);
      state = state.copyWith(
        doc: doc,
        currentSurveyId: () => id,
        enabled: true,
        syncing: false,
        dirty: false,
        selectedPointId: () => null,
      );
      unawaited(_persist());
      return doc;
    } on Object {
      state = state.copyWith(syncing: false, error: () => 'Could not open the survey. Check your connection.');
      return null;
    }
  }

  Future<void> deleteSurvey(String id) async {
    final userId = _userId;
    if (userId == null) return;
    try {
      await ref.read(surveyBackendProvider).delete(id, userId);
      state = state.copyWith(
        saved: [
          for (final s in state.saved)
            if (s.id != id) s,
        ],
        // Deleting the open survey keeps it on screen as a new, unsaved one
        currentSurveyId: () => state.currentSurveyId == id ? null : state.currentSurveyId,
      );
      unawaited(_persist());
    } on Object {
      state = state.copyWith(error: () => 'Could not delete the survey. Check your connection.');
    }
  }

  void clearError() => state = state.copyWith(error: () => null);
}

final navigatorProvider = NotifierProvider<NavigatorController, SurveyNavigatorState>(NavigatorController.new);

/// A survey the map should show (just opened from the saved list); cleared once shown
class ShowSurvey extends Notifier<SurveyDoc?> {
  @override
  SurveyDoc? build() => null;

  void show(SurveyDoc doc) => state = doc;
  void done() => state = null;
}

final showSurveyProvider = NotifierProvider<ShowSurvey, SurveyDoc?>(ShowSurvey.new);
