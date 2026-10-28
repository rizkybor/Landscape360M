import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/providers.dart';
import '../../core/theme/app_theme.dart';
import '../../core/ui/widgets.dart';
import '../../data/account/account_repository.dart';
import '../../domain/account/account_rules.dart';
import '../../domain/account/profile.dart';
import '../offline/offline_ui.dart';
import '../sos/sos_alerts.dart';
import '../sos/sos_screen.dart';
import '../sos/sos_state.dart';
import 'delete_account.dart';

/// User Account: profile, plan / role badges, cloud storage, edit, password, sign out.
/// Admins get a link to the admin panel, which stays on the web.
class AccountScreen extends ConsumerWidget {
  const AccountScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Signed out (here, on another device, or the session ended): back to the map
    ref.listen(authUserIdProvider, (prev, next) {
      if (prev?.value != null && next.hasValue && next.value == null && context.mounted) context.go('/');
    });
    final profile = ref.watch(profileProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('User Account')),
      body: profile.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) =>
            Padding(padding: const EdgeInsets.all(L360.gutter), child: ErrorBanner('Could not load your account: $e')),
        data: (p) => p == null ? const _SignedOut() : _AccountBody(profile: p),
      ),
    );
  }
}

/// Shown for a moment after signing out, or if the account page is reached without a session
class _SignedOut extends StatelessWidget {
  const _SignedOut();

  @override
  Widget build(BuildContext context) => Center(
    key: const Key('signed-out'),
    child: Padding(
      padding: const EdgeInsets.all(32),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Image.asset('assets/images/logo.png', width: 80, height: 80),
          const SizedBox(height: 12),
          const BrandName(textAlign: TextAlign.center),
          const SizedBox(height: 16),
          Text("You're signed out", style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 6),
          const Text(
            'The map still works. Sign in to use your account.',
            textAlign: TextAlign.center,
            style: TextStyle(color: L360Colors.sand600),
          ),
          const SizedBox(height: 24),
          FilledButton(onPressed: () => context.go('/login'), child: const Text('Sign in')),
          const SizedBox(height: 10),
          OutlinedButton(onPressed: () => context.go('/'), child: const Text('Back to the map')),
        ],
      ),
    ),
  );
}

class _AccountBody extends ConsumerWidget {
  const _AccountBody({required this.profile});

  final AccountProfile profile;

