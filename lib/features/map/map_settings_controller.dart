import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../domain/map/map_settings.dart';

const _prefsKey = 'l360-map-settings';

/// Map settings, kept on the phone between launches (style, exaggeration, DD/DMS)
class MapSettingsController extends Notifier<MapSettings> {
  final _prefs = SharedPreferencesAsync();

  @override
  MapSettings build() {
    unawaited(_load());
    return const MapSettings();
  }

  Future<void> _load() async {
    try {
      final raw = await _prefs.getString(_prefsKey);
      if (raw == null) return;
      final saved = MapSettings.fromJson(jsonDecode(raw) as Map<String, dynamic>);
      // Keep the view the user may already have switched to while loading
      state = saved.copyWith(view: state.view);
    } on Object {
      // Unreadable settings: keep the defaults
    }
  }

  void _update(MapSettings next) {
    state = next;
    unawaited(_prefs.setString(_prefsKey, jsonEncode(next.toJson())).catchError((Object _) {}));
  }

  void setStyle(MapStyle style) => _update(state.copyWith(style: style));
  void setView(MapView view) => _update(state.copyWith(view: view));
  void setExaggeration(double value) =>
      _update(state.copyWith(exaggeration: value.clamp(minExaggeration, maxExaggeration)));
  void setCoordFormat(CoordFormat format) => _update(state.copyWith(coordFormat: format));
  void setShowContours(bool show) => _update(state.copyWith(showContours: show));
  void setContourInterval(double meters) => _update(state.copyWith(contourInterval: meters.clamp(10.0, 500.0)));
  void setContourOpacity(double value) => _update(state.copyWith(contourOpacity: value.clamp(0.0, 1.0)));
  void setShowGrid(bool show) => _update(state.copyWith(showGrid: show));
  void setGridOpacity(double value) => _update(state.copyWith(gridOpacity: value.clamp(0.0, 1.0)));
  void setGridStep(double? degrees) => _update(state.copyWith(gridStep: () => degrees));
}

final mapSettingsProvider = NotifierProvider<MapSettingsController, MapSettings>(MapSettingsController.new);
