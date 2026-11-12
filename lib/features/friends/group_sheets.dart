import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers.dart';
import '../../core/theme/app_theme.dart';
import '../../core/ui/widgets.dart';
import '../../data/community/community_repository.dart' show CommunityException;
import '../../domain/account/profile.dart';
import '../../domain/friends/friends.dart';
import '../community/community_widgets.dart' show confirmDialog;
import 'chat_page.dart' show openGroupChat;
import 'friends_page.dart' show FriendAvatar;
import 'friends_state.dart';

// Groups: the avatar, making a group from friends (Pro and up), and a group's members (the
// maker adds friends and removes members, renames and deletes; others leave; a club chat's
// members are the club's, so there is nothing to add or remove)

String _message(Object e) => e is CommunityException ? e.message : '$e';

bool canMakeGroups(AccountProfile? p) => p != null && (p.isAdmin || p.plan == Plan.pro || p.plan == Plan.enterprise);

/// A group's icon: people for a group, a shield for a club chat
class GroupAvatar extends StatelessWidget {
  const GroupAvatar({super.key, required this.isClub, this.size = 40});

  final bool isClub;
  final double size;

  @override
  Widget build(BuildContext context) => Container(
    width: size,
    height: size,
    alignment: Alignment.center,
    decoration: BoxDecoration(color: isClub ? L360Colors.gold100 : L360Colors.forest100, shape: BoxShape.circle),
    child: Icon(
      isClub ? Icons.shield_outlined : Icons.groups_outlined,
      size: size * 0.5,
      color: isClub ? L360Colors.gold700 : L360Colors.forest800,
    ),
  );
}

// --- Making a group --------------------------------------------------------------------------------

Future<void> showCreateGroup(BuildContext context) => showModalBottomSheet<void>(
  context: context,
  isScrollControlled: true,
  useSafeArea: true,
  builder: (_) => const _CreateGroupSheet(),
);

class _CreateGroupSheet extends ConsumerStatefulWidget {
  const _CreateGroupSheet();

  @override
  ConsumerState<_CreateGroupSheet> createState() => _CreateGroupSheetState();
}

class _CreateGroupSheetState extends ConsumerState<_CreateGroupSheet> {
  final _name = TextEditingController();
  final _picked = <String>{};
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  Future<void> _create() async {
    final name = _name.text.trim();
    if (name.length < 2) {
      setState(() => _error = 'Give the group a name');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final id = await ref.read(friendsProvider.notifier).createGroup(name, _picked.toList());
      if (!mounted) return;
      Navigator.pop(context);
      await openGroupChat(context, id, name);
    } on Object catch (e) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = _message(e);
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final friends = ref.watch(friendsProvider.select((s) => s.friends));
    final allowed = canMakeGroups(ref.watch(profileProvider).value);
    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.85,
      maxChildSize: 0.95,
      builder: (context, scroll) => Column(
        children: [
          const SizedBox(height: 4),
          Padding(
            padding: const EdgeInsets.fromLTRB(L360.gutter, 8, L360.gutter, 4),
            child: Row(
              children: [
                const GroupAvatar(isClub: false, size: 36),
                const SizedBox(width: 10),
                const Expanded(
                  child: Text('New group', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
                ),
                if (allowed) BusyButton(key: const Key('group-save'), label: 'Create', busy: _busy, onPressed: _create),
              ],
            ),
          ),
          if (!allowed)
            const Padding(
              padding: EdgeInsets.fromLTRB(L360.gutter, 8, L360.gutter, 8),
              child: Text(
                'Making a group is for Pro and Enterprise accounts. You can still be in groups friends add you to.',
                key: Key('group-pro-note'),
                style: TextStyle(color: L360Colors.sand600, height: 1.4),
              ),
            )
          else ...[
            Padding(
              padding: const EdgeInsets.fromLTRB(L360.gutter, 8, L360.gutter, 4),
              child: TextField(
                key: const Key('group-name'),
                controller: _name,
                maxLength: groupNameMax,
                textCapitalization: TextCapitalization.words,
                decoration: const InputDecoration(labelText: 'Group name', hintText: 'Tim Merbabu', counterText: ''),
              ),
            ),
            if (_error != null)
              Padding(padding: const EdgeInsets.fromLTRB(L360.gutter, 0, L360.gutter, 4), child: ErrorBanner(_error!)),
            Padding(
              padding: const EdgeInsets.fromLTRB(L360.gutter, 8, L360.gutter, 4),
              child: Row(
                children: [
                  const Expanded(child: SectionLabel('Friends to add')),
                  Text(
                    _picked.isEmpty ? 'Only you for now' : '${_picked.length} picked',
                    style: const TextStyle(fontSize: 12, color: L360Colors.sand600),
                  ),
                ],
              ),
            ),
            Expanded(
              child: friends.isEmpty
                  ? const Padding(
                      padding: EdgeInsets.all(24),
                      child: Text(
                        'You have no friends yet. You can add them to the group later.',
                        textAlign: TextAlign.center,
                        style: TextStyle(color: L360Colors.sand600),
                      ),
                    )
                  : ListView(
                      controller: scroll,
                      children: [
                        for (final f in friends)
                          CheckboxListTile(
                            key: Key('group-pick-${f.userId}'),
                            value: _picked.contains(f.userId),
                            onChanged: (v) =>
                                setState(() => v == true ? _picked.add(f.userId) : _picked.remove(f.userId)),
                            secondary: FriendAvatar(name: f.name, size: 36),
                            title: Text(f.name),
                            subtitle: f.organization == null ? null : Text(f.organization!),
                            controlAffinity: ListTileControlAffinity.trailing,
                          ),
                      ],
                    ),
            ),
          ],
        ],
      ),
    );
  }
}