  Future<void> _signOut(BuildContext context, WidgetRef ref) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog.adaptive(
        title: const Text('Sign out?'),
        content: const Text('You can sign in again with your email and password.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            style: TextButton.styleFrom(foregroundColor: L360Colors.brick500),
            child: const Text('Sign out'),
          ),
        ],
      ),
    );
    if (ok != true || !context.mounted) return;
    // Taken before signing out: this page is replaced as soon as the session ends
    final router = GoRouter.of(context);
    await ref.read(accountRepositoryProvider).signOut();
    router.go('/');
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final p = profile;
    final siteUrl = ref.watch(appConfigProvider).apiBaseUrl;
    final hasContact = (p.organization?.isNotEmpty ?? false) || (p.phone?.isNotEmpty ?? false);
    return RefreshIndicator(
      onRefresh: () async {
        ref
          ..invalidate(profileProvider)
          ..invalidate(storageUsageProvider);
        await ref.read(profileProvider.future);
      },
      child: ListView(
        padding: const EdgeInsets.fromLTRB(L360.gutter, 8, L360.gutter, 32),
        children: [
          _ProfileHeader(profile: p),
          const SizedBox(height: 24),
          const _StorageSection(),
          GroupedSection(
            title: 'Profile',
            children: [
              if (p.organization?.isNotEmpty ?? false)
                ListTile(
                  leading: const TileIcon(Icons.groups_outlined),
                  title: const Text('Organization'),
                  subtitle: Text(p.organization!),
                ),
              if (p.phone?.isNotEmpty ?? false)
                ListTile(
                  leading: const TileIcon(Icons.phone_outlined),
                  title: const Text('Phone / WhatsApp'),
                  subtitle: Text(p.phone!),
                ),
              ListTile(
                leading: const TileIcon(Icons.edit_outlined),
                title: Text(hasContact ? 'Edit profile' : 'Add name, organization and phone'),
                trailing: const Icon(Icons.chevron_right, color: L360Colors.sand400),
                onTap: () => context.push('/account/edit'),
              ),
            ],
          ),
          GroupedSection(
            title: 'On this phone',
            children: [
              ListTile(
                key: const Key('account-offline'),
                leading: const TileIcon(Icons.download_for_offline_outlined),
                title: const Text('Offline maps'),
                trailing: const Icon(Icons.chevron_right, color: L360Colors.sand400),
                onTap: () => showOfflineSheet(context),
              ),
            ],
          ),
          GroupedSection(
            title: 'Security',
            children: [
              ListTile(
                leading: const TileIcon(Icons.lock_outline),
                title: const Text('Change password'),
                trailing: const Icon(Icons.chevron_right, color: L360Colors.sand400),
                onTap: () => context.push('/account/password'),
              ),
            ],
          ),
          if (p.isAdmin)
            GroupedSection(
              title: 'Admin',
              footer:
                  'Manage users, account requests, activity, broadcast and points of interest on the web. '
                  'S.O.S alerts are checked every 30 s while the app is open.',
              children: [
                ListTile(
                  key: const Key('admin-sos-alerts'),
                  leading: const TileIcon(Icons.sos, color: L360Colors.brick500, background: L360Colors.brick50),
                  title: const Text('S.O.S alerts'),
                  subtitle: Consumer(
                    builder: (context, ref, _) {
                      final n = ref.watch(sosAlertsProvider.select((s) => s.active.length));
                      return Text(n == 0 ? 'No active S.O.S' : '$n active');
                    },
                  ),
                  trailing: const Icon(Icons.chevron_right, color: L360Colors.sand400),
                  onTap: () => showSosAlertsSheet(context),
                ),
                ListTile(
                  key: const Key('admin-sos-open'),
                  leading: const TileIcon(
                    Icons.emergency_outlined,
                    color: L360Colors.brick500,
                    background: L360Colors.brick50,
                  ),
                  title: const Text('Open S.O.S screen'),
                  subtitle: const Text('Admins raise S.O.S here; others hold the red button on the map'),
                  onTap: () => openSosScreen(context, ref),
                ),
                ListTile(
                  leading: const TileIcon(
                    Icons.admin_panel_settings_outlined,
                    color: L360Colors.gold700,
                    background: L360Colors.gold50,
                  ),
                  title: const Text('Open the admin panel on the web'),
                  trailing: const Icon(Icons.open_in_new, size: 18, color: L360Colors.sand400),
                  onTap: () => launchUrl(Uri.parse(siteUrl), mode: LaunchMode.externalApplication),
                ),
              ],
            ),
          GroupedSection(
            children: [
              ListTile(
                key: const Key('account-about'),
                leading: const TileIcon(Icons.info_outline),
                title: const Text('About Landscape 360'),
                subtitle: const Text('Version, privacy, terms and support'),
                trailing: const Icon(Icons.chevron_right, color: L360Colors.sand400),
                onTap: () => context.push('/about'),
              ),
            ],
          ),
          GroupedSection(
            children: [
              ListTile(
                key: const Key('sign-out'),
                leading: const TileIcon(Icons.logout, color: L360Colors.brick500, background: L360Colors.brick50),
                title: const Text(
                  'Sign out',
                  style: TextStyle(color: L360Colors.brick500, fontWeight: FontWeight.w600),
                ),
                onTap: () => _signOut(context, ref),
              ),
            ],
          ),
          if (!p.isAdmin)
            GroupedSection(
              footer: 'Deletes the account and everything in it for good.',
              children: [
                ListTile(
                  key: const Key('delete-account'),
                  leading: const TileIcon(
                    Icons.person_remove_outlined,
                    color: L360Colors.brick500,
                    background: L360Colors.brick50,
                  ),
                  title: const Text('Delete account', style: TextStyle(color: L360Colors.brick500)),
                  onTap: () => confirmDeleteAccount(context, ref),
                ),
              ],
            ),
        ],
      ),
    );
  }
}

