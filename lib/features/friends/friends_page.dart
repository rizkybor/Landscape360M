import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:share_plus/share_plus.dart';

import '../../core/providers.dart';
import '../../core/theme/app_theme.dart';
import '../../core/ui/widgets.dart';
import '../../data/community/community_repository.dart' show CommunityException;
import '../../domain/friends/friends.dart';
import '../community/community_widgets.dart' show EmptyState, confirmDialog;
import 'chat_page.dart';
import 'friends_state.dart';

// Friends (User Account → Friends): Chats, the most recent first, and Friends with the requests
// to answer; Add friend by email, by scanning a friend's QR, or by sharing my own QR / link; and
// the card a friend link (/?friend=) opens.

String _message(Object e) => e is CommunityException ? e.message : '$e';

Future<void> openFriends(BuildContext context) =>
    Navigator.of(context, rootNavigator: true).push(MaterialPageRoute<void>(builder: (_) => const FriendsPage()));

/// A friend's first letter on a soft colour picked from their name (the same colour everywhere)
class FriendAvatar extends StatelessWidget {
  const FriendAvatar({super.key, required this.name, this.size = 40});

  final String name;
  final double size;

  static const _palette = [
    (L360Colors.forest100, L360Colors.forest800),
    (L360Colors.gold100, L360Colors.gold700),
    (Color(0xFFFBE3D3), L360Colors.ember600),
    (Color(0xFFDDE7F5), Color(0xFF2A5C9A)),
    (L360Colors.sand200, L360Colors.sand700),
  ];

  @override
  Widget build(BuildContext context) {
    final n = name.trim();
    final (bg, fg) = _palette[n.codeUnits.fold(0, (a, b) => a + b) % _palette.length];
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(color: bg, shape: BoxShape.circle),
      child: Text(
        n.isEmpty ? '?' : String.fromCharCode(n.runes.first).toUpperCase(),
        style: TextStyle(fontSize: size * 0.4, fontWeight: FontWeight.w700, color: fg),
      ),
    );
  }
}

class FriendsPage extends ConsumerStatefulWidget {
  const FriendsPage({super.key});

  @override
  ConsumerState<FriendsPage> createState() => _FriendsPageState();
}

class _FriendsPageState extends ConsumerState<FriendsPage> {
  // Read here, not in dispose (ref is gone by then)
  late final FriendsController _friends;

