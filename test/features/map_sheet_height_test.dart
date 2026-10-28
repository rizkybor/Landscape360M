import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:landscape360/core/config/app_config.dart';
import 'package:landscape360/core/providers.dart';
import 'package:landscape360/core/theme/app_theme.dart';
import 'package:landscape360/core/ui/widgets.dart';
import 'package:landscape360/features/map/map_screen.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

// The sheet opens only as far as its content: no empty space below a short section
void main() {
  testWidgets('the fully opened sheet ends at its content, also after switching to a shorter section', (tester) async {
    SharedPreferencesAsyncPlatform.instance = InMemorySharedPreferencesAsync.empty();
    tester.view.physicalSize = const Size(1179, 2556);
    tester.view.devicePixelRatio = 3;
    tester.view.padding = const FakeViewPadding(top: 59 * 3, bottom: 34 * 3);
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          appConfigProvider.overrideWithValue(
            const AppConfig(
              flavor: 'dev',
              supabaseUrl: 'https://x.supabase.co',
              supabaseAnonKey: 'sb_publishable_x',
              mapboxPublicToken: '',
              apiBaseUrl: 'https://landscape360.jcdigital.co.id',
            ),
          ),
          authUserIdProvider.overrideWith((ref) => Stream.value(null)),
          profileProvider.overrideWith((ref) async => null),
        ],
        child: MaterialApp(theme: buildAppTheme(), home: const MapScreen()),
      ),
    );
    await tester.pumpAndSettle();
    const screen = 2556 / 3;

    // Gap between the last line of the footer and the bottom of the screen
    double gapBelowFooter() => screen - tester.getBottomLeft(find.textContaining('Powered by')).dy;
    double bodyOpacity() => tester
        .widget<Opacity>(find.ancestor(of: find.byType(Divider).first, matching: find.byType(Opacity)).first)
        .opacity;

    // Closed: only the grabber, header and section tabs show, right above the home indicator
    final tabsBottom = tester.getBottomLeft(find.byKey(const Key('section-tools'))).dy;
    expect(screen - 34 - tabsBottom, inInclusiveRange(8, 20)); // tab padding only
    expect(bodyOpacity(), 0);

    await tester.drag(find.byKey(const Key('section-tools')), const Offset(0, -2000));
    await tester.pumpAndSettle();
    expect(gapBelowFooter(), lessThan(80)); // footer padding + home indicator, not empty space
    final toolsTop = tester.getTopLeft(find.byKey(const Key('section-tools'))).dy;
    expect(toolsTop, greaterThan(screen * 0.3)); // the map stays visible above a short sheet
    expect(bodyOpacity(), 1);

    // Dragging further up does not pull empty space into view
    await tester.drag(find.byKey(const Key('section-tools')), const Offset(0, -600));
    await tester.pump(const Duration(milliseconds: 50));
    expect(gapBelowFooter(), lessThan(80));
    await tester.pumpAndSettle();

    // Closing hides the body again; tapping a tab while closed opens the sheet
    await tester.drag(find.byKey(const Key('section-tools')), const Offset(0, 2000));
    await tester.pumpAndSettle();
    expect(bodyOpacity(), 0);
    await tester.tap(find.byKey(const Key('section-terrain')));
    await tester.pumpAndSettle();
    expect(bodyOpacity(), 1);
    expect(gapBelowFooter(), lessThan(80));

    // Closed again, a drag on the title (not a tab) opens the sheet; a tap on the grabber closes it
    await tester.tap(find.byKey(const Key('sheet-grabber')));
    await tester.pumpAndSettle();
    expect(bodyOpacity(), 0);
    await tester.fling(find.byType(BrandName), const Offset(0, -300), 1500);
    await tester.pumpAndSettle();
    expect(bodyOpacity(), 1);
    expect(gapBelowFooter(), lessThan(40)); // credits sit just above the home indicator
    await tester.tap(find.byKey(const Key('sheet-grabber')));
    await tester.pumpAndSettle();
    expect(bodyOpacity(), 0);
    await tester.drag(find.text('Explore without Limits'), const Offset(0, -400));
    await tester.pumpAndSettle();
    expect(bodyOpacity(), 1);

    await tester.tap(find.byKey(const Key('section-map')));
    await tester.pumpAndSettle();
    await tester.drag(find.byKey(const Key('section-map')), const Offset(0, -2000));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('section-terrain')));
    await tester.pumpAndSettle();
    expect(gapBelowFooter(), lessThan(80));
  });

  testWidgets('every section shows at its own height, and the tabs never scroll away', (tester) async {
    SharedPreferencesAsyncPlatform.instance = InMemorySharedPreferencesAsync.empty();
    tester.view.physicalSize = const Size(1170, 2532); // iPhone 13
    tester.view.devicePixelRatio = 3;
    tester.view.padding = const FakeViewPadding(top: 47 * 3, bottom: 34 * 3);
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          appConfigProvider.overrideWithValue(
            const AppConfig(
              flavor: 'dev',
              supabaseUrl: 'https://x.supabase.co',
              supabaseAnonKey: 'sb_publishable_x',
              mapboxPublicToken: '',
              apiBaseUrl: 'https://landscape360.jcdigital.co.id',
            ),
          ),
          authUserIdProvider.overrideWith((ref) => Stream.value(null)),
          profileProvider.overrideWith((ref) async => null),
        ],
        child: MaterialApp(theme: buildAppTheme(), home: const MapScreen()),
      ),
    );
    await tester.pumpAndSettle();
    const screen = 2532 / 3;
    double gap() => screen - tester.getBottomLeft(find.textContaining('Powered by')).dy;
    Future<void> tab(String s) async {
      await tester.tap(find.byKey(Key('section-$s')));
      await tester.pumpAndSettle();
    }

    double top() => tester.getTopLeft(find.byKey(const Key('section-tools'))).dy;
    // Every section ends at its own height, the same way whatever the order: Tools and Map
    // fit their content (no white space), Terrain stops at 90% of the screen and scrolls
    const terrainTop = screen * 0.1;
    Future<void> fitsThrough(List<String> sections) async {
      for (final s in sections) {
        await tab(s);
        if (s == 'terrain') {
          expect(top(), closeTo(terrainTop + 140, 30), reason: 'Terrain at 90%');
        } else {
          expect(gap(), inInclusiveRange(0, 80), reason: '$s fits its content');
        }
      }
    }

    await tester.drag(find.byKey(const Key('section-tools')), const Offset(0, -2000));
    await tester.pumpAndSettle();
    expect(gap(), inInclusiveRange(0, 80));
    await fitsThrough(['map', 'terrain', 'tools', 'terrain', 'map', 'tools', 'map']);
    final mapTop = top();
    await fitsThrough(['tools', 'map']);
    expect(top(), mapTop, reason: 'the same section always gets the same height');

    // Terrain to Tools slides down (no cut to the new height in one frame)
    await tab('terrain');
    final from = top();
    await tester.tap(find.byKey(const Key('section-tools')));
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 16)); // frames, as on screen
    }
    final mid = top();
    await tester.pumpAndSettle();
    expect(mid, greaterThan(from + 5), reason: 'moving down');
    expect(mid, lessThan(top() - 5), reason: 'not there yet: it slides');

    // One indicator slides between the tabs (no per-tab fade that made the bar blink)
    expect(find.byKey(const Key('section-indicator')), findsOneWidget);

    // Closed, a tab opens the sheet to that section's height
    for (final s in ['map', 'tools', 'terrain']) {
      await tester.tap(find.byKey(const Key('sheet-grabber')));
      await tester.pumpAndSettle();
      await fitsThrough([s]);
    }

    // Terrain scrolls under the tabs, which stay on screen
    await tester.drag(find.text('CONTOURS CONFIG').hitTestable().first, const Offset(0, -400), warnIfMissed: false);
    await tester.pumpAndSettle();
    expect(gap(), inInclusiveRange(0, 80), reason: 'scrolled to the end');
    expect(find.byKey(const Key('section-tools')).hitTestable(), findsOneWidget, reason: 'tabs still there');
    await fitsThrough(['tools']);
    expect(find.text('Navigator').hitTestable(), findsOneWidget);

    // In 3D, switching Contours off hides their settings: the sheet follows, no white space
    await tab('map');
    await tester.tap(find.byKey(const Key('view-3d')));
    await tester.pumpAndSettle();
    await tab('terrain');
    await tester.pump(const Duration(seconds: 2)); // well after the switch has settled
    final tall = top();
    await tester.tap(find.byKey(const Key('contours-toggle')));
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    final sliding = top();
    await tester.pumpAndSettle();
    expect(find.text('Opacity Contours'), findsNothing);
    expect(gap(), inInclusiveRange(0, 80), reason: 'fits the shorter Terrain, no white space');
    expect(sliding, greaterThan(tall + 5), reason: 'moving down');
    expect(sliding, lessThan(top() - 5), reason: 'it slides, no jump');
    await tester.tap(find.byKey(const Key('contours-toggle')));
    await tester.pumpAndSettle();
    expect(gap(), lessThanOrEqualTo(80));

    // Partly open (dragged down a little): a switch still fits the section
    await tester.drag(find.byKey(const Key('section-tools')), const Offset(0, 120));
    await tester.pump(const Duration(milliseconds: 30));
    await tester.pumpAndSettle();
    await fitsThrough(['map', 'terrain', 'tools']);
    expect(tester.takeException(), isNull);
  });
}
