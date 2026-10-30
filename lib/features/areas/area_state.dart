import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers.dart';
import '../../data/marked/marked_area_repository.dart';
import '../../domain/geo/spherical.dart';
import '../../domain/marked/area_contours.dart';
import '../../domain/marked/marked_areas.dart';
import '../map/map_tools_state.dart';

// Marked Areas (useMarkedAreaStore.ts): my areas, drawing a shape by tapping its corners,
// the form for a new or edited area, and the focus view that darkens the map outside one.

final areaBackendProvider = Provider<MarkedAreaBackend>(
  (ref) => SupabaseMarkedAreaBackend(ref.watch(supabaseClientProvider)),
);

const maxAreaPoints = 500;

/// The new or edited area being filled in (kept while the shape is drawn)
class AreaForm {
  const AreaForm({this.editingId, this.name = '', this.color = '#d49b22', this.notes = '', this.ring = const []});

  factory AreaForm.of(MarkedArea a) =>
      AreaForm(editingId: a.id, name: a.name, color: a.color, notes: a.notes ?? '', ring: a.ring);

  final String? editingId;
  final String name;
  final String color;
  final String notes;
  final List<LngLat> ring;

  AreaForm copyWith({String? name, String? color, String? notes, List<LngLat>? ring}) => AreaForm(
    editingId: editingId,
    name: name ?? this.name,
    color: color ?? this.color,
    notes: notes ?? this.notes,
    ring: ring ?? this.ring,
  );
}

class AreasState {
  const AreasState({
    this.userId,
    this.panelOpen = false,
    this.areas = const [],
    this.loading = false,
    this.error,
    this.drawing = false,
    this.draft = const [],
    this.form,
    this.focusId,
    this.selectedId,
    this.contourMeta = const {},
    this.shownContours = const {},
  });

  final String? userId;
  final bool panelOpen;
  final List<MarkedArea> areas;
  final bool loading;
  final String? error;
  final bool drawing; // taps on the map add corners
  final List<LngLat> draft;
  final AreaForm? form;
  final String? focusId; // everything outside this area is darkened
  final String? selectedId;
  final Map<String, AreaContourMeta> contourMeta; // areas with contours uploaded on the website
  final Map<String, Map<String, dynamic>> shownContours; // their lines on the map

  /// The contour sets on the map, each with its interval
  List<ContourSet> get contourSets => [
    for (final MapEntry(key: id, value: data) in shownContours.entries)
      (data: data, intervalM: contourMeta[id]?.intervalM),
  ];

  MarkedArea? get focused => areas.where((a) => a.id == focusId).firstOrNull;

  AreasState copyWith({
    bool? panelOpen,
    List<MarkedArea>? areas,
    bool? loading,
    String? Function()? error,
    bool? drawing,
    List<LngLat>? draft,
    AreaForm? Function()? form,
    String? Function()? focusId,
    String? Function()? selectedId,
    Map<String, AreaContourMeta>? contourMeta,
    Map<String, Map<String, dynamic>>? shownContours,
  }) => AreasState(
    userId: userId,
    panelOpen: panelOpen ?? this.panelOpen,
    areas: areas ?? this.areas,
    loading: loading ?? this.loading,
    error: error == null ? this.error : error(),
    drawing: drawing ?? this.drawing,
    draft: draft ?? this.draft,
    form: form == null ? this.form : form(),
    focusId: focusId == null ? this.focusId : focusId(),
    selectedId: selectedId == null ? this.selectedId : selectedId(),
    contourMeta: contourMeta ?? this.contourMeta,
    shownContours: shownContours ?? this.shownContours,
  );
}

final areasProvider = NotifierProvider<AreasController, AreasState>(AreasController.new);

class AreasController extends Notifier<AreasState> {
  @override
  AreasState build() {
    ref.listen(authUserIdProvider, (_, next) {
      if (!next.hasValue) return;
      final id = next.value;
      // After build (the first state is in place), and not once the provider is gone
      unawaited(
        Future(() {
          if (!ref.mounted) return;
          id == null ? reset() : unawaited(init(id));
        }),
      );
    }, fireImmediately: true);
    return const AreasState();
  }

  MarkedAreaBackend get _cloud => ref.read(areaBackendProvider);

  MarkedAreaPolicy get policy {
    final p = ref.read(profileProvider).value;
    return getMarkedAreaPolicy(
      hasUser: state.userId != null,
      subscriptionStatus: p?.plan.value ?? 'Free',
      isAdmin: p?.isAdmin ?? false,
    );
  }

