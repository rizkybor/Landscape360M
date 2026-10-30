import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:landscape360/core/theme/app_theme.dart';
import 'package:landscape360/core/ui/splash.dart';

// The launch screen: the app's name and a loader over the app, then it fades away and
// lets taps through

void main() {
  testWidgets('shows the name and loader, then fades into the app', (tester) async {
    var taps = 0;
    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppTheme(),
        home: SplashGate(
          hold: const Duration(milliseconds: 500),
          child: Scaffold(
            body: Center(
              child: TextButton(onPressed: () => taps++, child: const Text('map')),
            ),
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.byKey(const Key('splash')), findsOneWidget);
    expect(find.byKey(const Key('splash-loader')), findsOneWidget);
    expect(find.text('Explore without Limits'), findsOneWidget);

    await tester.pump(const Duration(milliseconds: 600));
    await tester.pump(const Duration(milliseconds: 600));
    expect(find.byKey(const Key('splash')), findsNothing, reason: 'gone after its moment');
    await tester.tap(find.text('map'));
    expect(taps, 1);
  });
}
