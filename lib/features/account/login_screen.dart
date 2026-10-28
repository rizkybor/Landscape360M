import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/providers.dart';
import '../../core/theme/app_theme.dart';
import '../../data/account/account_repository.dart';

const _supportEmail = 'contact@jcdigital.co.id';

class LoginScreen extends ConsumerStatefulWidget {
  const LoginScreen({super.key});

  @override
  ConsumerState<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends ConsumerState<LoginScreen> {
  final _email = TextEditingController();
  final _password = TextEditingController();
  bool _busy = false;
  bool _obscure = true;
  String? _error;

  @override
  void dispose() {
    _email.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await ref.read(accountRepositoryProvider).signIn(_email.text, _password.text);
      if (mounted) context.go('/');
    } on AccountException catch (e) {
      setState(() => _error = e.message);
    } on Object {
      setState(() => _error = 'Could not sign in. Check your connection and try again.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  // Like the web: there is no self-service reset, the admin resets the password
  Future<void> _forgotPassword() {
    final subject = Uri.encodeComponent('Reset Password Request for Landscape360');
    final body = Uri.encodeComponent(
      'Dear Admin,\n\nI forgot my password and would like to request a password reset.\n\n'
      'My Email: ${_email.text.trim()}\n\nThank you.',
    );
    return launchUrl(Uri.parse('mailto:$_supportEmail?subject=$subject&body=$body'));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Sign in')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(20),
          children: [
            const Text(
              'Landscape 360',
              style: TextStyle(fontSize: 26, fontWeight: FontWeight.w700, color: L360Colors.forest700),
            ),
            const Text('Explore without Limits', style: TextStyle(color: L360Colors.sand500)),
            const SizedBox(height: 24),
            AutofillGroup(
              child: Column(
                children: [
                  TextField(
                    key: const Key('login-email'),
                    controller: _email,
                    keyboardType: TextInputType.emailAddress,
                    autofillHints: const [AutofillHints.email],
                    autocorrect: false,
                    decoration: const InputDecoration(labelText: 'Email'),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    key: const Key('login-password'),
                    controller: _password,
                    obscureText: _obscure,
                    autofillHints: const [AutofillHints.password],
                    onSubmitted: (_) => _busy ? null : _submit(),
                    decoration: InputDecoration(
                      labelText: 'Password',
                      suffixIcon: IconButton(
                        tooltip: _obscure ? 'Show password' : 'Hide password',
                        icon: Icon(_obscure ? Icons.visibility : Icons.visibility_off),
                        onPressed: () => setState(() => _obscure = !_obscure),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            if (_error != null) ...[
              const SizedBox(height: 12),
              Text(
                _error!,
                key: const Key('login-error'),
                style: const TextStyle(color: L360Colors.brick500),
              ),
            ],
            const SizedBox(height: 20),
            FilledButton(
              key: const Key('login-submit'),
              onPressed: _busy ? null : _submit,
              child: _busy
                  ? const SizedBox.square(dimension: 20, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Text('Sign in'),
            ),
            TextButton(onPressed: _forgotPassword, child: const Text('Forgot password?')),
            const Divider(height: 32),
            OutlinedButton(
              onPressed: () => context.push('/request-account'),
              child: const Text("Don't have an account? Request one"),
            ),
          ],
        ),
      ),
    );
  }
}
