import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:landscape360/features/map/style_guard.dart';

// Switching the map style: a layer update that lands while the new style loads is dropped
// (everything is shown again once it has loaded); any other error still surfaces

void main() {
  test('"not in style" while the style reloads is dropped', () async {
    await onStyle(
      () async => throw PlatformException(code: '0', message: "Source 'marked-areas-labels' is not in style"),
    );
    await onStyle(() async => throw PlatformException(code: '0', message: "Layer 'route-planner-line' does not exist"));
  });

  test('other errors still fail', () async {
    await expectLater(
      onStyle(() async => throw PlatformException(code: '0', message: 'Invalid GeoJSON')),
      throwsA(isA<PlatformException>()),
    );
    await expectLater(onStyle(() async => throw StateError('x')), throwsStateError);
  });
}
