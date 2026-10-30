import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/providers.dart';
import '../../data/classic/classic_links.dart';
import '../../domain/classic/classic_solve.dart';
import '../../domain/classic/field_work.dart';
import '../../domain/geo/spherical.dart' show LngLat;

// Classic (useClassicStore.ts): resection / intersection practice with typed degrees. Each
// mode keeps its own Field Works (separate exercises); the open one is drawn on the map.
// Everything is remembered on this phone. A shared Field Work is saved to its link a moment
// after typing stops, so the link always shows the latest version.

final classicLinksProvider = Provider<ClassicLinks>((ref) => SupabaseClassicLinks(ref.watch(supabaseClientProvider)));

final classicPrefsProvider = Provider<SharedPreferencesAsync>((ref) => SharedPreferencesAsync());

/// Wait after the last change before a shared Field Work is saved to its link
final classicShareDelayProvider = Provider<Duration>((ref) => const Duration(milliseconds: 1200));

const classicPrefsKey = 'l360-classic';

/// What "Pick on map" places: a sighting's position, or your position (resection)
const pickOrigin = -1;

enum ShareStatus { saving, saved, error }

class ClassicState {
  const ClassicState({
    this.panelOpen = false,
    this.minimized = false,
    this.mode = ClassicMode.resection,
    required this.fieldWorks,
    required this.active,
    this.declination = '0',
    this.picking,
    this.viewing,
    this.shareStatus,
    this.shareError,
  });

  factory ClassicState.fresh() {
    final r = FieldWork(id: _newId(), name: 'Field Work 1');
    final i = FieldWork(id: _newId(), name: 'Field Work 1');
    return ClassicState(
      fieldWorks: {
        ClassicMode.resection: [r],
        ClassicMode.intersection: [i],
      },
      active: {ClassicMode.resection: r.id, ClassicMode.intersection: i.id},
    );
  }

  final bool panelOpen;
  final bool minimized; // only the panel's header shows, the map is in view
  final ClassicMode mode;
  final Map<ClassicMode, List<FieldWork>> fieldWorks;
  final Map<ClassicMode, String> active;
  final String declination; // degrees, east positive, as typed
  final int? picking; // sighting index, or pickOrigin
  final ViewedFieldWork? viewing; // a shared Field Work, read only
  final ShareStatus? shareStatus;
  final String? shareError;

  List<FieldWork> get modeFieldWorks => fieldWorks[mode]!;
  FieldWork get fieldWork => modeFieldWorks.firstWhere((f) => f.id == active[mode], orElse: () => modeFieldWorks.first);
  FieldWorkData get data => fieldWork.data;

  /// What the map and panel show: the shared Field Work being viewed, or the open one
  ClassicSolution get solution {
    final v = viewing;
    return v == null
        ? solveClassic(mode: mode, sightings: data.sightings, origin: data.origin, declination: declination)
        : solveClassic(mode: v.mode, sightings: v.data.sightings, origin: v.data.origin, declination: v.declination);
  }

  ClassicState copyWith({
    bool? panelOpen,
    bool? minimized,
    ClassicMode? mode,
    Map<ClassicMode, List<FieldWork>>? fieldWorks,
    Map<ClassicMode, String>? active,
    String? declination,
    int? Function()? picking,
    ViewedFieldWork? Function()? viewing,
    ShareStatus? Function()? shareStatus,
    String? Function()? shareError,
  }) => ClassicState(
    panelOpen: panelOpen ?? this.panelOpen,
    minimized: minimized ?? this.minimized,
    mode: mode ?? this.mode,
    fieldWorks: fieldWorks ?? this.fieldWorks,
    active: active ?? this.active,
    declination: declination ?? this.declination,
    picking: picking == null ? this.picking : picking(),
    viewing: viewing == null ? this.viewing : viewing(),
    shareStatus: shareStatus == null ? this.shareStatus : shareStatus(),
    shareError: shareError == null ? this.shareError : shareError(),
  );

  Map<String, Object> toJson() => {
    'mode': mode.name,
    'declination': declination,
    'fieldWorks': {
      for (final MapEntry(:key, :value) in fieldWorks.entries) key.name: [for (final f in value) f.toJson()],
    },
    'activeFieldWork': {for (final MapEntry(:key, :value) in active.entries) key.name: value},
  };

  static ClassicState? fromJson(Map<String, dynamic> j) {
    final lists = <ClassicMode, List<FieldWork>>{};
    final raw = j['fieldWorks'] as Map? ?? const {};
    for (final m in ClassicMode.values) {
      final list = [
        for (final f in (raw[m.name] as List? ?? const []).whereType<Map<dynamic, dynamic>>())
          FieldWork.fromJson(Map<String, dynamic>.from(f)),
      ];
      if (list.isEmpty) return null;
      lists[m] = list;
    }
    final act = j['activeFieldWork'] as Map? ?? const {};
    return ClassicState(
      mode: ClassicMode.parse(j['mode']),
      declination: '${j['declination'] ?? '0'}',
      fieldWorks: lists,
      active: {for (final m in ClassicMode.values) m: '${act[m.name] ?? lists[m]!.first.id}'},
    );
  }
}