// --- A group's members -------------------------------------------------------------------------------

Future<void> showGroupMembers(BuildContext context, String groupId) => showModalBottomSheet<void>(
  context: context,
  isScrollControlled: true,
  useSafeArea: true,
  builder: (_) => _GroupMembersSheet(groupId: groupId),
);

class _GroupMembersSheet extends ConsumerStatefulWidget {
  const _GroupMembersSheet({required this.groupId});

  final String groupId;

  @override
  ConsumerState<_GroupMembersSheet> createState() => _GroupMembersSheetState();
}

class _GroupMembersSheetState extends ConsumerState<_GroupMembersSheet> {
  bool _busy = false;
  String? _error;

  Future<void> _run(Future<void> Function() fn, {bool closeAfter = false}) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await fn();
      ref.invalidate(groupMembersProvider(widget.groupId));
      if (closeAfter && mounted) Navigator.pop(context);
    } on Object catch (e) {
      if (mounted) setState(() => _error = _message(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _add(List<GroupMember> members) async {
    final inGroup = {for (final m in members) m.userId};
    final picked = await pickFriends(context, exclude: inGroup);
    if (picked == null || picked.isEmpty || !mounted) return;
    await _run(() => ref.read(friendsProvider.notifier).addMembers(widget.groupId, picked));
  }

  Future<void> _rename(ChatGroup g) async {
    final name = await _askName(context, g.name);
    if (name == null || !mounted) return;
    await _run(() => ref.read(friendsProvider.notifier).renameGroup(widget.groupId, name));
  }

  Future<void> _leave(ChatGroup g) async {
    final userId = ref.read(authUserIdProvider).value;
    if (userId == null) return;
    if (!await confirmDialog(
      context,
      title: 'Leave ${g.name}?',
      message: 'You will no longer see its messages. The maker can add you again.',
      action: 'Leave',
    )) {
      return;
    }
    if (!mounted) return;
    await _run(() => ref.read(friendsProvider.notifier).removeMember(widget.groupId, userId), closeAfter: true);
    // Back out of the chat too
    if (mounted) Navigator.of(context, rootNavigator: true).popUntil((r) => r.isFirst);
  }

  Future<void> _delete(ChatGroup g) async {
    if (!await confirmDialog(
      context,
      title: 'Delete ${g.name}?',
      message: g.isClub
          ? 'The club chat and every message in it are deleted for good. You can open a new one later.'
          : 'The group and every message in it are deleted for good for everyone.',
      action: 'Delete',
    )) {
      return;
    }
    if (!mounted) return;
    await _run(() => ref.read(friendsProvider.notifier).deleteGroup(widget.groupId), closeAfter: true);
    if (mounted) Navigator.of(context, rootNavigator: true).popUntil((r) => r.isFirst);
  }

  Future<void> _remove(GroupMember m) async {
    if (!await confirmDialog(
      context,
      title: 'Remove ${m.name}?',
      message: 'They will no longer see the group. You can add them again later.',
      action: 'Remove',
    )) {
      return;
    }
    if (!mounted) return;
    await _run(() => ref.read(friendsProvider.notifier).removeMember(widget.groupId, m.userId));
  }

  @override
  Widget build(BuildContext context) {
    final g = ref.watch(friendsProvider.select((s) => s.groupById(widget.groupId)));
    final members = ref.watch(groupMembersProvider(widget.groupId));
    final list = members.value ?? const <GroupMember>[];
    final manager = g?.isManager ?? false;
    final editable = manager && !(g?.isClub ?? true);
    return DraggableScrollableSheet(
      key: const Key('group-members-sheet'),
      expand: false,
      initialChildSize: 0.7,
      maxChildSize: 0.95,
      builder: (context, scroll) => Column(
        children: [
          const SizedBox(height: 4),
          Padding(
            padding: const EdgeInsets.fromLTRB(L360.gutter, 8, 8, 4),
            child: Row(
              children: [
                GroupAvatar(isClub: g?.isClub ?? false, size: 40),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        g?.name ?? 'Group',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700),
                      ),
                      Text(
                        '${g?.isClub ?? false ? 'Club chat' : 'Group'} · ${list.length} member${list.length == 1 ? '' : 's'}',
                        style: const TextStyle(fontSize: 12, color: L360Colors.sand600),
                      ),
                    ],
                  ),
                ),
                if (g != null)
                  PopupMenuButton<String>(
                    key: const Key('group-menu'),
                    enabled: !_busy,
                    onSelected: (v) => switch (v) {
                      'rename' => _rename(g),
                      'leave' => _leave(g),
                      'delete' => _delete(g),
                      _ => null,
                    },
                    itemBuilder: (_) => [
                      if (editable) const PopupMenuItem(value: 'rename', child: Text('Rename')),
                      if (!manager && !g.isClub) const PopupMenuItem(value: 'leave', child: Text('Leave group')),
                      if (manager)
                        PopupMenuItem(
                          key: const Key('group-delete'),
                          value: 'delete',
                          child: Text(g.isClub ? 'Delete club chat' : 'Delete group'),
                        ),
                    ],
                  ),
              ],
            ),
          ),
          if (_error != null)
            Padding(padding: const EdgeInsets.fromLTRB(L360.gutter, 0, L360.gutter, 4), child: ErrorBanner(_error!)),
          if (g?.isClub ?? false)
            const Padding(
              padding: EdgeInsets.fromLTRB(L360.gutter, 4, L360.gutter, 4),
              child: Text(
                'Everyone in the club is in this chat; members come and go with the club.',
                style: TextStyle(fontSize: 12.5, color: L360Colors.sand600),
              ),
            ),
          if (editable)
            Padding(
              padding: const EdgeInsets.fromLTRB(L360.gutter, 4, L360.gutter, 4),
              child: OutlinedButton.icon(
                key: const Key('group-add-members'),
                onPressed: _busy ? null : () => _add(list),
                icon: const Icon(Icons.person_add_alt_1_outlined, size: 18),
                label: const Text('Add friends'),
              ),
            ),
          Expanded(
            child: members.isLoading && list.isEmpty
                ? const Center(child: CircularProgressIndicator())
                : ListView(
                    controller: scroll,
                    children: [
                      for (final m in list)
                        ListTile(
                          key: Key('member-${m.userId}'),
                          leading: FriendAvatar(name: m.name, size: 38),
                          title: Row(
                            children: [
                              Flexible(
                                child: Text(m.isMe ? '${m.name} (you)' : m.name, overflow: TextOverflow.ellipsis),
                              ),
                              if (m.isManager) ...[
                                const SizedBox(width: 6),
                                Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                                  decoration: BoxDecoration(
                                    color: L360Colors.gold100,
                                    borderRadius: BorderRadius.circular(8),
                                  ),
                                  child: Text(
                                    g?.isClub ?? false ? 'Leader' : 'Maker',
                                    style: const TextStyle(
                                      fontSize: 10.5,
                                      fontWeight: FontWeight.w700,
                                      color: L360Colors.gold700,
                                    ),
                                  ),
                                ),
                              ],
                            ],
                          ),
                          subtitle: m.organization == null ? null : Text(m.organization!),
                          trailing: editable && !m.isMe
                              ? IconButton(
                                  key: Key('member-remove-${m.userId}'),
                                  tooltip: 'Remove',
                                  onPressed: _busy ? null : () => _remove(m),
                                  icon: const Icon(Icons.person_remove_outlined, color: L360Colors.brick500),
                                )
                              : null,
                        ),
                    ],
                  ),
          ),
        ],
      ),
    );
  }
}

