import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/providers.dart';
import '../../core/theme/app_theme.dart';

/// Home screen. The Mapbox map and the Tools / Map / Terrain sheet arrive in phase 4; until
/// then it shows the account entry point. Like the web, the map works without signing in.
class MapScreen extends ConsumerWidget {
  const MapScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final profile = ref.watch(profileProvider).value;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Landscape 360'),
        actions: [
          IconButton(
            key: const Key('account-button'),
            tooltip: profile == null ? 'Sign in' : 'User Account',
            icon: Icon(profile == null ? Icons.login : Icons.account_circle_outlined),
            onPressed: () => context.push(profile == null ? '/login' : '/account'),
          ),
        ],
      ),
      body: const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.terrain, size: 72, color: L360Colors.forest600),
              SizedBox(height: 12),
              Text('Explore without Limits', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
              SizedBox(height: 8),
              Text('The map arrives in phase 4.', textAlign: TextAlign.center),
            ],
          ),
        ),
      ),
    );
  }
}