final _random = math.Random();
String _newId() => List.generate(8, (_) => 'abcdefghijklmnopqrstuvwxyz0123456789'[_random.nextInt(36)]).join();

final classicProvider = NotifierProvider<ClassicController, ClassicState>(ClassicController.new);

class ClassicController extends Notifier<ClassicState> {
  Timer? _persist;
  Timer? _share;

  @override
  ClassicState build() {
    ref.onDispose(() {
      _persist?.cancel();
      _share?.cancel();
    });
    unawaited(Future(_restore));
    return ClassicState.fresh();
  }

  SharedPreferencesAsync get _prefs => ref.read(classicPrefsProvider);

  Future<void> _restore() async {
    try {
      final raw = await _prefs.getString(classicPrefsKey);
      if (raw == null || !ref.mounted) return;
      final restored = ClassicState.fromJson(jsonDecode(raw) as Map<String, dynamic>);
      if (restored != null) state = restored.copyWith(panelOpen: state.panelOpen, viewing: () => state.viewing);
    } on Object {
      // Unreadable: start fresh
    }
  }

  // Remembered on the phone (the panel, a pick or a viewed link are not)
  void _save() {
    _persist?.cancel();
    _persist = Timer(const Duration(milliseconds: 300), () {
      if (ref.mounted) unawaited(_prefs.setString(classicPrefsKey, jsonEncode(state.toJson())));
    });
  }

  /// Field Works per mode for this account (null: no limit)
  int? get limit {
    final p = ref.read(profileProvider).value;
    return fieldWorkLimit(
      hasUser: p != null,
      subscriptionStatus: p?.plan.value ?? 'Free',
      isAdmin: p?.isAdmin ?? false,
    );
  }

  bool get canAddFieldWork {
    final l = limit;
    return l == null || state.modeFieldWorks.length < l;
  }

  // --- Panel and mode

  void setPanelOpen(bool open) => state = state.copyWith(panelOpen: open, minimized: false, picking: () => null);

  void setMinimized(bool minimized) => state = state.copyWith(minimized: minimized);

  void setMode(ClassicMode mode) {
    if (state.mode == mode) return;
    state = state.copyWith(mode: mode, picking: () => null);
    _save();
  }

  // --- The open Field Work

  void _edit(FieldWorkData Function(FieldWorkData d) change) {
    final fw = state.fieldWork;
    _replace(fw.copyWith(data: change(fw.data)));
  }

  void _replace(FieldWork fw) {
    state = state.copyWith(
      fieldWorks: {
        ...state.fieldWorks,
        state.mode: [for (final f in state.modeFieldWorks) f.id == fw.id ? fw : f],
      },
    );
    _save();
    _syncShare();
  }

  FieldWorkData _with(
    FieldWorkData d, {
    List<Sighting>? sightings,
    PointInput? origin,
    Map<String, double>? lineLengths,
  }) => FieldWorkData(
    sightings: sightings ?? d.sightings,
    origin: origin ?? d.origin,
    lineLengths: lineLengths ?? d.lineLengths,
  );

  void updateSighting(int index, Sighting Function(Sighting s) change) =>
      _edit((d) => _with(d, sightings: [for (final (i, s) in d.sightings.indexed) i == index ? change(s) : s]));

  void setAzimuth(int index, String azimuth) => updateSighting(index, (s) => s.copyWith(azimuth: azimuth));
  void setBack(int index, String back) => updateSighting(index, (s) => s.copyWith(back: back));
  void setSightingPoint(int index, PointInput point) => updateSighting(index, (s) => s.copyWith(point: point));
  void checkAzimuth(int index) => updateSighting(index, (s) => s.copyWith(azChecks: s.azChecks + 1));
  void checkBack(int index) => updateSighting(index, (s) => s.copyWith(backChecks: s.backChecks + 1));

  void addSighting() {
    if (state.data.sightings.length >= maxSightings) return;
    _edit((d) => _with(d, sightings: [...d.sightings, const Sighting()]));
  }

  /// The lines after it move up a letter, so hand-set lengths start again
  void removeSighting(int index) {
    if (state.data.sightings.length <= minSightings) return;
    state = state.copyWith(picking: () => null);
    _edit(
      (d) => _with(
        d,
        sightings: [
          for (final (i, s) in d.sightings.indexed)
            if (i != index) s,
        ],
        lineLengths: const {},
      ),
    );
  }

  void setOrigin(PointInput origin) => _edit((d) => _with(d, origin: origin));
  void clearOrigin() => setOrigin(const PointInput());

  void startPicking(int target) => state = state.copyWith(picking: () => target);
  void stopPicking() => state = state.copyWith(picking: () => null);

  /// A tap on the map while picking places the point
  void placePicked(LngLat p) {
    final target = state.picking;
    if (target == null) return;
    state = state.copyWith(picking: () => null);
    target == pickOrigin ? setOrigin(PointInput.of(p)) : setSightingPoint(target, PointInput.of(p));
  }