Future<String?> _askName(BuildContext context, String current) async {
  final c = TextEditingController(text: current);
  final name = await showDialog<String>(
    context: context,
    builder: (dialog) => AlertDialog(
      title: const Text('Rename group'),
      content: TextField(
        key: const Key('group-rename'),
        controller: c,
        autofocus: true,
        maxLength: groupNameMax,
        textCapitalization: TextCapitalization.words,
        decoration: const InputDecoration(counterText: ''),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(dialog), child: const Text('Cancel')),
        FilledButton(onPressed: () => Navigator.pop(dialog, c.text.trim()), child: const Text('Save')),
      ],
    ),
  );
  c.dispose();
  return name == null || name.length < 2 ? null : name;
}

/// Picks friends (not those in [exclude]); null when dismissed
Future<List<String>?> pickFriends(BuildContext context, {Set<String> exclude = const {}}) =>
    showModalBottomSheet<List<String>>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (_) => _PickFriends(exclude: exclude),
    );

class _PickFriends extends ConsumerStatefulWidget {
  const _PickFriends({required this.exclude});

  final Set<String> exclude;

  @override
  ConsumerState<_PickFriends> createState() => _PickFriendsState();
}

class _PickFriendsState extends ConsumerState<_PickFriends> {
  final _picked = <String>{};