  @override
  void initState() {
    super.initState();
    _friends = ref.read(friendsProvider.notifier);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _friends.watch();
    });
  }

  @override
  void dispose() {
    _friends.unwatch();
    super.dispose();
  }

  // 0 Chats, 1 Friends; QR and Add friend open a sheet and keep the page where it is
  int _tab = 0;

  void _select(int i) {
    switch (i) {
      case 2:
        unawaited(showMyFriendCode(context));
      case 3:
        unawaited(showAddFriend(context));
      default:
        setState(() => _tab = i);
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = ref.watch(friendsProvider);
    final incoming = s.incoming.length;
    final unread = s.chats.where((f) => f.unread > 0).length;
    return Scaffold(
      appBar: AppBar(
        toolbarHeight: 68,
        backgroundColor: Colors.white,
        surfaceTintColor: Colors.white,
        shape: const Border(bottom: BorderSide(color: L360Colors.sand200)),
        title: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(4),
              decoration: BoxDecoration(color: L360Colors.sand50, borderRadius: BorderRadius.circular(12)),
              child: Image.asset('assets/images/logo.png', key: const Key('friends-logo'), width: 36, height: 36),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    _tab == 0 ? 'Chats' : 'Friends',
                    style: const TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.w800,
                      color: L360Colors.ink,
                      height: 1.1,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    _tab == 0
                        ? (unread == 0 ? 'All caught up' : '$unread unread ${unread == 1 ? 'chat' : 'chats'}')
                        : '${s.friends.length} ${s.friends.length == 1 ? 'friend' : 'friends'}'
                              '${incoming > 0 ? ' · $incoming new ${incoming == 1 ? 'request' : 'requests'}' : ''}',
                    style: const TextStyle(fontSize: 11.5, fontWeight: FontWeight.w500, color: L360Colors.sand600),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
      body: Column(
        children: [
          if (s.error != null)
            Padding(padding: const EdgeInsets.fromLTRB(L360.gutter, 8, L360.gutter, 0), child: ErrorBanner(s.error!)),
          Expanded(
            child: IndexedStack(
              index: _tab,
              children: [
                _ChatsTab(state: s),
                _FriendsTab(state: s),
              ],
            ),
          ),
        ],
      ),
      bottomNavigationBar: _NavBar(
        selected: _tab,
        onSelect: _select,
        items: [
          _NavItem(
            const Key('friends-tab-chats'),
            Icons.chat_bubble_outline_rounded,
            Icons.chat_bubble_rounded,
            'Chats',
            dot: unread > 0,
          ),
          _NavItem(
            const Key('friends-tab-friends'),
            Icons.people_outline_rounded,
            Icons.people_rounded,
            'Friends',
            dot: incoming > 0,
            dotKey: const Key('friends-request-dot'),
          ),
          const _NavItem(Key('friends-my-qr'), Icons.qr_code_2_rounded, Icons.qr_code_2_rounded, 'My QR'),
          const _NavItem(Key('friends-add'), Icons.person_add_alt_1_outlined, Icons.person_add_alt_1, 'Add friend'),
        ],
      ),
    );
  }
}

class _NavItem {
  const _NavItem(this.key, this.icon, this.activeIcon, this.label, {this.dot = false, this.dotKey});

  final Key key;
  final IconData icon;
  final IconData activeIcon;
  final String label;
  final bool dot;
  final Key? dotKey;
}

/// A floating white bar: four equal items, icon over label; the open one sits on a soft green pill
class _NavBar extends StatelessWidget {
  const _NavBar({required this.selected, required this.onSelect, required this.items});

  final int selected;
  final ValueChanged<int> onSelect;
  final List<_NavItem> items;

  @override
  Widget build(BuildContext context) => SafeArea(
    top: false,
    minimum: const EdgeInsets.only(bottom: 8),
    child: Padding(
      padding: const EdgeInsets.fromLTRB(L360.gutter, 6, L360.gutter, 4),
      child: Container(
        height: 66,
        padding: const EdgeInsets.symmetric(horizontal: 6),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(22),
          border: Border.all(color: L360Colors.sand200),
          boxShadow: const [BoxShadow(color: Color(0x141E3C13), blurRadius: 16, offset: Offset(0, 4))],
        ),
        child: Row(
          children: [
            for (final (i, item) in items.indexed)
              Expanded(
                child: _NavButton(item: item, active: i == selected, onTap: () => onSelect(i)),
              ),
          ],
        ),
      ),
    ),
  );
}

class _NavButton extends StatelessWidget {
  const _NavButton({required this.item, required this.active, required this.onTap});

  final _NavItem item;
  final bool active;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    selected: active,
    label: item.label,
    excludeSemantics: true,
    child: InkResponse(
      key: item.key,
      onTap: onTap,
      radius: 32,
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          AnimatedContainer(
            duration: const Duration(milliseconds: 200),
            curve: Curves.easeOutCubic,
            width: 52,
            height: 30,
            decoration: BoxDecoration(
              color: active ? L360Colors.forest100 : Colors.transparent,
              borderRadius: BorderRadius.circular(15),
            ),
            child: Stack(
              clipBehavior: Clip.none,
              alignment: Alignment.center,
              children: [
                Icon(
                  active ? item.activeIcon : item.icon,
                  size: 22,
                  color: active ? L360Colors.forest800 : L360Colors.sand500,
                ),
                if (item.dot)
                  Positioned(
                    top: 2,
                    right: 12,
                    child: Container(
                      key: item.dotKey,
                      width: 9,
                      height: 9,
                      decoration: BoxDecoration(
                        color: L360Colors.ember500,
                        shape: BoxShape.circle,
                        border: Border.all(color: active ? L360Colors.forest100 : Colors.white, width: 1.5),
                      ),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 3),
          Text(
            item.label,
            maxLines: 1,
            style: TextStyle(
              fontSize: 11,
              fontWeight: active ? FontWeight.w700 : FontWeight.w500,
              color: active ? L360Colors.forest800 : L360Colors.sand500,
            ),
          ),
        ],
      ),
    ),
  );
}

class _ChatsTab extends ConsumerWidget {
  const _ChatsTab({required this.state});

