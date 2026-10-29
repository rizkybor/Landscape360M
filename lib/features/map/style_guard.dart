import 'package:flutter/services.dart';

// While another map style loads (Streets / Outdoors / Satellite), the app's own sources and
// layers are briefly gone: a change that lands in that moment would fail with "Source … is
// not in style". It is dropped instead; once the new style has loaded every layer is added
// and shown again with the latest data (_onStyleLoaded in map_screen.dart).

final _missing = RegExp(r'not in style|does not exist|not found', caseSensitive: false);

/// Runs [change] on the map's style, ignoring only "the style is being replaced" errors
Future<void> onStyle(Future<void> Function() change) async {
  try {
    await change();
  } on PlatformException catch (e) {
    if (!_missing.hasMatch('${e.message}')) rethrow;
  }
}