class _ProfileHeader extends StatelessWidget {
  const _ProfileHeader({required this.profile});

  final AccountProfile profile;

  @override
  Widget build(BuildContext context) {
    final p = profile;
    final name = p.displayName.isEmpty ? p.email : p.displayName;
    return Column(
      children: [
        CircleAvatar(
          radius: 40,
          backgroundColor: L360Colors.forest700,
          child: Text(
            name.isEmpty ? '?' : name.characters.first.toUpperCase(),
            style: const TextStyle(color: Colors.white, fontSize: 32, fontWeight: FontWeight.w700),
          ),
        ),
        const SizedBox(height: 12),
        Text(name, textAlign: TextAlign.center, style: Theme.of(context).textTheme.titleLarge),
        if (p.displayName.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Text(p.email, style: const TextStyle(color: L360Colors.sand500)),
          ),
        const SizedBox(height: 12),
        Wrap(
          alignment: WrapAlignment.center,
          spacing: 8,
          runSpacing: 8,
          children: [
            if (p.isAdmin)
              const Pill(
                'Admin',
                background: L360Colors.gold100,
                foreground: L360Colors.gold700,
                icon: Icons.shield_outlined,
              )
            else
              Pill(
                p.plan.value,
                background: L360Colors.gold100,
                foreground: L360Colors.gold700,
                icon: Icons.workspace_premium_outlined,
              ),
            Pill(p.role.name, background: L360Colors.forest100, foreground: L360Colors.forest700),
            if (p.canUseSos)
              const Pill('S.O.S', background: L360Colors.brick50, foreground: L360Colors.brick600, icon: Icons.sos),
          ],
        ),
      ],
    );
  }
}

