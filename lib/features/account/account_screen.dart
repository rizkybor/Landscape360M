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
import '../offline/offline_state.dart' show offlineSheetRequestProvider;
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
    Widget chevron() => const Icon(Icons.chevron_right, color: L360Colors.sand400);
    return RefreshIndicator(
      onRefresh: () async {
        ref
          ..invalidate(profileProvider)
          ..invalidate(storageUsageProvider);
        await ref.read(profileProvider.future);
      },
      // Tablets: a phone-width column in the middle
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: L360.panelMaxWidth),
          // Menu rows at reading size, a settings page rather than a list of headlines
          child: ListTileTheme.merge(
            titleTextStyle: const TextStyle(fontSize: 15, fontWeight: FontWeight.w500, color: L360Colors.ink),
            subtitleTextStyle: const TextStyle(fontSize: 13, color: L360Colors.sand600),
            child: ListView(
              padding: const EdgeInsets.fromLTRB(L360.gutter, 8, L360.gutter, 32),
              children: [
                _ProfileCard(profile: p),
                const SizedBox(height: 16),
                const _StorageCard(),
                const SizedBox(height: 24),
                GroupedSection(
                  title: 'Settings',
                  children: [
                    ListTile(
                      key: const Key('account-offline'),
                      leading: const TileIcon(Icons.download_for_offline_outlined),
                      title: const Text('Offline maps'),
                      subtitle: const Text('Areas saved on this phone'),
                      trailing: chevron(),
                      // Back to the map, which opens the sheet: framing an area needs the map
                      onTap: () {
                        final router = GoRouter.of(context);
                        router.canPop() ? router.pop() : router.go('/');
                        ref.read(offlineSheetRequestProvider.notifier).open();
                      },
                    ),
                    ListTile(
                      leading: const TileIcon(Icons.lock_outline),
                      title: const Text('Change password'),
                      trailing: chevron(),
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
                        trailing: chevron(),
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
                  title: 'Help',
                  children: [
                    ListTile(
                      key: const Key('account-about'),
                      leading: const TileIcon(Icons.info_outline),
                      title: const Text('About Landscape 360'),
                      subtitle: const Text('Version, privacy, terms and support'),
                      trailing: chevron(),
                      onTap: () => context.push('/about'),
                    ),
                  ],
                ),
                OutlinedButton.icon(
                  key: const Key('sign-out'),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: L360Colors.brick500,
                    side: const BorderSide(color: Color(0xFFF0C9C5)),
                    backgroundColor: Colors.white,
                  ),
                  onPressed: () => _signOut(context, ref),
                  icon: const Icon(Icons.logout, size: 20),
                  label: const Text('Sign out'),
                ),
                // Rare and final: a quiet link under everything else
                if (!p.isAdmin) ...[
                  const SizedBox(height: 16),
                  Center(
                    child: TextButton(
                      key: const Key('delete-account'),
                      style: TextButton.styleFrom(foregroundColor: L360Colors.sand600),
                      onPressed: () => confirmDeleteAccount(context, ref),
                      child: const Text('Delete account', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w500)),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Plan and role as people read them
String roleLabel(AccountProfile p) => p.role == UserRole.monitor360 ? 'Monitor' : 'Member';

String _initials(String name) {
  final words = name.trim().split(RegExp(r'\s+')).where((w) => w.isNotEmpty).toList();
  if (words.isEmpty) return '?';
  final first = words.first.characters.first;
  final second = words.length > 1 ? words[1].characters.first : '';
  return (first + second).toUpperCase();
}

/// Who is signed in: avatar, name and email, plan and role, contact, Edit
class _ProfileCard extends StatelessWidget {
  const _ProfileCard({required this.profile});

  final AccountProfile profile;

  @override
  Widget build(BuildContext context) {
    final p = profile;
    final hasName = p.displayName.isNotEmpty;
    final name = hasName ? p.displayName : p.email;
    final contact = [
      if (p.organization?.isNotEmpty ?? false) (Icons.groups_outlined, p.organization!),
      if (p.phone?.isNotEmpty ?? false) (Icons.phone_outlined, p.phone!),
    ];
    return Card(
      key: const Key('profile-card'),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                CircleAvatar(
                  radius: 28,
                  backgroundColor: L360Colors.forest700,
                  child: Text(
                    _initials(name),
                    style: const TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.w700),
                  ),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
                      ),
                      if (hasName) ...[
                        const SizedBox(height: 2),
                        Text(
                          p.email,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 13, color: L360Colors.sand500),
                        ),
                      ],
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 14),
            Wrap(
              spacing: 6,
              runSpacing: 6,
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
                Pill(
                  roleLabel(p),
                  background: L360Colors.forest100,
                  foreground: L360Colors.forest700,
                  icon: p.role == UserRole.monitor360 ? Icons.visibility_outlined : Icons.hiking,
                ),
                if (p.canUseSos)
                  const Pill(
                    'S.O.S',
                    background: L360Colors.brick50,
                    foreground: L360Colors.brick600,
                    icon: Icons.emergency_outlined,
                  ),
              ],
            ),
            // A paid plan: when it ends (red in its last week)
            if (planEndText(p, DateTime.now()) case final end?) ...[
              const SizedBox(height: 8),
              Row(
                key: const Key('plan-end'),
                children: [
                  Icon(
                    Icons.event_outlined,
                    size: 15,
                    color: p.endsSoon(DateTime.now()) ? L360Colors.brick600 : L360Colors.sand500,
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      '${p.plan.value} · $end',
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: p.endsSoon(DateTime.now()) ? FontWeight.w700 : FontWeight.w500,
                        color: p.endsSoon(DateTime.now()) ? L360Colors.brick600 : L360Colors.sand500,
                      ),
                    ),
                  ),
                ],
              ),
            ],
            const SizedBox(height: 14),
            const Divider(height: 1),
            const SizedBox(height: 6),
            for (final (icon, text) in contact)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: Row(
                  children: [
                    Icon(icon, size: 18, color: L360Colors.sand500),
                    const SizedBox(width: 10),
                    Expanded(child: Text(text, style: const TextStyle(fontSize: 14))),
                  ],
                ),
              ),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                key: const Key('edit-profile'),
                style: TextButton.styleFrom(padding: const EdgeInsets.symmetric(horizontal: 4)),
                onPressed: () => context.push('/account/edit'),
                icon: const Icon(Icons.edit_outlined, size: 18),
                label: Text(contact.isEmpty ? 'Add name, organization and phone' : 'Edit profile'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Cloud storage: how much is used, of what plan limit, split by kind
class _StorageCard extends ConsumerWidget {
  const _StorageCard();

  static const _colors = [L360Colors.forest700, L360Colors.ember500, L360Colors.gold400, L360Colors.forest300];

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final u = ref.watch(storageUsageProvider).value;
    if (u == null) return const SizedBox.shrink();
    final level = usageLevel(u.percent);
    final total = u.limitBytes ?? u.usedBytes;
    final parts = u.breakdown;
    return Card(
      key: const Key('storage-card'),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                const Expanded(
                  child: Text('Cloud storage', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
                ),
                Text(
                  u.percent == null ? 'Unlimited' : '${u.percent!.round()}% used',
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: level == UsageLevel.critical ? L360Colors.brick500 : L360Colors.sand600,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text.rich(
              TextSpan(
                children: [
                  TextSpan(
                    text: formatBytes(u.usedBytes),
                    style: const TextStyle(fontWeight: FontWeight.w700, color: L360Colors.ink),
                  ),
                  TextSpan(text: u.limitBytes == null ? ' used' : ' of ${formatBytes(u.limitBytes!)}'),
                ],
              ),
              style: const TextStyle(fontSize: 13, color: L360Colors.sand600),
            ),
            const SizedBox(height: 12),
            // One bar, a segment per kind of data
            ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: SizedBox(
                height: 8,
                child: ColoredBox(
                  color: L360Colors.sand100,
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      for (final (i, (_, bytes)) in parts.indexed)
                        if (bytes > 0 && total > 0)
                          Expanded(
                            flex: (bytes * 1000 / total).round().clamp(1, 1000),
                            child: ColoredBox(color: _colors[i % _colors.length]),
                          ),
                      if (total > u.usedBytes)
                        Expanded(
                          flex: ((total - u.usedBytes) * 1000 / total).round().clamp(1, 1000),
                          child: const SizedBox(),
                        ),
                    ],
                  ),
                ),
              ),
            ),
            const SizedBox(height: 14),
            for (final (i, (label, bytes)) in parts.indexed)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Row(
                  children: [
                    Container(
                      width: 8,
                      height: 8,
                      decoration: BoxDecoration(color: _colors[i % _colors.length], shape: BoxShape.circle),
                    ),
                    const SizedBox(width: 10),
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
    this.icon,
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
  final IconData? icon; // none for long text, where a centred icon would float
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
        prefixIcon: icon == null ? null : Icon(icon, size: 20),
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
