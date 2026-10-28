import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show ProviderListenable;
import 'package:go_router/go_router.dart';

import '../../core/providers.dart';
import '../../core/theme/app_theme.dart';
import '../../core/ui/widgets.dart';
import '../../data/account/account_repository.dart';
import '../../domain/sos/sos.dart' show emergencyContactsKey;
import '../../domain/sos/sos_outbox.dart' show sosOutboxKey;
import '../basemaps/basemap_state.dart';
import '../live/live_tracking_state.dart';
import '../sos/sos_state.dart';
import '../tracks/track_recorder_state.dart';
import 'account_screen.dart' show FormFieldRow;

// Delete account (App Store 5.1.1(v), Google Play account deletion), in two steps: what is
// deleted, then the password and DELETE typed. The server deletes the account and its data;
// the app then removes what this account left on the phone.

/// Reads a provider (WidgetRef.read or ProviderContainer.read)
typedef ProviderReader = T Function<T>(ProviderListenable<T> provider);

/// What the account leaves on the phone, removed after the server deleted the account
Future<void> deleteAccountData(ProviderReader read, String userId, List<String> basemapIds) async {
  final store = read(trackLocalStoreProvider);
  for (final t in await store.listTracks(userId)) {
    await store.deleteTrack(t.id);
  }
  final files = read(basemapFilesProvider);
  for (final id in basemapIds) {
    await files.remove(id);
  }
  final prefs = read(sosPrefsProvider);
  await prefs.remove(emergencyContactsKey(userId));
  await prefs.remove(sosOutboxKey);
  await read(basemapPrefsProvider).remove('l360-basemap-opacity-$userId');
}

/// Step 1: what deleting means. Busy features (a recording, S.O.S) must end first.
Future<void> confirmDeleteAccount(BuildContext context, WidgetRef ref) async {
  final busy = ref.read(trackRecorderProvider).active != null
      ? 'Stop and save the track you are recording first.'
      : ref.read(sosProvider).phase != SosPhase.closed
      ? 'Close the S.O.S screen first.'
      : null;
  if (busy != null) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(busy)));
    return;
  }
  final go = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog.adaptive(
      title: const Text('Delete your account?'),
      content: const Text(
        'Your account and everything in it are deleted for good: surveys, recorded tracks, '
        'marked locations and areas, the links and shares made from them, custom basemaps, '
        'offline map list and S.O.S history. Shared links stop working. This cannot be undone.',
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
        TextButton(
          key: const Key('delete-account-continue'),
          onPressed: () => Navigator.pop(context, true),
          style: TextButton.styleFrom(foregroundColor: L360Colors.brick500),
          child: const Text('Continue'),
        ),
      ],
    ),
  );
  if (go == true && context.mounted) await context.push('/account/delete');
}

/// Step 2: the password and DELETE typed
class DeleteAccountScreen extends ConsumerStatefulWidget {
  const DeleteAccountScreen({super.key});

  @override
  ConsumerState<DeleteAccountScreen> createState() => _DeleteAccountScreenState();
}

class _DeleteAccountScreenState extends ConsumerState<DeleteAccountScreen> {
  final _password = TextEditingController();
  final _typed = TextEditingController();
  bool _busy = false;
  bool _show = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _typed.addListener(() => setState(() {}));
    _password.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _password.dispose();
    _typed.dispose();
    super.dispose();
  }

  bool get _ready => _password.text.isNotEmpty && _typed.text.trim() == 'DELETE';

  Future<void> _delete() async {
    final profile = ref.read(profileProvider).value;
    if (profile == null || !_ready) return;
    FocusScope.of(context).unfocus();
    setState(() {
      _busy = true;
      _error = null;
    });
    // Taken before the session ends: this screen is replaced as soon as it does
    final router = GoRouter.of(context);
    final messenger = ScaffoldMessenger.of(context);
    final basemapIds = [for (final b in ref.read(basemapsProvider).basemaps) b.id];
    final read = ref.read;
    try {
      await read(liveTrackingProvider.notifier).stop();
      await read(accountRepositoryProvider).deleteAccount(password: _password.text);
      await deleteAccountData(read, profile.userId, basemapIds);
      messenger.showSnackBar(const SnackBar(content: Text('Your account has been deleted.')));
      router.go('/');
    } on AccountException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } on Object catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = ref.watch(profileProvider).value;
    return Scaffold(
      appBar: AppBar(title: const Text('Delete account')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(L360.gutter),
          children: [
            if (p?.isAdmin ?? false)
              const ErrorBanner('The admin account cannot be deleted. Contact support at contact@jcdigital.co.id.')
            else ...[
              Text(
                'Enter the password of ${p?.email ?? 'your account'} and type DELETE to delete the account for good.',
                style: const TextStyle(color: L360Colors.sand700),
              ),
              const SizedBox(height: 16),
              FormFieldRow(
                fieldKey: const Key('delete-password'),
                controller: _password,
                label: 'Password',
                icon: Icons.lock_outline,
                obscure: !_show,
                autofill: const [AutofillHints.password],
                suffix: IconButton(
                  tooltip: _show ? 'Hide password' : 'Show password',
                  icon: Icon(_show ? Icons.visibility_off_outlined : Icons.visibility_outlined, size: 20),
                  onPressed: () => setState(() => _show = !_show),
                ),
              ),
              FormFieldRow(
                fieldKey: const Key('delete-typed'),
                controller: _typed,
                label: 'Type DELETE',
                icon: Icons.warning_amber_outlined,
                textInputAction: TextInputAction.done,
                onSubmitted: (_) => _busy ? null : _delete(),
              ),
              if (_error != null) ...[ErrorBanner(_error!), const SizedBox(height: 12)],
              const SizedBox(height: 8),
              FilledButton(
                key: const Key('delete-account-confirm'),
                style: FilledButton.styleFrom(backgroundColor: L360Colors.brick500),
                onPressed: _busy || !_ready ? null : _delete,
                child: _busy
                    ? const SizedBox.square(
                        dimension: 20,
                        child: CircularProgressIndicator(strokeWidth: 2.5, color: Colors.white),
                      )
                    : const Text('Delete my account forever'),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