  void setLineLength(String key, double metres) => _edit((d) => _with(d, lineLengths: {...d.lineLengths, key: metres}));
  void resetLineLengths() => _edit((d) => _with(d, lineLengths: const {}));

  void setDeclination(String value) {
    state = state.copyWith(declination: value);
    _save();
    _syncShare();
  }

  /// Empties the open Field Work
  void resetExercise() {
    state = state.copyWith(picking: () => null);
    _edit((_) => const FieldWorkData());
  }

  // --- Field Works

  void addFieldWork() {
    if (!canAddFieldWork) return;
    final created = FieldWork(id: _newId(), name: nextFieldWorkName(state.modeFieldWorks));
    state = state.copyWith(
      fieldWorks: {
        ...state.fieldWorks,
        state.mode: [...state.modeFieldWorks, created],
      },
      active: {...state.active, state.mode: created.id},
      picking: () => null,
      shareStatus: () => null,
    );
    _save();
  }

  void selectFieldWork(String id) {
    if (id == state.active[state.mode] || !state.modeFieldWorks.any((f) => f.id == id)) return;
    state = state.copyWith(active: {...state.active, state.mode: id}, picking: () => null, shareStatus: () => null);
    _save();
  }

  void renameFieldWork(String id, String name) {
    final fw = state.modeFieldWorks.firstWhere((f) => f.id == id);
    final trimmed = name.trim();
    _replace(fw.copyWith(name: trimmed.isEmpty ? fw.name : trimmed.substring(0, math.min(40, trimmed.length))));
  }

  /// The last one is emptied instead: there is always a Field Work to work in
  Future<void> deleteFieldWork(String id) async {
    final list = state.modeFieldWorks;
    final fw = list.firstWhere((f) => f.id == id);
    if (list.length <= 1) {
      _replace(fw.copyWith(data: const FieldWorkData()));
      return;
    }
    final token = fw.shareToken;
    if (token != null) unawaited(ref.read(classicLinksProvider).revoke(token).catchError((Object _) {}));
    final index = list.indexWhere((f) => f.id == id);
    final rest = [
      for (final f in list)
        if (f.id != id) f,
    ];
    final next = id == state.active[state.mode] ? rest[math.min(index, rest.length - 1)].id : state.active[state.mode]!;
    state = state.copyWith(
      fieldWorks: {...state.fieldWorks, state.mode: rest},
      active: {...state.active, state.mode: next},
      picking: () => null,
      shareStatus: () => null,
    );
    _save();
  }

  // --- Sharing (every signed-in account)

  Future<void> startSharing() async {
    if (ref.read(authUserIdProvider).value == null) return;
    final fw = state.fieldWork;
    state = state.copyWith(shareStatus: () => ShareStatus.saving, shareError: () => null);
    try {
      final token = await ref
          .read(classicLinksProvider)
          .save(token: null, mode: state.mode, name: fw.name, data: fw.data, declination: state.declination);
      _setToken(fw.id, token);
      state = state.copyWith(shareStatus: () => ShareStatus.saved);
    } on Object catch (e) {
      state = state.copyWith(shareStatus: () => ShareStatus.error, shareError: () => '$e');
    }
  }

  Future<void> stopSharing() async {
    final fw = state.fieldWork;
    final token = fw.shareToken;
    if (token == null) return;
    _share?.cancel();
    await ref.read(classicLinksProvider).revoke(token).catchError((Object _) {});
    _setToken(fw.id, null);
    state = state.copyWith(shareStatus: () => null);
  }

  void _setToken(String id, String? token) {
    final mode = state.mode;
    state = state.copyWith(
      fieldWorks: {
        ...state.fieldWorks,
        mode: [for (final f in state.fieldWorks[mode]!) f.id == id ? f.copyWith(shareToken: () => token) : f],
      },
    );
    _save();
  }

  // The link always shows the latest version: saved a moment after typing stops
  void _syncShare() {
    final fw = state.fieldWork;
    final token = fw.shareToken;
    if (token == null || ref.read(authUserIdProvider).value == null) return;
    _share?.cancel();
    _share = Timer(ref.read(classicShareDelayProvider), () async {
      if (!ref.mounted) return;
      final mode = state.mode;
      final now = state.fieldWorks[mode]!.firstWhere((f) => f.id == fw.id, orElse: () => fw);
      state = state.copyWith(shareStatus: () => ShareStatus.saving, shareError: () => null);
      try {
        final saved = await ref
            .read(classicLinksProvider)
            .save(token: token, mode: mode, name: now.name, data: now.data, declination: state.declination);
        // A link turned off elsewhere comes back as a new one
        if (saved != token) _setToken(fw.id, saved);
        state = state.copyWith(shareStatus: () => ShareStatus.saved);
      } on Object catch (e) {
        state = state.copyWith(shareStatus: () => ShareStatus.error, shareError: () => '$e');
      }
    });
  }

  // --- A shared Field Work opened from its link (read only)

  void view(ViewedFieldWork viewing) =>
      state = state.copyWith(viewing: () => viewing, panelOpen: true, picking: () => null);

  void closeViewing() => state = state.copyWith(viewing: () => null);
}
