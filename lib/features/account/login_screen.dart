import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/providers.dart';
import '../../core/theme/app_theme.dart';
import '../../core/ui/widgets.dart';
import '../../data/account/account_repository.dart';
import 'account_screen.dart';

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
    FocusScope.of(context).unfocus();
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await ref.read(accountRepositoryProvider).signIn(_email.text, _password.text);
      await HapticFeedback.mediumImpact();
      if (mounted) context.go('/');
    } on AccountException catch (e) {
      await HapticFeedback.heavyImpact();
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
      appBar: AppBar(),
      body: SafeArea(
        top: false,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
          children: [
            Center(child: Image.asset('assets/images/logo.png', width: 96, height: 96)),
            const SizedBox(height: 8),
            const BrandName(fontSize: 15, textAlign: TextAlign.center),
            const SizedBox(height: 10),
            Text('Welcome back', textAlign: TextAlign.center, style: Theme.of(context).textTheme.headlineSmall),
            const SizedBox(height: 4),
            Text.rich(
              TextSpan(
                children: [
                  const TextSpan(text: 'Sign in to '),
                  ...brandSpans(),
                  const TextSpan(text: ' to save surveys, tracks and places.'),
                ],
              ),
              textAlign: TextAlign.center,
              style: const TextStyle(color: L360Colors.sand600),
            ),
            const SizedBox(height: 28),
            AutofillGroup(
              child: Column(
                children: [
                  FormFieldRow(
                    fieldKey: const Key('login-email'),
                    controller: _email,
                    label: 'Email',
                    icon: Icons.mail_outline,
                    keyboardType: TextInputType.emailAddress,
                    autofill: const [AutofillHints.email, AutofillHints.username],
                  ),
                  FormFieldRow(
                    fieldKey: const Key('login-password'),
                    controller: _password,
                    label: 'Password',
                    icon: Icons.lock_outline,
                    obscure: _obscure,
                    autofill: const [AutofillHints.password],
                    textInputAction: TextInputAction.go,
                    onSubmitted: (_) => _busy ? null : _submit(),
                    suffix: IconButton(
                      tooltip: _obscure ? 'Show password' : 'Hide password',
                      icon: Icon(_obscure ? Icons.visibility_outlined : Icons.visibility_off_outlined, size: 20),
                      onPressed: () => setState(() => _obscure = !_obscure),
                    ),
                  ),
                ],
              ),
            ),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton(onPressed: _forgotPassword, child: const Text('Forgot password?')),
            ),
            if (_error != null) ...[
              const SizedBox(height: 4),
              KeyedSubtree(key: const Key('login-error'), child: ErrorBanner(_error!)),
            ],
            const SizedBox(height: 16),
            KeyedSubtree(
              key: const Key('login-submit'),
              child: BusyButton(label: 'Sign in', busy: _busy, onPressed: _submit),
            ),
            const SizedBox(height: 32),
            const Row(
              children: [
                Expanded(child: Divider()),
                Padding(
                  padding: EdgeInsets.symmetric(horizontal: 12),
                  child: Text("Don't have an account?", style: TextStyle(fontSize: 13, color: L360Colors.sand500)),
                ),
                Expanded(child: Divider()),
              ],
            ),
            const SizedBox(height: 16),
            OutlinedButton(onPressed: () => context.push('/request-account'), child: const Text('Request an account')),
          ],
        ),
      ),
    );
  }
}