  @override
  Widget build(BuildContext context) {
    final friends = [
      for (final f in ref.watch(friendsProvider.select((s) => s.friends)))
        if (!widget.exclude.contains(f.userId)) f,
    ];
    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.7,
      maxChildSize: 0.95,
      builder: (context, scroll) => Column(
        children: [
          const SizedBox(height: 4),
          Padding(
            padding: const EdgeInsets.fromLTRB(L360.gutter, 8, L360.gutter, 4),
            child: Row(
              children: [
                const Expanded(
                  child: Text('Add friends', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
                ),
                FilledButton(
                  key: const Key('pick-friends-done'),
                  onPressed: _picked.isEmpty ? null : () => Navigator.pop(context, _picked.toList()),
                  child: Text(_picked.isEmpty ? 'Add' : 'Add ${_picked.length}'),
                ),
              ],
            ),
          ),
          Expanded(
            child: friends.isEmpty
                ? const Padding(
                    padding: EdgeInsets.all(24),
                    child: Text(
                      'All your friends are in this group already.',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: L360Colors.sand600),
                    ),
                  )
                : ListView(
                    controller: scroll,
                    children: [
                      for (final f in friends)
                        CheckboxListTile(
                          key: Key('pick-${f.userId}'),
                          value: _picked.contains(f.userId),
                          onChanged: (v) =>
                              setState(() => v == true ? _picked.add(f.userId) : _picked.remove(f.userId)),
                          secondary: FriendAvatar(name: f.name, size: 36),
                          title: Text(f.name),
                          subtitle: f.organization == null ? null : Text(f.organization!),
                          controlAffinity: ListTileControlAffinity.trailing,
                        ),
                    ],
                  ),
          ),
        ],
      ),
    );
  }
}
