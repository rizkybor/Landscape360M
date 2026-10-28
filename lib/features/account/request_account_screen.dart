import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers.dart';
import '../../core/theme/app_theme.dart';
import '../../data/account/account_repository.dart';
import '../../domain/account/account_request.dart';

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
      appBar: AppBar(title: const Text('Request an account')),
      body: SafeArea(
        child: _sent
            ? const Padding(
                padding: EdgeInsets.all(24),
                child: Text(
                  'Thank you! Your request was sent. The admin will email you when your account is ready.',
                  key: Key('request-sent'),
                  style: TextStyle(fontSize: 16),
                ),
              )
            : ListView(
                padding: const EdgeInsets.all(20),
                children: [
                  TextField(
                    controller: _name,
                    decoration: const InputDecoration(labelText: 'Full name'),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _email,
                    keyboardType: TextInputType.emailAddress,
                    autocorrect: false,
                    decoration: const InputDecoration(labelText: 'Email'),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _organization,
                    decoration: const InputDecoration(labelText: 'Organization (optional)'),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _phone,
                    keyboardType: TextInputType.phone,
                    decoration: const InputDecoration(labelText: 'Phone / WhatsApp (optional)'),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _message,
                    maxLines: 4,
                    maxLength: 1000,
                    decoration: const InputDecoration(labelText: 'How will you use Landscape 360?'),
                  ),
                  if (_error != null)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 12),
                      child: Text(_error!, style: const TextStyle(color: L360Colors.brick500)),
                    ),
                  FilledButton(onPressed: _busy ? null : _submit, child: const Text('Send request')),
                ],
              ),
      ),
    );
  }
}