  final FriendsState state;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final chats = state.chats;
    final now = DateTime.now();
    return RefreshIndicator(
      onRefresh: ref.read(friendsProvider.notifier).refresh,
      child: ListView(
        key: const Key('friends-chats'),
        padding: const EdgeInsets.fromLTRB(L360.gutter, 16, L360.gutter, 24),
        children: [
          if (chats.isEmpty && state.loaded)
            EmptyState(
              icon: Icons.forum_outlined,
              title: 'No chats yet',
              text: state.friends.isEmpty
                  ? 'Add a friend by email or with your QR code, then send them a message or your location.'
                  : 'Open a friend in Friends to send a message.',
            )
          else if (chats.isEmpty)
            const Padding(
              padding: EdgeInsets.all(32),
              child: Center(child: CircularProgressIndicator()),
            )
          else ...[
            const Padding(
              padding: EdgeInsets.only(left: 4, bottom: 6),
              child: Text(
                'RECENT',
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                  color: L360Colors.sand600,
                  letterSpacing: 0.8,
                ),
              ),
            ),
            for (final (i, f) in chats.indexed) ...[
              if (i > 0) const Divider(height: 1, indent: 54, color: L360Colors.sand200),
              _ChatRow(friend: f, now: now),
            ],
          ],
        ],
      ),
    );
  }
}

/// One chat: avatar, name, the last message (an icon for a location or map data), when, unread
class _ChatRow extends StatelessWidget {
  const _ChatRow({required this.friend, required this.now});

  final Friend friend;
  final DateTime now;

