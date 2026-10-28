import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'core/config/app_config.dart';
import 'core/providers.dart';
import 'core/router.dart';
import 'core/theme/app_theme.dart';
import 'data/supabase/secure_session_storage.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final config = AppConfig.fromEnvironment();
  final problems = config.problems();
  if (problems.isNotEmpty) {
    runApp(ConfigErrorApp(problems: problems));
    return;
  }

  await Supabase.initialize(
    url: config.supabaseUrl,
    publishableKey: config.supabaseAnonKey,
    authOptions: FlutterAuthClientOptions(
      localStorage: SecureSessionStorage(),
      // Email + password only: incoming links are share links, never auth callbacks
      detectSessionInUri: false,
    ),
  );

  runApp(ProviderScope(overrides: [appConfigProvider.overrideWithValue(config)], child: const Landscape360App()));
}

class Landscape360App extends StatefulWidget {
  const Landscape360App({super.key});

  @override
  State<Landscape360App> createState() => _Landscape360AppState();
}

class _Landscape360AppState extends State<Landscape360App> {
  final _authChanges = _AuthChanges(Supabase.instance.client.auth);
  late final _router = buildRouter(
    isSignedIn: () => Supabase.instance.client.auth.currentSession != null,
    refresh: _authChanges,
  );

  @override
  void dispose() {
    _authChanges.dispose();
    _router.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => MaterialApp.router(
    title: 'Landscape 360',
    theme: buildAppTheme(),
    routerConfig: _router,
    debugShowCheckedModeBanner: false,
  );
}

/// Re-runs the router's redirect when the user signs in or out
class _AuthChanges extends ChangeNotifier {
  _AuthChanges(GoTrueClient auth) {
    _sub = auth.onAuthStateChange.listen((_) => notifyListeners());
  }

  late final StreamSubscription<AuthState> _sub;

  @override
  void dispose() {
    _sub.cancel();
    super.dispose();
  }
}

/// Shown instead of the app when the build was made with a wrong or unsafe configuration
class ConfigErrorApp extends StatelessWidget {
  const ConfigErrorApp({super.key, required this.problems});

  final List<String> problems;

  @override
  Widget build(BuildContext context) => MaterialApp(
    home: Scaffold(
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(24),
          children: [
            const Text('Configuration error', style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
            const SizedBox(height: 12),
            for (final p in problems) Text('• $p'),
            const SizedBox(height: 12),
            const Text('Build with --dart-define-from-file=config/<flavor>.json (see config/*.json.example).'),
          ],
        ),
      ),
    ),
  );
}
