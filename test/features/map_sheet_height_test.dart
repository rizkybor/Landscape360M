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

  testWidgets('switching sections fits the sheet to each, and the tabs never scroll away', (tester) async {
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

    // Open on Tools, then a taller section: the sheet keeps its height and the section
    // scrolls; back to the shorter one, the sheet comes down to it (no empty space)
    await tester.drag(find.byKey(const Key('section-tools')), const Offset(0, -2000));
    await tester.pumpAndSettle();
    expect(gap(), inInclusiveRange(0, 80));
    final openTop = tester.getTopLeft(find.byKey(const Key('section-tools'))).dy;
    await tab('map');
    expect(tester.getTopLeft(find.byKey(const Key('section-tools'))).dy, openTop, reason: 'same height');
    await tab('tools');
    expect(gap(), inInclusiveRange(0, 80), reason: 'back to the shorter one, no empty space');

    // One indicator slides between the tabs (no per-tab fade that made the bar blink)
    expect(find.byKey(const Key('section-indicator')), findsOneWidget);

    // Closed, a tab opens the sheet to that section's height (was the previous one's)
    for (final s in ['map', 'tools']) {
      await tester.tap(find.byKey(const Key('sheet-grabber')));
      await tester.pumpAndSettle();
      await tab(s);
      expect(gap(), inInclusiveRange(0, 80), reason: 'opened to fit $s');
    }

    // Terrain is taller than the 90% limit: it scrolls, and the tabs stay on screen
    await tab('terrain');
    await tester.drag(find.text('CONTOURS CONFIG').hitTestable().first, const Offset(0, -400), warnIfMissed: false);
    await tester.pumpAndSettle();
    expect(gap(), inInclusiveRange(0, 80), reason: 'scrolled to the end');
    expect(find.byKey(const Key('section-tools')).hitTestable(), findsOneWidget, reason: 'tabs still there');
    await tab('tools');
    expect(find.text('Navigator').hitTestable(), findsOneWidget);
    expect(gap(), inInclusiveRange(0, 80));
    expect(tester.takeException(), isNull);
  });
}