class _StorageSection extends ConsumerWidget {
  const _StorageSection();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final usage = ref.watch(storageUsageProvider);
    final u = usage.value;
    if (u == null) return const SizedBox.shrink();
    final level = usageLevel(u.percent);
    final barColor = switch (level) {
      UsageLevel.critical => L360Colors.brick500,
      UsageLevel.warning => L360Colors.gold400,
      UsageLevel.normal => L360Colors.forest700,
    };
    return Padding(
      padding: const EdgeInsets.only(bottom: 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SectionLabel('Cloud Storage'),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.baseline,
                    textBaseline: TextBaseline.alphabetic,
                    children: [
                      Text(formatBytes(u.usedBytes), style: Theme.of(context).textTheme.titleMedium),
                      const SizedBox(width: 4),
                      Text(
                        u.limitBytes == null ? 'used · unlimited' : 'of ${formatBytes(u.limitBytes!)}',
                        style: const TextStyle(color: L360Colors.sand500),
                      ),
                    ],
                  ),
                  if (u.percent != null) ...[
                    const SizedBox(height: 10),
                    ClipRRect(
                      borderRadius: BorderRadius.circular(4),
                      child: LinearProgressIndicator(
                        value: u.percent! / 100,
                        minHeight: 8,
                        color: barColor,
                        backgroundColor: L360Colors.sand100,
                      ),
                    ),
                  ],
                  const SizedBox(height: 12),
                  for (final (label, bytes) in u.breakdown)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 3),
                      child: Row(
                        children: [
                          Expanded(
                            child: Text(label, style: const TextStyle(fontSize: 13, color: L360Colors.sand700)),
                          ),
                          Text(formatBytes(bytes), style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
                        ],
                      ),
                    ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Text field with a leading icon, used by the account forms
class FormFieldRow extends StatelessWidget {
  const FormFieldRow({
    super.key,
    this.fieldKey,
    required this.controller,
    required this.label,
    required this.icon,
    this.keyboardType,
    this.obscure = false,
    this.autofill,
    this.helper,
    this.maxLines = 1,
    this.maxLength,
    this.textInputAction = TextInputAction.next,
    this.onSubmitted,
    this.suffix,
  });

  final Key? fieldKey;
  final TextEditingController controller;
  final String label;
  final IconData icon;
  final TextInputType? keyboardType;
  final bool obscure;
  final Iterable<String>? autofill;
  final String? helper;
  final int maxLines;
  final int? maxLength;
  final TextInputAction textInputAction;
  final ValueChanged<String>? onSubmitted;
  final Widget? suffix;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 12),
    child: TextField(
      key: fieldKey,
      controller: controller,
      keyboardType: keyboardType,
      obscureText: obscure,
      autocorrect: !obscure && keyboardType != TextInputType.emailAddress,
      autofillHints: autofill,
      maxLines: maxLines,
      maxLength: maxLength,
      textInputAction: textInputAction,
      onSubmitted: onSubmitted,
      decoration: InputDecoration(
        labelText: label,
        helperText: helper,
        prefixIcon: Icon(icon, size: 20),
        suffixIcon: suffix,
        alignLabelWithHint: maxLines > 1,
      ),
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
    FocusScope.of(context).unfocus();
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await ref
          .read(accountRepositoryProvider)
          .updateProfile(displayName: _name.text, organization: _organization.text, phone: _phone.text);
      ref.invalidate(profileProvider);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Profile updated')));
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
    appBar: AppBar(title: const Text('Edit profile')),
    body: SafeArea(
      child: ListView(
        padding: const EdgeInsets.all(L360.gutter),
        children: [
          FormFieldRow(
            controller: _name,
            label: 'Name',
            icon: Icons.person_outline,
            autofill: const [AutofillHints.name],
          ),
          FormFieldRow(
            controller: _organization,
            label: 'Organization',
            icon: Icons.groups_outlined,
            autofill: const [AutofillHints.organizationName],
          ),
          FormFieldRow(
            controller: _phone,
            label: 'Phone / WhatsApp',
            icon: Icons.phone_outlined,
            keyboardType: TextInputType.phone,
            autofill: const [AutofillHints.telephoneNumber],
            helper: '8 to 15 digits, e.g. 0812 3456 7890',
            textInputAction: TextInputAction.done,
            onSubmitted: (_) => _busy ? null : _save(),
          ),
          if (_error != null) ...[ErrorBanner(_error!), const SizedBox(height: 12)],
          const SizedBox(height: 8),
          BusyButton(label: 'Save', busy: _busy, onPressed: _save),
        ],
      ),
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
  bool _show = false;
  String? _error;

  @override
  void dispose() {
    _current.dispose();
    _next.dispose();
    _confirm.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    FocusScope.of(context).unfocus();
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
  Widget build(BuildContext context) {
    final eye = IconButton(
      tooltip: _show ? 'Hide passwords' : 'Show passwords',
      icon: Icon(_show ? Icons.visibility_off_outlined : Icons.visibility_outlined, size: 20),
      onPressed: () => setState(() => _show = !_show),
    );
    return Scaffold(
      appBar: AppBar(title: const Text('Change password')),
      body: SafeArea(
        child: AutofillGroup(
          child: ListView(
            padding: const EdgeInsets.all(L360.gutter),
            children: [
              FormFieldRow(
                controller: _current,
                label: 'Current password',
                icon: Icons.lock_outline,
                obscure: !_show,
                autofill: const [AutofillHints.password],
                suffix: eye,
              ),
              FormFieldRow(
                controller: _next,
                label: 'New password',
                icon: Icons.key_outlined,
                obscure: !_show,
                autofill: const [AutofillHints.newPassword],
                helper: 'At least $minPasswordLength characters',
              ),
              FormFieldRow(
                controller: _confirm,
                label: 'Confirm new password',
                icon: Icons.key_outlined,
                obscure: !_show,
                autofill: const [AutofillHints.newPassword],
                textInputAction: TextInputAction.done,
                onSubmitted: (_) => _busy ? null : _save(),
              ),
              const Padding(
                padding: EdgeInsets.fromLTRB(4, 0, 4, 16),
                child: Text(
                  'Other phones and browsers signed in to this account will have to sign in again.',
                  style: TextStyle(fontSize: 12, color: L360Colors.sand600),
                ),
              ),
              if (_error != null) ...[ErrorBanner(_error!), const SizedBox(height: 12)],
              BusyButton(label: 'Change password', busy: _busy, onPressed: _save),
            ],
          ),
        ),
      ),
    );
  }
}
