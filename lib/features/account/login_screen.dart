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
    final text = Theme.of(context).textTheme;
    return Scaffold(
      appBar: AppBar(),
      body: SafeArea(
        top: false,
        // Tablets: a phone-width column in the middle
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: authMaxWidth),
            child: CustomScrollView(
              slivers: [
                SliverPadding(
                  padding: const EdgeInsets.fromLTRB(24, 0, 24, 0),
                  sliver: SliverList.list(
                    children: [
                      // Brand
                      Center(child: Image.asset('assets/images/logo.png', width: 88, height: 88)),
                      const SizedBox(height: 16),
                      const BrandName(key: Key('login-brand'), fontSize: 28, textAlign: TextAlign.center),
                      const SizedBox(height: 24),
                      // Greeting
                      Text(
                        'Welcome back',
                        key: const Key('login-welcome'),
                        textAlign: TextAlign.center,
                        style: text.titleMedium?.copyWith(fontWeight: FontWeight.w700),
                      ),
                      const SizedBox(height: 8),
                      const Text(
                        'Sign in to Landscape 360 app to save surveys, tracks and places.',
                        textAlign: TextAlign.center,
                        style: TextStyle(color: L360Colors.sand600, height: 1.45),
                      ),
                      const SizedBox(height: 32),
                      // Form
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
                                icon: Icon(
                                  _obscure ? Icons.visibility_outlined : Icons.visibility_off_outlined,
                                  size: 20,
                                ),
                                onPressed: () => setState(() => _obscure = !_obscure),
                              ),
                            ),
                          ],
                        ),
                      ),
                      // Right under the password field
                      Align(
                        alignment: Alignment.centerRight,
                        child: TextButton(
                          onPressed: _forgotPassword,
                          style: TextButton.styleFrom(
                            padding: const EdgeInsets.symmetric(horizontal: 4),
                            minimumSize: const Size(0, 32),
                            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                          ),
                          child: const Text('Forgot password?', style: TextStyle(fontSize: 13)),
                        ),
                      ),
                      if (_error != null) ...[
                        const SizedBox(height: 12),
                        KeyedSubtree(key: const Key('login-error'), child: ErrorBanner(_error!)),
                      ],
                      const SizedBox(height: 24),
                      KeyedSubtree(
                        key: const Key('login-submit'),
                        child: BusyButton(label: 'Sign in', busy: _busy, onPressed: _submit),
                      ),
                      const SizedBox(height: 32),
                      // New here
                      const _OrDivider("Don't have an account?"),
                      const SizedBox(height: 16),
                      OutlinedButton(
                        onPressed: () => context.push('/request-account'),
                        child: const Text('Request an account'),
                      ),
                    ],
                  ),
                ),
                // Credits at the bottom of the screen, or after the form when it scrolls
                const SliverFillRemaining(
                  hasScrollBody: false,
                  child: Align(
                    alignment: Alignment.bottomCenter,
                    child: Padding(padding: EdgeInsets.fromLTRB(24, 32, 24, 16), child: _Credits()),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Sign in and Request account: content width on tablets
const authMaxWidth = 440.0;

/// A label between two hairlines; the label keeps its own width and wraps only when it
/// is longer than most of the row (large text)
class _OrDivider extends StatelessWidget {
  const _OrDivider(this.label);

  final String label;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, c) => Row(
      children: [
        const Expanded(child: Divider()),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: ConstrainedBox(
            constraints: BoxConstraints(maxWidth: c.maxWidth * 0.7),
            child: Text(
              label,
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 13, color: L360Colors.sand500),
            ),
          ),
        ),
        const Expanded(child: Divider()),
      ],
    ),
  );
}

/// "Powered by" in small type at the bottom, like the web's sign in
class _Credits extends StatelessWidget {
  const _Credits();

  static const _small = TextStyle(fontSize: 10, color: L360Colors.sand400);
  static const _name = TextStyle(fontSize: 10, color: L360Colors.sand600, fontWeight: FontWeight.w700);

  Widget _link(String text, String url) => GestureDetector(
    onTap: () => launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication),
    child: Text(text, style: _name),
  );

  @override
  Widget build(BuildContext context) => Column(
    key: const Key('login-credits'),
    mainAxisSize: MainAxisSize.min,
    children: [
      Wrap(
        alignment: WrapAlignment.center,
        crossAxisAlignment: WrapCrossAlignment.center,
        spacing: 4,
        runSpacing: 2,
        children: [
          const Text('Powered by', style: _small),
          _link('Jendela Cakra Digital', 'https://instagram.com/jendelacakradigital'),
          const Text('·', style: _small),
          _link('Makopala Univ. Budi Luhur', 'https://instagram.com/makopala_ubl'),
        ],
      ),
      const SizedBox(height: 4),
      Text('© ${DateTime.now().year}', style: _small),
    ],
  );
}
