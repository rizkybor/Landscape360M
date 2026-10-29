import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/providers.dart';
import '../../core/theme/app_theme.dart';
import '../../core/ui/widgets.dart';
import '../../data/account/account_repository.dart';
import '../../domain/account/account_request.dart';
import 'account_screen.dart';
import 'login_screen.dart' show authMaxWidth;

class RequestAccountScreen extends ConsumerStatefulWidget {
  const RequestAccountScreen({super.key});

  @override
  ConsumerState<RequestAccountScreen> createState() => _RequestAccountScreenState();
}

class _RequestAccountScreenState extends ConsumerState<RequestAccountScreen> {
  final _name = TextEditingController();
  final _email = TextEditingController();
  final _organization = TextEditingController();
  final _phone = TextEditingController();
  final _message = TextEditingController();
  bool _busy = false;
  bool _sent = false;
  String? _error;

  @override
  void dispose() {
    for (final c in [_name, _email, _organization, _phone, _message]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _submit() async {
    FocusScope.of(context).unfocus();
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await ref
          .read(accountRepositoryProvider)
          .requestAccount(
            AccountRequestInput(
              email: _email.text,
              fullName: _name.text,
              organization: _organization.text,
              phone: _phone.text,
              message: _message.text,
            ),
          );
      await HapticFeedback.mediumImpact();
      setState(() => _sent = true);
    } on AccountException catch (e) {
      setState(() => _error = e.message);
    } on Object {
      setState(() => _error = 'Could not send the request. Check your connection and try again.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(),
      body: SafeArea(
        top: false,
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: authMaxWidth),
            child: _sent ? _Sent(onDone: () => context.pop()) : _form(context),
          ),
        ),
      ),
    );
  }

  Widget _form(BuildContext context) => ListView(
    padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
    children: [
      Text(
        'Request an account',
        style: Theme.of(context).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w700),
      ),
      const SizedBox(height: 8),
      const Text(
        'Tell us who you are. The admin reviews every request and emails your login details after approval. '
        'New accounts start on the Free plan.',
        style: TextStyle(color: L360Colors.sand600, height: 1.45),
      ),
      const SizedBox(height: 32),
      const SectionLabel('About you'),
      FormFieldRow(
        fieldKey: const Key('request-name'),
        controller: _name,
        label: 'Full name',
        icon: Icons.person_outline,
        autofill: const [AutofillHints.name],
      ),
      FormFieldRow(
        fieldKey: const Key('request-email'),
        controller: _email,
        label: 'Email',
        icon: Icons.mail_outline,
        keyboardType: TextInputType.emailAddress,
        autofill: const [AutofillHints.email],
      ),
      const SizedBox(height: 12),
      const SectionLabel('Organization and contact'),
      FormFieldRow(
        controller: _organization,
        label: 'Organization (optional)',
        icon: Icons.groups_outlined,
        autofill: const [AutofillHints.organizationName],
      ),
      FormFieldRow(
        controller: _phone,
        label: 'Phone / WhatsApp (optional)',
        icon: Icons.phone_outlined,
        keyboardType: TextInputType.phone,
        autofill: const [AutofillHints.telephoneNumber],
        helper: '8 to 15 digits',
      ),
      const SizedBox(height: 12),
      const SectionLabel('Your request'),
      FormFieldRow(
        fieldKey: const Key('request-message'),
        controller: _message,
        label: 'Message',
        helper: 'How will you use Landscape 360 app?',
        maxLines: 5,
        maxLength: 1000,
        textInputAction: TextInputAction.newline,
      ),
      if (_error != null) ...[const SizedBox(height: 4), ErrorBanner(_error!)],
      const SizedBox(height: 24),
      BusyButton(label: 'Send request', busy: _busy, onPressed: _submit),
    ],
  );
}

class _Sent extends StatelessWidget {
  const _Sent({required this.onDone});

  final VoidCallback onDone;

  @override
  Widget build(BuildContext context) => Padding(
    key: const Key('request-sent'),
    padding: const EdgeInsets.all(32),
    child: Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Container(
          width: 72,
          height: 72,
          decoration: const BoxDecoration(color: L360Colors.forest50, shape: BoxShape.circle),
          child: const Icon(Icons.mark_email_read_outlined, size: 36, color: L360Colors.forest700),
        ),
        const SizedBox(height: 20),
        Text('Request sent', style: Theme.of(context).textTheme.titleLarge),
        const SizedBox(height: 8),
        const Text(
          'Thank you! The admin will email you when your account is ready.',
          textAlign: TextAlign.center,
          style: TextStyle(color: L360Colors.sand600),
        ),
        const SizedBox(height: 28),
        OutlinedButton(onPressed: onDone, child: const Text('Back to sign in')),
      ],
    ),
  );
}
