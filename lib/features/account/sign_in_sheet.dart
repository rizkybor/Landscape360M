import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../core/theme/app_theme.dart';

// One sheet for every tool that needs an account, opened from its tile while signed out
// (the same look as the GPS sheet): what the tool is, why signing in, Sign in / Request.

Future<void> showSignInSheet(BuildContext context, {required String title, required String reason}) {
  final router = GoRouter.maybeOf(context);
  return showModalBottomSheet<void>(
    context: context,
    useSafeArea: true,
    builder: (context) => Padding(
      key: const Key('sign-in-sheet'),
      padding: const EdgeInsets.fromLTRB(L360.gutter, 4, L360.gutter, 16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(title, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
          const SizedBox(height: 14),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: L360Colors.sand50,
              borderRadius: BorderRadius.circular(L360.radiusSmall),
              border: Border.all(color: L360Colors.sand200),
            ),
            child: Row(
              children: [
                const Icon(Icons.lock_outline, size: 18, color: L360Colors.sand600),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(reason, style: const TextStyle(fontSize: 13, color: L360Colors.sand700)),
                ),
              ],
            ),
          ),
          const SizedBox(height: 14),
          FilledButton(
            key: const Key('sign-in-sheet-login'),
            onPressed: () {
              Navigator.pop(context);
              router?.push('/login');
            },
            child: const Text('Sign in'),
          ),
          TextButton(
            onPressed: () {
              Navigator.pop(context);
              router?.push('/request-account');
            },
            child: const Text('Request an account'),
          ),
        ],
      ),
    ),
  );
}
