import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers.dart';
import '../../core/theme/app_theme.dart';
import '../../core/ui/widgets.dart';
import '../../data/account/account_repository.dart';
import '../../data/account/biometric_login.dart';
import 'biometric_state.dart';

// The Face ID pieces of Sign in and User Account. Nothing shows on phones without it.

IconData biometricIcon(BiometricKind? kind) => kind == BiometricKind.fingerprint ? Icons.fingerprint : Icons.face;

/// After a password sign-in: asks once per account whether to use Face ID next time
Future<void> offerBiometric(BuildContext context, WidgetRef ref, String email, String password) async {
  final ctrl = ref.read(biometricProvider.notifier);
  if (!await ctrl.shouldOffer(email) || !context.mounted) return;
  await ctrl.markOffered(email);
  final s = ref.read(biometricProvider);
  if (!context.mounted) return;
  final yes = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog.adaptive(
      icon: Icon(biometricIcon(s.kind), size: 36, color: L360Colors.forest500),
      title: Text('Use ${s.label} to sign in?'),
      content: Text(
        'Next time, sign in with ${s.label} instead of typing your password. '
        'Your password stays on this phone only. You can switch it off in User Account.',
      ),
      actions: [
        TextButton(
          key: const Key('biometric-offer-no'),
          onPressed: () => Navigator.pop(context, false),
          child: const Text('Not now'),
        ),
        TextButton(
          key: const Key('biometric-offer-yes'),
          onPressed: () => Navigator.pop(context, true),
          child: Text('Use ${s.label}'),
        ),
      ],
    ),
  );
  if (yes == true) await ctrl.enable(email, password);
}

/// "Sign in with Face ID" on the Sign in screen, when it is on for an account on this phone
class BiometricSignInButton extends ConsumerWidget {
  const BiometricSignInButton({required this.busy, required this.onPressed, super.key});

  final bool busy;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(biometricProvider);
    if (!s.enabled) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: OutlinedButton.icon(
        key: const Key('login-biometric'),
        onPressed: busy ? null : onPressed,
        icon: Icon(biometricIcon(s.kind), size: 22),
        label: Text('Sign in with ${s.label}', overflow: TextOverflow.ellipsis),
      ),
    );
  }
}

/// The switch in User Account settings; switching on asks for the password first
class BiometricTile extends ConsumerWidget {
  const BiometricTile({required this.email, super.key});

  final String email;

  Future<void> _switchOn(BuildContext context, WidgetRef ref) async {
    final label = ref.read(biometricProvider).label;
    final password = await showDialog<String>(
      context: context,
      builder: (_) => _PasswordDialog(label: label),
    );
    if (password == null) return;
    final ok = await ref.read(biometricProvider.notifier).enable(email, password);
    if (!ok && context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$label was not switched on.')));
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(biometricProvider);
    if (!s.available) return const SizedBox.shrink();
    final on = s.email == email.trim().toLowerCase();
    return SwitchListTile.adaptive(
      key: const Key('account-biometric'),
      secondary: TileIcon(biometricIcon(s.kind)),
      title: Text('Sign in with ${s.label}'),
      subtitle: Text(on ? 'On for this account' : 'Without typing your password'),
      value: on,
      onChanged: (v) => v ? _switchOn(context, ref) : ref.read(biometricProvider.notifier).disable(),
    );
  }
}

class _PasswordDialog extends ConsumerStatefulWidget {
  const _PasswordDialog({required this.label});

  final String label;

  @override
  ConsumerState<_PasswordDialog> createState() => _PasswordDialogState();
}

class _PasswordDialogState extends ConsumerState<_PasswordDialog> {
  final _password = TextEditingController();
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _password.dispose();
    super.dispose();
  }

  Future<void> _confirm() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await ref.read(accountRepositoryProvider).checkPassword(_password.text);
      if (mounted) Navigator.pop(context, _password.text);
    } on AccountException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } on Object {
      if (mounted) setState(() => _error = 'Could not check the password. Check your connection.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text('Switch on ${widget.label}'),
    content: Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Text('Enter your password. It is kept on this phone only, opened by your face or finger.'),
        const SizedBox(height: 12),
        TextField(
          key: const Key('biometric-password'),
          controller: _password,
          obscureText: true,
          autofocus: true,
          autofillHints: const [AutofillHints.password],
          decoration: const InputDecoration(labelText: 'Password'),
          onSubmitted: (_) => _busy ? null : _confirm(),
        ),
        if (_error != null) ...[const SizedBox(height: 12), ErrorBanner(_error!)],
      ],
    ),
    actions: [
      TextButton(onPressed: _busy ? null : () => Navigator.pop(context), child: const Text('Cancel')),
      TextButton(
        key: const Key('biometric-password-ok'),
        onPressed: _busy ? null : _confirm,
        child: const Text('Continue'),
      ),
    ],
  );
}