  Future<void> init(String userId) async {
    if (state.userId == userId) return;
    state = AreasState(userId: userId);
    await load();
  }

  void reset() => state = const AreasState();

  Future<void> load() async {
    final userId = state.userId;
    if (userId == null) return;
    state = state.copyWith(loading: true);
    try {
      final (areas, meta) = await (
        _cloud.mine(userId),
        _cloud.contourMeta(userId).catchError((Object _) => const <AreaContourMeta>[]),
      ).wait;
      if (state.userId == userId) {
        state = state.copyWith(areas: areas, contourMeta: {for (final m in meta) m.areaId: m}, error: () => null);
      }
    } on Object catch (e) {
      if (state.userId == userId) state = state.copyWith(error: () => '$e');
    } finally {
      if (state.userId == userId) state = state.copyWith(loading: false);
    }
  }

  void setPanelOpen(bool open) => state = state.copyWith(panelOpen: open);
  void clearError() => state = state.copyWith(error: () => null);
  void select(String? id) => state = state.copyWith(selectedId: () => id);

  // --- Drawing

  /// Starts a new shape, or redraws the form's shape from its corners
  void startDrawing({List<LngLat> from = const []}) =>
      state = state.copyWith(drawing: true, draft: from, focusId: () => null, panelOpen: false);

  void addPoint(LngLat p) {
    if (!state.drawing || state.draft.length >= maxAreaPoints) return;
    state = state.copyWith(draft: [...state.draft, p]);
  }

  void undoPoint() {
    if (state.draft.isEmpty) return;
    state = state.copyWith(draft: state.draft.sublist(0, state.draft.length - 1));
  }

  /// Done: the shape goes into the form (a new one when none is open)
  void finishDrawing() {
    if (state.draft.length < 3) return;
    final form = (state.form ?? AreaForm(color: areaColors.first)).copyWith(ring: state.draft);
    state = state.copyWith(drawing: false, form: () => form, panelOpen: true);
  }

  void cancelDrawing() => state = state.copyWith(drawing: false, draft: const [], panelOpen: true);

  // --- Form

  void newArea() {
    state = state.copyWith(form: () => null, error: () => null);
    startDrawing();
  }

  void edit(MarkedArea a) => state = state.copyWith(form: () => AreaForm.of(a));
  void updateForm(AreaForm f) => state = state.copyWith(form: () => f);
  void closeForm() => state = state.copyWith(form: () => null);

  /// Saves the form; null when saved, else the problem
  Future<String?> save() async {
    final f = state.form;
    if (f == null) return null;
    final problem = areaInputError(name: f.name, ring: f.ring);
    if (problem != null) return problem;
    final input = MarkedAreaInput(name: f.name, color: f.color, notes: f.notes, ring: f.ring);
    try {
      final id = f.editingId;
      final saved = id == null ? await _cloud.create(input) : await _cloud.update(id, input);
      state = state.copyWith(
        areas: id == null ? [saved, ...state.areas] : [for (final a in state.areas) a.id == id ? saved : a],
        form: () => null,
        selectedId: () => saved.id,
        draft: const [],
      );
      return null;
    } on Object catch (e) {
      return '$e';
    }
  }

  Future<void> delete(String id) async {
    await _cloud.delete(id);
    state = state.copyWith(
      areas: state.areas.where((a) => a.id != id).toList(),
      contourMeta: {...state.contourMeta}..remove(id),
      shownContours: {...state.shownContours}..remove(id),
      focusId: state.focusId == id ? () => null : null,
      selectedId: state.selectedId == id ? () => null : null,
    );
  }

  // --- Focus

  /// Darkens the map outside the area and fits it on screen; again to leave
  void focus(String? id) {
    state = state.copyWith(focusId: () => id);
    final a = state.focused;
    if (a != null) ref.read(fitPointsProvider.notifier).go(a.ring);
    // Focusing an area with uploaded contours shows them
    if (id != null && state.contourMeta.containsKey(id)) unawaited(showContours(id).catchError((Object _) {}));
  }

  // --- Contours uploaded on the website

  Future<void> showContours(String id) async {
    if (state.shownContours.containsKey(id) || !state.contourMeta.containsKey(id)) return;
    final data = await _cloud.contours(id);
    if (!state.contourMeta.containsKey(id)) return;
    state = state.copyWith(shownContours: {...state.shownContours, id: data});
  }

  void hideContours(String id) => state = state.copyWith(shownContours: {...state.shownContours}..remove(id));
}
