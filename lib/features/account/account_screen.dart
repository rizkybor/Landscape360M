import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/providers.dart';
import '../../core/theme/app_theme.dart';
import '../../data/account/account_repository.dart';
import '../../domain/account/profile.dart';

/// User Account: name, email, organization, phone, plan / role badges, edit, password,
/// sign out. Admins get a link to the admin panel, which stays on the web.
class AccountScreen extends ConsumerWidget {
  const AccountScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final profile = ref.watch(profileProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('User Account')),
      body: profile.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('Could not load your account: $e')),
        data: (p) => p == null ? const Center(child: Text('Signed out')) : _AccountBody(profile: p),
      ),
    );
  }
}

class _AccountBody extends ConsumerWidget {
  const _AccountBody({required this.profile});

  final AccountProfile profile;

  Future<void> _signOut(BuildContext context, WidgetRef ref) async {
    await ref.read(accountRepositoryProvider).signOut();
    if (context.mounted) context.go('/');
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final p = profile;
    final siteUrl = ref.watch(appConfigProvider).apiBaseUrl;
    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        Text(
          p.displayName.isEmpty ? p.email : p.displayName,
          style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w700),
        ),
        Text(p.email, style: const TextStyle(color: L360Colors.sand500)),
        const SizedBox(height: 12),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            _Badge(p.isAdmin ? 'Admin' : p.plan.value, L360Colors.gold100, L360Colors.gold700),
            _Badge(p.role.name, L360Colors.forest100, L360Colors.forest700),
            if (p.canUseSos) const _Badge('S.O.S', L360Colors.brick50, L360Colors.brick600),
          ],
        ),
        const SizedBox(height: 16),
        if (p.organization?.isNotEmpty ?? false)
          ListTile(title: const Text('Organization'), subtitle: Text(p.organization!)),
        if (p.phone?.isNotEmpty ?? false) ListTile(title: const Text('Phone'), subtitle: Text(p.phone!)),
        ListTile(
          leading: const Icon(Icons.edit_outlined),
          title: const Text('Edit profile'),
          onTap: () => context.push('/account/edit'),
        ),
        ListTile(
          leading: const Icon(Icons.lock_outline),
          title: const Text('Change password'),
          onTap: () => context.push('/account/password'),
        ),
        if (p.isAdmin)
          ListTile(
            leading: const Icon(Icons.admin_panel_settings_outlined),
            title: const Text('Open the admin panel on the web'),
            subtitle: const Text('Manage users, account requests, activity and POI'),
            onTap: () => launchUrl(Uri.parse(siteUrl), mode: LaunchMode.externalApplication),
          ),
        const SizedBox(height: 24),
        OutlinedButton.icon(
          key: const Key('sign-out'),
          onPressed: () => _signOut(context, ref),
          icon: const Icon(Icons.logout),
          label: const Text('Sign out'),
        ),
      ],
    );
  }
}

class _Badge extends StatelessWidget {
  const _Badge(this.label, this.background, this.foreground);

  final String label;
  final Color background;
  final Color foreground;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
    decoration: BoxDecoration(color: background, borderRadius: BorderRadius.circular(20)),
    child: Text(
      label,
      style: TextStyle(color: foreground, fontWeight: FontWeight.w600, fontSize: 12),
    ),
  );
}

class EditProfileScreen extends ConsumerStatefulWidget {
  const EditProfileScreen({super.key});

  @override
  ConsumerState<EditProfileScreen> createState() => _EditProfileScreenState();
}

class _EditProfileScreenState extends ConsumerState<EditProfileScreen> {
  late final TextEditingController _name;
  late final TextEditingController _organization;
  late final TextEditingController _phone;
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    final p = ref.read(profileProvider).value;
    _name = TextEditingController(text: p?.displayName ?? '');
    _organization = TextEditingController(text: p?.organization ?? '');
    _phone = TextEditingController(text: p?.phone ?? '');
  }

  @override
  void dispose() {
    _name.dispose();
    _organization.dispose();
    _phone.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await ref
          .read(accountRepositoryProvider)
          .updateProfile(displayName: _name.text, organization: _organization.text, phone: _phone.text);
      ref.invalidate(profileProvider);
      if (mounted) context.pop();
    } on AccountException catch (e) {
      setState(() => _error = e.message);
    } on Object catch (e) {
      setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Edit profile')),
    body: ListView(
      padding: const EdgeInsets.all(20),
      children: [
        TextField(
          controller: _name,
          decoration: const InputDecoration(labelText: 'Name'),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _organization,
          decoration: const InputDecoration(labelText: 'Organization'),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _phone,
          keyboardType: TextInputType.phone,
          decoration: const InputDecoration(labelText: 'Phone / WhatsApp'),
        ),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.only(top: 12),
            child: Text(_error!, style: const TextStyle(color: L360Colors.brick500)),
          ),
        const SizedBox(height: 20),
        FilledButton(onPressed: _busy ? null : _save, child: const Text('Save')),
      ],
    ),
  );
}

class ChangePasswordScreen extends ConsumerStatefulWidget {
  const ChangePasswordScreen({super.key});

  @override
  ConsumerState<ChangePasswordScreen> createState() => _ChangePasswordScreenState();
}

class _ChangePasswordScreenState extends ConsumerState<ChangePasswordScreen> {
  final _current = TextEditingController();
  final _next = TextEditingController();
  final _confirm = TextEditingController();
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _current.dispose();
    _next.dispose();
    _confirm.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await ref
          .read(accountRepositoryProvider)
          .changePassword(current: _current.text, next: _next.text, confirm: _confirm.text);
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('Password changed. Other devices were signed out.')));
      context.pop();
    } on AccountException catch (e) {
      setState(() => _error = e.message);
    } on Object catch (e) {
      setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Change password')),
    body: ListView(
      padding: const EdgeInsets.all(20),
      children: [
        TextField(
          controller: _current,
          obscureText: true,
          decoration: const InputDecoration(labelText: 'Current password'),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _next,
          obscureText: true,
          decoration: const InputDecoration(labelText: 'New password'),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _confirm,
          obscureText: true,
          decoration: const InputDecoration(labelText: 'Confirm new password'),
        ),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.only(top: 12),
            child: Text(_error!, style: const TextStyle(color: L360Colors.brick500)),
          ),
        const SizedBox(height: 20),
        FilledButton(onPressed: _busy ? null : _save, child: const Text('Change password')),
      ],
    ),
  );
}
