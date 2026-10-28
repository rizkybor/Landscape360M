import 'package:flutter/foundation.dart';
import 'package:go_router/go_router.dart';

import '../features/account/about_screen.dart';
import '../features/account/account_screen.dart';
import '../features/account/delete_account.dart';
import '../features/account/login_screen.dart';
import '../features/account/request_account_screen.dart';
import '../features/map/map_screen.dart';

/// Routes. Account pages need a session ([isSignedIn]); the map and sign-in do not.
GoRouter buildRouter({required bool Function() isSignedIn, Listenable? refresh}) => GoRouter(
  refreshListenable: refresh,
  routes: [
    GoRoute(path: '/', builder: (_, _) => const MapScreen()),
    GoRoute(path: '/login', builder: (_, _) => const LoginScreen()),
    GoRoute(path: '/request-account', builder: (_, _) => const RequestAccountScreen()),
    GoRoute(path: '/about', builder: (_, _) => const AboutScreen()),
    GoRoute(
      path: '/account',
      builder: (_, _) => const AccountScreen(),
      routes: [
        GoRoute(path: 'edit', builder: (_, _) => const EditProfileScreen()),
        GoRoute(path: 'password', builder: (_, _) => const ChangePasswordScreen()),
        GoRoute(path: 'delete', builder: (_, _) => const DeleteAccountScreen()),
      ],
    ),
  ],
  redirect: (_, state) {
    final signedIn = isSignedIn();
    if (!signedIn && state.matchedLocation.startsWith('/account')) return '/login';
    if (signedIn && state.matchedLocation == '/login') return '/account';
    return null;
  },
);