  @override
  Widget build(BuildContext context) {
    final f = friend;
    final unread = f.unread > 0;
    final icon = f.lastDeleted
        ? Icons.block
        : switch (f.lastKind) {
            ChatKind.location => Icons.my_location,
            ChatKind.attachment => Icons.timeline,
            _ => null,
          };
    final preview = (f.preview ?? '').replaceFirst(RegExp(r'^You: '), '');
    return InkWell(
      key: Key('chat-${f.userId}'),
      onTap: () => openChat(context, f.userId, f.name),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(4, 10, 4, 10),
        child: Row(
          children: [
            FriendAvatar(name: f.name, size: 38),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          f.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 14,
                            fontWeight: unread ? FontWeight.w800 : FontWeight.w600,
                            color: L360Colors.ink,
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Text(
                        chatTime(f.lastAt!, now),
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: unread ? FontWeight.w700 : FontWeight.w500,
                          color: unread ? L360Colors.ember600 : L360Colors.sand500,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 2),
                  Row(
                    children: [
                      if (f.lastFromMe && !f.lastDeleted)
                        const Padding(
                          padding: EdgeInsets.only(right: 4),
                          child: Text('You:', style: TextStyle(fontSize: 12.5, color: L360Colors.sand500)),
                        ),
                      if (icon != null) ...[
                        Icon(icon, size: 13.5, color: unread ? L360Colors.forest700 : L360Colors.sand500),
                        const SizedBox(width: 4),
                      ],
                      Expanded(
                        child: Text(
                          preview,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 12.5,
                            fontStyle: f.lastDeleted ? FontStyle.italic : FontStyle.normal,
                            fontWeight: unread ? FontWeight.w600 : FontWeight.normal,
                            color: unread ? L360Colors.ink : L360Colors.sand600,
                          ),
                        ),
                      ),
                      if (unread) ...[const SizedBox(width: 8), _Count(f.unread)],
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Count extends StatelessWidget {
  const _Count(this.n);

  final int n;

  @override
  Widget build(BuildContext context) => Container(
    constraints: const BoxConstraints(minWidth: 18),
    height: 18,
    alignment: Alignment.center,
    padding: const EdgeInsets.symmetric(horizontal: 5),
    decoration: BoxDecoration(color: L360Colors.ember500, borderRadius: BorderRadius.circular(9)),
    child: Text(
      n > 99 ? '99+' : '$n',
      style: const TextStyle(fontSize: 10.5, fontWeight: FontWeight.w800, color: Colors.white),
    ),
  );
}

class _FriendsTab extends ConsumerStatefulWidget {
  const _FriendsTab({required this.state});

  final FriendsState state;

  @override
  ConsumerState<_FriendsTab> createState() => _FriendsTabState();
}

class _FriendsTabState extends ConsumerState<_FriendsTab> {
  bool _busy = false;
  String? _error;

  Future<void> _run(Future<void> Function() fn) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await fn();
    } on Object catch (e) {
      if (mounted) setState(() => _error = _message(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _remove(Friend f) async {
    if (!await confirmDialog(
      context,
      title: 'Remove ${f.name}?',
      message: 'You will no longer be able to message each other. Your chat stays readable.',
      action: 'Remove',
    )) {
      return;
    }
    await _run(() => ref.read(friendsProvider.notifier).remove(f.userId));
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.state;
    final ctrl = ref.read(friendsProvider.notifier);
    const label = TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: L360Colors.sand600, letterSpacing: 0.6);
    Widget header(String t) => Padding(
      padding: const EdgeInsets.fromLTRB(L360.gutter, 16, L360.gutter, 4),
      child: Text(t.toUpperCase(), style: label),
    );
    return RefreshIndicator(
      onRefresh: ctrl.refresh,
      child: ListView(
        key: const Key('friends-list'),
        padding: const EdgeInsets.only(bottom: 24),
        children: [
          if (_error != null)
            Padding(padding: const EdgeInsets.fromLTRB(L360.gutter, 8, L360.gutter, 0), child: ErrorBanner(_error!)),
          if (s.incoming.isNotEmpty) ...[
            header('Requests'),
            for (final r in s.incoming)
              ListTile(
                key: Key('request-${r.id}'),
                leading: FriendAvatar(name: r.name),
                title: Text(r.name),
                subtitle: r.organization == null ? null : Text(r.organization!),
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    IconButton(
                      key: Key('request-decline-${r.id}'),
                      tooltip: 'Decline',
                      icon: const Icon(Icons.close, color: L360Colors.sand600),
                      onPressed: _busy ? null : () => _run(() => ctrl.answer(r, accept: false)),
                    ),
                    IconButton.filled(
                      key: Key('request-accept-${r.id}'),
                      tooltip: 'Accept',
                      style: IconButton.styleFrom(backgroundColor: L360Colors.forest700),
                      icon: const Icon(Icons.check),
                      onPressed: _busy ? null : () => _run(() => ctrl.answer(r, accept: true)),
                    ),
                  ],
                ),
              ),
          ],
          header('Friends · ${s.friends.length}'),
          if (s.friends.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: L360.gutter, vertical: 8),
              child: Text(
                s.loaded
                    ? 'No friends yet. Tap Add friend to send a request by email, or show your QR code.'
                    : 'Loading…',
                style: const TextStyle(color: L360Colors.sand600),
              ),
            ),
          for (final f in s.friends)
            ListTile(
              key: Key('friend-${f.userId}'),
              leading: FriendAvatar(name: f.name),
              title: Text(f.name),
              subtitle: f.organization == null ? null : Text(f.organization!),
              onTap: () => openChat(context, f.userId, f.name),
              trailing: PopupMenuButton<String>(
                key: Key('friend-menu-${f.userId}'),
                enabled: !_busy,
                onSelected: (v) => v == 'remove' ? _remove(f) : openChat(context, f.userId, f.name),
                itemBuilder: (_) => const [
                  PopupMenuItem(value: 'chat', child: Text('Message')),
                  PopupMenuItem(value: 'remove', child: Text('Remove friend')),
                ],
              ),
            ),
          if (s.outgoing.isNotEmpty) ...[
            header('Waiting for an answer'),
            for (final r in s.outgoing)
              ListTile(
                key: Key('outgoing-${r.id}'),
                leading: FriendAvatar(name: r.name),
                title: Text(r.name),
                subtitle: const Text('Request sent'),
              ),
          ],
        ],
      ),
    );
  }
}

// --- Add friend ----------------------------------------------------------------------------------

Future<void> showAddFriend(BuildContext context) => showModalBottomSheet<void>(
  context: context,
  isScrollControlled: true,
  useSafeArea: true,
  builder: (_) => const _AddFriendSheet(),
);

class _AddFriendSheet extends ConsumerStatefulWidget {
  const _AddFriendSheet();

  @override
  ConsumerState<_AddFriendSheet> createState() => _AddFriendSheetState();
}

class _AddFriendSheetState extends ConsumerState<_AddFriendSheet> {
  final _email = TextEditingController();
  bool _busy = false;
  String? _error;
  String? _done;

  @override
  void dispose() {
    _email.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    final email = _email.text.trim();
    if (!email.contains('@')) return setState(() => _error = 'Enter the email of their Landscape 360 account.');
    setState(() {
      _busy = true;
      _error = null;
      _done = null;
    });
    try {
      await ref.read(friendsProvider.notifier).requestByEmail(email);
      _email.clear();
      // The same answer whether or not the account exists (their email stays private)
      if (mounted) setState(() => _done = 'Request sent if a Landscape 360 account uses $email.');
    } on Object catch (e) {
      if (mounted) setState(() => _error = _message(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _scan() async {
    final token = await Navigator.of(
      context,
      rootNavigator: true,
    ).push<String>(MaterialPageRoute(fullscreenDialog: true, builder: (_) => const FriendQrScanner()));
    if (token == null || !mounted) return;
    Navigator.of(context).pop();
    await openFriendLink(context, token);
  }

  @override
  Widget build(BuildContext context) => Padding(
    padding: EdgeInsets.fromLTRB(L360.gutter, 8, L360.gutter, 16 + MediaQuery.viewInsetsOf(context).bottom),
    child: SingleChildScrollView(
      child: Column(
        key: const Key('add-friend'),
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('Add friend', style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 12),
          TextField(
            key: const Key('add-friend-email'),
            controller: _email,
            keyboardType: TextInputType.emailAddress,
            autocorrect: false,
            decoration: const InputDecoration(labelText: 'Their email', hintText: 'name@example.com'),
            onSubmitted: (_) => _busy ? null : _send(),
          ),
          const SizedBox(height: 8),
          if (_error != null) ...[ErrorBanner(_error!), const SizedBox(height: 8)],
          if (_done != null) ...[
            Text(
              _done!,
              key: const Key('add-friend-done'),
              style: const TextStyle(color: L360Colors.forest700),
            ),
            const SizedBox(height: 8),
          ],
          KeyedSubtree(
            key: const Key('add-friend-send'),
            child: BusyButton(label: 'Send request', busy: _busy, onPressed: _send),
          ),
          const SizedBox(height: 20),
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  key: const Key('add-friend-scan'),
                  style: OutlinedButton.styleFrom(minimumSize: const Size(0, 48)),
                  onPressed: _scan,
                  icon: const Icon(Icons.qr_code_scanner),
                  label: const Text('Scan QR'),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: OutlinedButton.icon(
                  key: const Key('add-friend-my-qr'),
                  style: OutlinedButton.styleFrom(minimumSize: const Size(0, 48)),
                  onPressed: () => showMyFriendCode(context),
                  icon: const Icon(Icons.qr_code_2),
                  label: const Text('My QR'),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          const Text(
            'Meeting in person? One of you shows My QR, the other scans it.',
            style: TextStyle(fontSize: 12, color: L360Colors.sand600),
          ),
        ],
      ),
    ),
  );
}

/// My QR code and link: anyone who opens it can ask me to be friends
Future<void> showMyFriendCode(BuildContext context) => showModalBottomSheet<void>(
  context: context,
  isScrollControlled: true,
  useSafeArea: true,
  builder: (_) => const _MyFriendCode(),
);

class _MyFriendCode extends ConsumerStatefulWidget {
  const _MyFriendCode();

  @override
  ConsumerState<_MyFriendCode> createState() => _MyFriendCodeState();
}

class _MyFriendCodeState extends ConsumerState<_MyFriendCode> {
  String? _token;
  String? _error;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    unawaited(_load(() => ref.read(friendsRepositoryProvider).myLink()));
  }

  Future<void> _load(Future<String> Function() fn) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final t = await fn();
      if (mounted) setState(() => _token = t);
    } on Object catch (e) {
      if (mounted) setState(() => _error = _message(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _renew() async {
    if (!await confirmDialog(
      context,
      title: 'Make a new code?',
      message: 'Your current QR code and link stop working. Friends you have keep being your friends.',
      action: 'New code',
      destructive: false,
    )) {
      return;
    }
    await _load(() => ref.read(friendsRepositoryProvider).renewLink());
  }

  @override
  Widget build(BuildContext context) {
    final site = ref.watch(appConfigProvider).apiBaseUrl;
    final token = _token;
    final url = token == null ? null : friendLinkUrl(site, token);
    final me = ref.watch(profileProvider).value;
    return Padding(
      padding: const EdgeInsets.fromLTRB(L360.gutter, 8, L360.gutter, 24),
      child: Column(
        key: const Key('my-friend-code'),
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(me?.displayName ?? 'My code', style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 4),
          const Text(
            'Friends scan this with the Landscape 360 app or their camera.',
            textAlign: TextAlign.center,
            style: TextStyle(color: L360Colors.sand600),
          ),
          const SizedBox(height: 16),
          Container(
            width: 232,
            height: 232,
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: L360Colors.sand200),
            ),
            child: url == null
                ? Center(child: _busy ? const CircularProgressIndicator() : const Icon(Icons.qr_code_2, size: 64))
                : QrImageView(
                    key: const Key('my-friend-qr'),
                    data: url,
                    eyeStyle: const QrEyeStyle(eyeShape: QrEyeShape.square, color: L360Colors.forest800),
                    dataModuleStyle: const QrDataModuleStyle(
                      dataModuleShape: QrDataModuleShape.square,
                      color: L360Colors.forest800,
                    ),
                  ),
          ),
          if (_error != null) ...[const SizedBox(height: 12), ErrorBanner(_error!)],
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  key: const Key('my-friend-renew'),
                  onPressed: _busy || url == null ? null : _renew,
                  icon: const Icon(Icons.refresh, size: 18),
                  label: const Text('New code'),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: FilledButton.icon(
                  key: const Key('my-friend-share'),
                  style: FilledButton.styleFrom(minimumSize: const Size(0, 44)),
                  onPressed: url == null
                      ? null
                      : () => SharePlus.instance.share(ShareParams(text: 'Add me as a friend on Landscape 360: $url')),
                  icon: const Icon(Icons.ios_share, size: 18),
                  label: const Text('Share link'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// The camera, until a friend QR (or link) is seen; returns its token
class FriendQrScanner extends StatefulWidget {
  const FriendQrScanner({super.key});

  @override
  State<FriendQrScanner> createState() => _FriendQrScannerState();
}

class _FriendQrScannerState extends State<FriendQrScanner> {
  bool _done = false;
  String? _hint;

  void _seen(BarcodeCapture capture) {
    if (_done) return;
    for (final b in capture.barcodes) {
      final raw = b.rawValue ?? '';
      final uri = Uri.tryParse(raw);
      final token = uri == null ? null : parseFriendParam(uri.query);
      if (token != null) {
        _done = true;
        Navigator.of(context).pop(token);
        return;
      }
    }
    if (_hint == null) setState(() => _hint = 'That is not a Landscape 360 friend code.');
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: Colors.black,
    appBar: AppBar(
      backgroundColor: Colors.black,
      foregroundColor: Colors.white,
      title: const Text('Scan a friend code'),
    ),
    body: Stack(
      fit: StackFit.expand,
      children: [
        MobileScanner(
          onDetect: _seen,
          errorBuilder: (context, error) => Center(
            child: Padding(
              padding: const EdgeInsets.all(32),
              child: Text(
                error.errorCode == MobileScannerErrorCode.permissionDenied
                    ? 'Allow the camera for Landscape 360 in Settings to scan a friend code.'
                    : 'The camera is not available.',
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.white),
              ),
            ),
          ),
        ),
        Center(
          child: Container(
            width: 240,
            height: 240,
            decoration: BoxDecoration(
              border: Border.all(color: Colors.white, width: 3),
              borderRadius: BorderRadius.circular(20),
            ),
          ),
        ),
        if (_hint != null)
          Positioned(
            left: 24,
            right: 24,
            bottom: 48,
            child: Text(
              _hint!,
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600),
            ),
          ),
      ],
    ),
  );
}

// --- A friend link -------------------------------------------------------------------------------

/// The card of a friend link or QR: who it is and Add friend (sign in first)
Future<void> openFriendLink(BuildContext context, String token) => showModalBottomSheet<void>(
  context: context,
  useRootNavigator: true,
  builder: (_) => _FriendLinkCard(token: token),
);

class _FriendLinkCard extends ConsumerStatefulWidget {
  const _FriendLinkCard({required this.token});

  final String token;

  @override
  ConsumerState<_FriendLinkCard> createState() => _FriendLinkCardState();
}

class _FriendLinkCardState extends ConsumerState<_FriendLinkCard> {
  ({String name, String? organization, bool isMe})? _card;
  bool _loading = true;
  bool _busy = false;
  String? _error;
  String? _result;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    try {
      final c = await ref.read(friendsRepositoryProvider).linkCard(widget.token);
      if (!mounted) return;
      setState(() {
        _card = c;
        _loading = false;
        if (c == null) _error = 'This friend link is no longer valid.';
      });
    } on Object catch (e) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = _message(e);
        });
      }
    }
  }

  Future<void> _add() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final r = await ref.read(friendsProvider.notifier).requestByLink(widget.token);
      if (mounted) {
        setState(
          () => _result = r == 'friends' ? 'You are now friends.' : 'Request sent. They will see it in Friends.',
        );
      }
    } on Object catch (e) {
      if (mounted) setState(() => _error = _message(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = _card;
    final signedIn = ref.watch(authUserIdProvider).value != null;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(L360.gutter, 12, L360.gutter, 20),
        child: Column(
          key: const Key('friend-link-card'),
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (_loading)
              const Padding(
                padding: EdgeInsets.all(24),
                child: Center(child: CircularProgressIndicator()),
              )
            else if (c != null) ...[
              Center(child: FriendAvatar(name: c.name, size: 64)),
              const SizedBox(height: 10),
              Text(c.name, textAlign: TextAlign.center, style: Theme.of(context).textTheme.titleLarge),
              if (c.organization?.isNotEmpty ?? false)
                Text(
                  c.organization!,
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: L360Colors.sand600),
                ),
              const SizedBox(height: 16),
            ],
            if (_error != null) ...[ErrorBanner(_error!), const SizedBox(height: 8)],
            if (_result != null)
              Text(
                _result!,
                key: const Key('friend-link-result'),
                textAlign: TextAlign.center,
                style: const TextStyle(color: L360Colors.forest700, fontWeight: FontWeight.w600),
              )
            else if (c != null && c.isMe)
              const Text('This is your own code.', textAlign: TextAlign.center)
            else if (c != null && !signedIn)
              const Text('Sign in to add friends.', textAlign: TextAlign.center)
            else if (c != null)
              KeyedSubtree(
                key: const Key('friend-link-add'),
                child: BusyButton(label: 'Add friend', busy: _busy, onPressed: _add),
              ),
          ],
        ),
      ),
    );
  }
}
