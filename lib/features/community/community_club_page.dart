import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:share_plus/share_plus.dart';

import '../../core/providers.dart';
import '../../core/theme/app_theme.dart';
import '../../core/ui/widgets.dart';
import '../../domain/community/community.dart';
import '../../domain/community/community_attachments.dart';
import '../../domain/marked/marked_areas.dart' show formatLength;
import '../../domain/share/share_location.dart' show ClassicLink;
import '../account/sign_in_sheet.dart';
import '../map/shared_links.dart';
import 'community_attach.dart';
import 'community_clubs.dart';
import 'community_state.dart';
import 'community_widgets.dart';

// One club (20261102000025–27): the profile, its posts, and two tabs. Members: roles (the
// leader makes members admins), adding by email, removing, invite links (7 days) and leaving.
// Workspace: copies of members' tracks, areas, locations and Field Works in folders, shown on
// the map. The leader and admins manage; any member adds to the workspace. Also the card an
// invite link (/?join=) opens, with Join.

final clubInvitesProvider = FutureProvider.family<List<ClubInvite>, String>(
  (ref, clubId) => ref.watch(communityRepositoryProvider).invites(clubId),
);

final clubFoldersProvider = FutureProvider.family<List<ClubFolder>, String>(
  (ref, clubId) => ref.watch(communityRepositoryProvider).clubFolders(clubId),
);

final clubItemsProvider = FutureProvider.family<List<ClubItem>, String>(
  (ref, clubId) => ref.watch(communityRepositoryProvider).clubItems(clubId),
);

Future<void> openClub(BuildContext context, String clubId) =>
    Navigator.of(context, rootNavigator: true).push(MaterialPageRoute<void>(builder: (_) => ClubPage(clubId: clubId)));

class ClubPage extends ConsumerStatefulWidget {
  const ClubPage({super.key, required this.clubId});

  final String clubId;

  @override
  ConsumerState<ClubPage> createState() => _ClubPageState();
}

class _ClubPageState extends ConsumerState<ClubPage> {
  Future<void> _delete(CommunityClub c) async {
    if (!await confirmDialog(
      context,
      title: 'Delete ${c.name}?',
      message: 'The club, every post in it and its workspace are deleted for good.',
      action: 'Delete',
    )) {
      return;
    }
    try {
      await ref.read(communityRepositoryProvider).deleteClub(c.id);
      ref
        ..invalidate(myClubsProvider)
        ..invalidate(communityLimitsProvider);
      final feed = ref.read(communityFeedProvider);
      if (feed.filter.clubId == c.id) {
        unawaited(ref.read(communityFeedProvider.notifier).setFilter(feed.filter.copyWith(clubId: () => null)));
      }
      if (mounted) Navigator.pop(context);
    } on Object catch (e) {
      if (mounted) showSnack(context, '$e');
    }
  }

  /// The club's posts in the feed (marks them read)
  void _posts(CommunityClub c) {
    final feed = ref.read(communityFeedProvider);
    unawaited(
      ref
          .read(communityFeedProvider.notifier)
          .setFilter(const FeedFilter().copyWith(scope: feed.filter.scope, clubId: () => c.id)),
    );
    // Back to the Community sheet (or the map when it was closed)
    Navigator.of(context).popUntil((r) => r is! PageRoute || r.isFirst);
  }

  @override
  Widget build(BuildContext context) {
    final club = (ref.watch(myClubsProvider).value ?? const <CommunityClub>[])
        .where((c) => c.id == widget.clubId)
        .firstOrNull;
    return DefaultTabController(
      length: 2,
      child: Scaffold(
        appBar: AppBar(
          title: Text(club?.name ?? 'Club'),
          actions: [
            if (club?.isOwner ?? false)
              PopupMenuButton<String>(
                key: const Key('club-menu'),
                onSelected: (v) => v == 'edit' ? showClubForm(context, club: club) : _delete(club!),
                itemBuilder: (_) => const [
                  PopupMenuItem(value: 'edit', child: Text('Edit')),
                  PopupMenuItem(value: 'delete', child: Text('Delete club')),
                ],
              ),
          ],
          bottom: const TabBar(
            tabs: [
              Tab(key: Key('club-tab-members'), text: 'Members'),
              Tab(key: Key('club-tab-workspace'), text: 'Workspace'),
            ],
          ),
        ),
        body: club == null
            ? const Center(child: CircularProgressIndicator())
            : TabBarView(
                children: [
                  _MembersTab(club: club, header: _header(club)),
                  _WorkspaceTab(club: club),
                ],
              ),
      ),
    );
  }

  Widget _header(CommunityClub club) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Row(
        children: [
          ClubAvatar(club: club, size: 64),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(club.name, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
                Text(
                  [
                    'Leader: ${club.ownerName}',
                    '${club.memberCount} member${club.memberCount == 1 ? '' : 's'}',
                  ].join(' · '),
                  style: const TextStyle(fontSize: 12, color: L360Colors.sand600),
                ),
              ],
            ),
          ),
          if (club.isOwner)
            TextButton.icon(
              key: const Key('club-edit'),
              onPressed: () => showClubForm(context, club: club),
              icon: const Icon(Icons.edit_outlined, size: 18),
              label: const Text('Edit'),
            ),
        ],
      ),
      const SizedBox(height: 12),
      if (club.description?.isNotEmpty ?? false) ...[
        Text(club.description!, style: const TextStyle(fontSize: 14, height: 1.4)),
        const SizedBox(height: 8),
      ],
      if (club.region?.isNotEmpty ?? false) ...[
        Row(
          children: [
            const Icon(Icons.place_outlined, size: 16, color: L360Colors.sand600),
            const SizedBox(width: 6),
            Expanded(
              child: Text(club.region!, style: const TextStyle(fontSize: 13, color: L360Colors.sand700)),
            ),
          ],
        ),
        const SizedBox(height: 6),
      ],
      if (club.contact?.isNotEmpty ?? false) ...[ClubContact(contact: club.contact!), const SizedBox(height: 6)],
      const SizedBox(height: 6),
      OutlinedButton.icon(
        key: const Key('club-posts'),
        onPressed: () => _posts(club),
        icon: const Icon(Icons.forum_outlined, size: 18),
        label: Text(club.newPosts > 0 ? 'Club posts (${club.newPosts} new)' : 'Club posts'),
      ),
      const SizedBox(height: 6),
      const Text(
        'Posts to this club are $membersOnlyLabel: only its members see them, and they have no public link.',
        style: TextStyle(fontSize: 12, color: L360Colors.sand600),
      ),
    ],
  );
}

// --- Members -------------------------------------------------------------------------------------

class _MembersTab extends ConsumerStatefulWidget {
  const _MembersTab({required this.club, required this.header});

  final CommunityClub club;
  final Widget header;

  @override
  ConsumerState<_MembersTab> createState() => _MembersTabState();
}

class _MembersTabState extends ConsumerState<_MembersTab> {
  final _email = TextEditingController();
  bool _busy = false;
  String? _error;

  CommunityClub get _club => widget.club;

  @override
  void dispose() {
    _email.dispose();
    super.dispose();
  }

  Future<void> _run(Future<void> Function() task) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await task();
    } on Object catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _changed() {
    ref
      ..invalidate(clubMembersProvider(_club.id))
      ..invalidate(myClubsProvider);
  }

  Future<void> _add() async {
    final problem = memberEmailError(_email.text);
    if (problem != null) {
      setState(() => _error = problem);
      return;
    }
    await _run(() async {
      final name = await ref.read(communityRepositoryProvider).addClubMember(_club.id, _email.text);
      _email.clear();
      if (mounted) FocusScope.of(context).unfocus();
      _changed();
      if (mounted) showSnack(context, '$name was added to the club.');
    });
  }

  Future<void> _remove(ClubMember m) async {
    if (!await confirmDialog(
      context,
      title: 'Remove ${m.name}?',
      message: 'They will no longer see the club and its posts.',
      action: 'Remove',
    )) {
      return;
    }
    await _run(() async {
      await ref.read(communityRepositoryProvider).removeClubMember(_club.id, m.userId);
      _changed();
    });
  }

  Future<void> _setRole(ClubMember m, ClubRole role) => _run(() async {
    await ref.read(communityRepositoryProvider).setClubRole(_club.id, m.userId, role);
    _changed();
  });

  Future<void> _leave(ClubMember me) async {
    if (!await confirmDialog(
      context,
      title: 'Leave this club?',
      message: 'You will no longer see its posts. The club can add you again.',
      action: 'Leave',
    )) {
      return;
    }
    await _run(() async {
      await ref.read(communityRepositoryProvider).removeClubMember(_club.id, me.userId);
      ref.invalidate(myClubsProvider);
      if (mounted) Navigator.pop(context);
    });
  }

  Future<void> _newInvite() => _run(() async {
    final token = await ref.read(communityRepositoryProvider).createInvite(_club.id);
    ref.invalidate(clubInvitesProvider(_club.id));
    await _shareInvite(token);
  });

  Future<void> _shareInvite(String token) => SharePlus.instance.share(
    ShareParams(text: 'Join ${_club.name} on Landscape 360: ${joinUrl(token)}', subject: _club.name),
  );

  Future<void> _stopInvite(ClubInvite i) => _run(() async {
    await ref.read(communityRepositoryProvider).revokeInvite(i.token);
    ref.invalidate(clubInvitesProvider(_club.id));
  });

  /// The leader removes anyone but themself; an admin removes members only
  bool _canRemove(ClubMember m) =>
      _club.canManage && !m.isMe && m.role != ClubRole.owner && (_club.isOwner || m.role == ClubRole.member);

  @override
  Widget build(BuildContext context) {
    final members = ref.watch(clubMembersProvider(_club.id));
    final me = members.value?.where((m) => m.isMe).firstOrNull;
    final now = ref.watch(communityClockProvider)();
    return ListView(
      key: const Key('club-members'),
      padding: const EdgeInsets.fromLTRB(L360.gutter, 12, L360.gutter, 32),
      children: [
        widget.header,
        if (_error != null) ...[const SizedBox(height: 10), ErrorBanner(_error!)],
        if (_club.canManage) ...[
          const SizedBox(height: 14),
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Expanded(
                child: TextField(
                  key: const Key('club-member-email'),
                  controller: _email,
                  keyboardType: TextInputType.emailAddress,
                  autocorrect: false,
                  decoration: const InputDecoration(labelText: 'Add a member by email'),
                  onSubmitted: (_) => _busy ? null : _add(),
                ),
              ),
              const SizedBox(width: 8),
              FilledButton(
                key: const Key('club-member-add'),
                style: FilledButton.styleFrom(minimumSize: const Size(0, 48)),
                onPressed: _busy ? null : _add,
                child: const Text('Add'),
              ),
            ],
          ),
          const SizedBox(height: 12),
          _invites(now),
        ],
        const SizedBox(height: 16),
        Text(
          'Members${members.value == null ? '' : ' (${members.value!.length} / $clubMembersMax)'}',
          style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 4),
        ...switch (members) {
          AsyncData(:final value) => [
            for (final m in value)
              ListTile(
                key: Key('member-${m.userId}'),
                contentPadding: EdgeInsets.zero,
                leading: Icon(switch (m.role) {
                  ClubRole.owner => Icons.star,
                  ClubRole.admin => Icons.shield_outlined,
                  ClubRole.member => Icons.person_outline,
                }, color: L360Colors.forest700),
                title: Row(
                  children: [
                    Flexible(child: Text(m.isMe ? '${m.name} (you)' : m.name, overflow: TextOverflow.ellipsis)),
                    if (m.role != ClubRole.member) ...[
                      const SizedBox(width: 6),
                      Pill(
                        m.role.label,
                        key: Key('role-${m.userId}'),
                        background: m.role == ClubRole.owner ? L360Colors.gold50 : L360Colors.forest50,
                        foreground: m.role == ClubRole.owner ? L360Colors.gold700 : L360Colors.forest700,
                      ),
                    ],
                  ],
                ),
                subtitle: [?m.organization, ?m.email].isEmpty ? null : Text([?m.organization, ?m.email].join(' · ')),
                trailing: _memberMenu(m),
              ),
          ],
          AsyncError(:final error) => [ErrorBanner('$error')],
          _ => [
            const Padding(
              padding: EdgeInsets.all(16),
              child: Center(child: CircularProgressIndicator()),
            ),
          ],
        },
        if (me != null && me.role != ClubRole.owner) ...[
          const SizedBox(height: 16),
          OutlinedButton.icon(
            key: const Key('club-leave'),
            style: OutlinedButton.styleFrom(foregroundColor: L360Colors.brick500),
            onPressed: _busy ? null : () => _leave(me),
            icon: const Icon(Icons.logout),
            label: const Text('Leave club'),
          ),
        ],
      ],
    );
  }

  Widget? _memberMenu(ClubMember m) {
    final setRole = _club.isOwner && _club.canManage && m.role != ClubRole.owner;
    final remove = _canRemove(m);
    if (!setRole && !remove) return null;
    return PopupMenuButton<String>(
      key: Key('member-menu-${m.userId}'),
      enabled: !_busy,
      onSelected: (v) => switch (v) {
        'admin' => _setRole(m, ClubRole.admin),
        'member' => _setRole(m, ClubRole.member),
        _ => _remove(m),
      },
      itemBuilder: (_) => [
        if (setRole && m.role == ClubRole.member) const PopupMenuItem(value: 'admin', child: Text('Make admin')),
        if (setRole && m.role == ClubRole.admin) const PopupMenuItem(value: 'member', child: Text('Remove admin role')),
        if (remove) const PopupMenuItem(value: 'remove', child: Text('Remove from club')),
      ],
    );
  }

  Widget _invites(DateTime now) {
    final invites = ref.watch(clubInvitesProvider(_club.id)).value ?? const <ClubInvite>[];
    return Container(
      key: const Key('club-invites'),
      padding: const EdgeInsets.fromLTRB(12, 8, 4, 8),
      decoration: BoxDecoration(
        color: L360Colors.sand50,
        borderRadius: BorderRadius.circular(L360.radiusSmall),
        border: Border.all(color: L360Colors.sand200),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              const Expanded(
                child: Text('Invite links (7 days)', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700)),
              ),
              TextButton.icon(
                key: const Key('club-invite-new'),
                onPressed: _busy ? null : _newInvite,
                icon: const Icon(Icons.link, size: 18),
                label: const Text('New link'),
              ),
            ],
          ),
          if (invites.isEmpty)
            const Text(
              'Anyone with a link and a Landscape 360 account can join.',
              style: TextStyle(fontSize: 12, color: L360Colors.sand600),
            ),
          for (final i in invites)
            Row(
              key: Key('invite-${i.token}'),
              children: [
                Expanded(
                  child: Text(
                    [
                      'Until ${formatDay(i.expiresAt.toLocal())}',
                      '${i.uses} joined',
                      if (i.createdByName.isNotEmpty) 'by ${i.createdByName}',
                    ].join(' · '),
                    style: const TextStyle(fontSize: 12, color: L360Colors.sand700),
                  ),
                ),
                IconButton(
                  tooltip: 'Copy link',
                  visualDensity: VisualDensity.compact,
                  icon: const Icon(Icons.copy, size: 18),
                  onPressed: () {
                    unawaited(Clipboard.setData(ClipboardData(text: i.url)));
                    showSnack(context, 'Link copied.');
                  },
                ),
                IconButton(
                  tooltip: 'Share link',
                  visualDensity: VisualDensity.compact,
                  icon: const Icon(Icons.share, size: 18),
                  onPressed: () => _shareInvite(i.token),
                ),
                IconButton(
                  key: Key('invite-stop-${i.token}'),
                  tooltip: 'Stop link',
                  visualDensity: VisualDensity.compact,
                  icon: const Icon(Icons.link_off, size: 18, color: L360Colors.brick500),
                  onPressed: _busy ? null : () => _stopInvite(i),
                ),
              ],
            ),
        ],
      ),
    );
  }
}

// --- Workspace -----------------------------------------------------------------------------------

class _WorkspaceTab extends ConsumerStatefulWidget {
  const _WorkspaceTab({required this.club});

  final CommunityClub club;

  @override
  ConsumerState<_WorkspaceTab> createState() => _WorkspaceTabState();
}

/// The folder being looked at: all items, none (outside folders) or one folder
const _allItems = '*';

class _WorkspaceTabState extends ConsumerState<_WorkspaceTab> {
  String? _folder = _allItems; // null: items outside any folder
  bool _busy = false;
  String? _error;

  CommunityClub get _club => widget.club;

  Future<void> _run(Future<void> Function() task) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await task();
    } on Object catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _changed() {
    ref
      ..invalidate(clubItemsProvider(_club.id))
      ..invalidate(clubFoldersProvider(_club.id));
  }

  Future<void> _add() async {
    final data = await pickAttachment(context, trackPoints: workspaceTrackPoints);
    if (data == null || !mounted) return;
    await _run(() async {
      await ref.read(communityRepositoryProvider).addClubItem(_club.id, _folder == _allItems ? null : _folder, data);
      _changed();
      if (mounted) showSnack(context, '${data.name} was added to the workspace.');
    });
  }

  Future<void> _folderForm({ClubFolder? folder}) async {
    final name = await _askText(
      context,
      title: folder == null ? 'New folder' : 'Rename folder',
      label: 'Folder name',
      initial: folder?.name ?? '',
      maxLength: clubFolderNameMax,
    );
    if (name == null || name.trim().isEmpty) return;
    await _run(() async {
      final id = await ref.read(communityRepositoryProvider).saveClubFolder(_club.id, folder?.id, name);
      _changed();
      if (mounted && folder == null) setState(() => _folder = id);
    });
  }

  Future<void> _deleteFolder(ClubFolder f) async {
    if (!await confirmDialog(
      context,
      title: 'Delete folder ${f.name}?',
      message: 'Its items stay in the workspace, outside any folder.',
      action: 'Delete',
    )) {
      return;
    }
    await _run(() async {
      await ref.read(communityRepositoryProvider).deleteClubFolder(f.id);
      _changed();
      if (mounted) setState(() => _folder = _allItems);
    });
  }

  Future<void> _show(ClubItem item) => _run(() async {
    final data = await ref.read(communityRepositoryProvider).clubItemData(item.id);
    if (data == null) throw StateError('This item is no longer in the workspace.');
    if (!mounted) return;
    if (data is ClassicAttachment) {
      unawaited(ref.read(sharedLinkProvider.notifier).open(ClassicLink(data.token)));
    } else {
      ref.read(communityFocusProvider.notifier).showFocus(MapFocus(title: item.name, attachment: data));
    }
    Navigator.of(context).popUntil((r) => r.isFirst);
  });

  Future<void> _edit(ClubItem item, List<ClubFolder> folders) async {
    final result = await showModalBottomSheet<(String, String, String?)>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (_) => _ItemForm(item: item, folders: folders),
    );
    if (result == null) return;
    await _run(() async {
      await ref
          .read(communityRepositoryProvider)
          .updateClubItem(item.id, name: result.$1, note: result.$2, folderId: result.$3);
      _changed();
    });
  }

  Future<void> _delete(ClubItem item) async {
    if (!await confirmDialog(
      context,
      title: 'Remove ${item.name}?',
      message: 'It is removed from the club workspace. The original on your account stays.',
      action: 'Remove',
    )) {
      return;
    }
    await _run(() async {
      await ref.read(communityRepositoryProvider).deleteClubItem(item.id);
      _changed();
    });
  }

  @override
  Widget build(BuildContext context) {
    final folders = ref.watch(clubFoldersProvider(_club.id)).value ?? const <ClubFolder>[];
    final items = ref.watch(clubItemsProvider(_club.id));
    final manage = _club.canManage;
    final shown = [
      for (final i in items.value ?? const <ClubItem>[])
        if (_folder == _allItems || i.folderId == _folder) i,
    ];
    final current = folders.where((f) => f.id == _folder).firstOrNull;
    return ListView(
      key: const Key('club-workspace'),
      padding: const EdgeInsets.fromLTRB(L360.gutter, 12, L360.gutter, 32),
      children: [
        const Text(
          "Your team's tracks, areas, locations and Field Works, as copies. Every member can add and look; "
          'the leader and admins keep the folders.',
          style: TextStyle(fontSize: 12, color: L360Colors.sand600),
        ),
        const SizedBox(height: 10),
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: [
            ChoiceChip(
              key: const Key('folder-all'),
              label: const Text('All'),
              selected: _folder == _allItems,
              onSelected: (_) => setState(() => _folder = _allItems),
            ),
            ChoiceChip(
              key: const Key('folder-none'),
              label: const Text('No folder'),
              selected: _folder == null,
              onSelected: (_) => setState(() => _folder = null),
            ),
            for (final f in folders)
              ChoiceChip(
                key: Key('folder-${f.id}'),
                avatar: const Icon(Icons.folder_outlined, size: 16),
                label: Text('${f.name} (${f.itemCount})'),
                selected: _folder == f.id,
                onSelected: (_) => setState(() => _folder = f.id),
              ),
            if (manage)
              ActionChip(
                key: const Key('folder-new'),
                avatar: const Icon(Icons.create_new_folder_outlined, size: 16),
                label: const Text('New folder'),
                onPressed: _busy ? null : () => _folderForm(),
              ),
          ],
        ),
        if (manage && current != null)
          Row(
            children: [
              TextButton(
                onPressed: _busy ? null : () => _folderForm(folder: current),
                child: const Text('Rename folder'),
              ),
              TextButton(
                key: const Key('folder-delete'),
                style: TextButton.styleFrom(foregroundColor: L360Colors.brick500),
                onPressed: _busy ? null : () => _deleteFolder(current),
                child: const Text('Delete folder'),
              ),
            ],
          ),
        const SizedBox(height: 8),
        FilledButton.icon(
          key: const Key('workspace-add'),
          style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(44)),
          onPressed: _busy ? null : _add,
          icon: const Icon(Icons.add, size: 18),
          label: Text(current == null ? 'Add from my map data' : 'Add to ${current.name}'),
        ),
        if (_busy) const Padding(padding: EdgeInsets.only(top: 8), child: LinearProgressIndicator(minHeight: 2)),
        if (_error != null) ...[const SizedBox(height: 10), ErrorBanner(_error!)],
        const SizedBox(height: 10),
        ...switch (items) {
          AsyncData() when shown.isEmpty => [
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 24),
              child: Text(
                'Nothing here yet.',
                textAlign: TextAlign.center,
                style: TextStyle(color: L360Colors.sand500),
              ),
            ),
          ],
          AsyncData() => [
            for (final i in shown)
              ListTile(
                key: Key('item-${i.id}'),
                contentPadding: EdgeInsets.zero,
                leading: Icon(_kindIcon(i.kind), color: i.color == null ? L360Colors.forest700 : hexColor(i.color!)),
                title: Text(i.name),
                subtitle: Text(
                  [
                    if (i.distanceM != null) formatLength(i.distanceM!),
                    if (i.note?.isNotEmpty ?? false) i.note!,
                    'by ${i.addedByName}',
                  ].join(' · '),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                onTap: _busy ? null : () => _show(i),
                trailing: i.isMine || manage
                    ? PopupMenuButton<String>(
                        key: Key('item-menu-${i.id}'),
                        onSelected: (v) => switch (v) {
                          'show' => _show(i),
                          'edit' => _edit(i, folders),
                          _ => _delete(i),
                        },
                        itemBuilder: (_) => [
                          PopupMenuItem(value: 'show', child: Text(i.kind == 'classic' ? 'Open' : 'Show on map')),
                          const PopupMenuItem(value: 'edit', child: Text('Edit')),
                          const PopupMenuItem(value: 'delete', child: Text('Remove')),
                        ],
                      )
                    : const Icon(Icons.map_outlined, color: L360Colors.sand400),
              ),
          ],
          AsyncError(:final error) => [ErrorBanner('$error')],
          _ => [
            const Padding(
              padding: EdgeInsets.all(16),
              child: Center(child: CircularProgressIndicator()),
            ),
          ],
        },
      ],
    );
  }
}

IconData _kindIcon(String kind) => switch (kind) {
  'track' => Icons.timeline,
  'area' => Icons.hexagon_outlined,
  'place' => Icons.pin_drop_outlined,
  _ => Icons.architecture,
};

/// Name, note and folder of a workspace item: (name, note, folder id)
class _ItemForm extends StatefulWidget {
  const _ItemForm({required this.item, required this.folders});

  final ClubItem item;
  final List<ClubFolder> folders;

  @override
  State<_ItemForm> createState() => _ItemFormState();
}

class _ItemFormState extends State<_ItemForm> {
  late final _name = TextEditingController(text: widget.item.name);
  late final _note = TextEditingController(text: widget.item.note ?? '');
  late String? _folder = widget.item.folderId;

  @override
  void dispose() {
    _name.dispose();
    _note.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Padding(
    key: const Key('item-form'),
    padding: EdgeInsets.fromLTRB(L360.gutter, 4, L360.gutter, 16 + MediaQuery.viewInsetsOf(context).bottom),
    child: SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text('Edit item', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
          const SizedBox(height: 10),
          TextField(
            key: const Key('item-name'),
            controller: _name,
            maxLength: clubItemNameMax,
            decoration: const InputDecoration(labelText: 'Name *'),
          ),
          TextField(
            controller: _note,
            maxLength: clubItemNoteMax,
            minLines: 1,
            maxLines: 3,
            decoration: const InputDecoration(labelText: 'Note'),
          ),
          DropdownButtonFormField<String?>(
            key: const Key('item-folder'),
            isExpanded: true,
            initialValue: widget.folders.any((f) => f.id == _folder) ? _folder : null,
            decoration: const InputDecoration(labelText: 'Folder'),
            items: [
              const DropdownMenuItem<String?>(value: null, child: Text('No folder')),
              for (final f in widget.folders) DropdownMenuItem<String?>(value: f.id, child: Text(f.name)),
            ],
            onChanged: (v) => setState(() => _folder = v),
          ),
          const SizedBox(height: 12),
          FilledButton(
            key: const Key('item-save'),
            onPressed: () {
              if (_name.text.trim().isEmpty) return;
              Navigator.pop(context, (_name.text, _note.text, _folder));
            },
            child: const Text('Save'),
          ),
        ],
      ),
    ),
  );
}

Future<String?> _askText(
  BuildContext context, {
  required String title,
  required String label,
  String initial = '',
  int? maxLength,
}) => showDialog<String>(
  context: context,
  builder: (_) => _TextDialog(title: title, label: label, initial: initial, maxLength: maxLength),
);

/// One line of text in a dialog (its controller lives as long as the dialog)
class _TextDialog extends StatefulWidget {
  const _TextDialog({required this.title, required this.label, required this.initial, this.maxLength});

  final String title;
  final String label;
  final String initial;
  final int? maxLength;

  @override
  State<_TextDialog> createState() => _TextDialogState();
}

class _TextDialogState extends State<_TextDialog> {
  late final _c = TextEditingController(text: widget.initial);

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(widget.title),
    content: TextField(
      key: const Key('ask-text'),
      controller: _c,
      autofocus: true,
      maxLength: widget.maxLength,
      decoration: InputDecoration(labelText: widget.label),
    ),
    actions: [
      TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
      TextButton(key: const Key('ask-ok'), onPressed: () => Navigator.pop(context, _c.text), child: const Text('Save')),
    ],
  );
}

// --- Invite link (/?join=) -----------------------------------------------------------------------

Future<void> openJoinClub(BuildContext context, String token) => Navigator.of(
  context,
  rootNavigator: true,
).push(MaterialPageRoute<void>(builder: (_) => JoinClubPage(token: token)));

/// The club behind an invite link, with Join (signing in first when needed)
class JoinClubPage extends ConsumerStatefulWidget {
  const JoinClubPage({super.key, required this.token});

  final String token;

  @override
  ConsumerState<JoinClubPage> createState() => _JoinClubPageState();
}

class _JoinClubPageState extends ConsumerState<JoinClubPage> {
  ClubInviteInfo? _info;
  bool _loading = true;
  bool _joining = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    try {
      final info = await ref.read(communityRepositoryProvider).inviteInfo(widget.token);
      if (!mounted) return;
      setState(() {
        _info = info;
        _loading = false;
      });
    } on Object catch (e) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = '$e';
        });
      }
    }
  }

  Future<void> _join() async {
    if (ref.read(authUserIdProvider).value == null) {
      await showSignInSheet(
        context,
        title: 'Join ${_info?.name ?? 'the club'}',
        reason: 'Sign in to join the club, see its posts and share map data with its members.',
      );
      return;
    }
    setState(() {
      _joining = true;
      _error = null;
    });
    try {
      final clubId = await ref.read(communityRepositoryProvider).joinClub(widget.token);
      ref.invalidate(myClubsProvider);
      if (!mounted) return;
      await Navigator.of(context).pushReplacement(MaterialPageRoute<void>(builder: (_) => ClubPage(clubId: clubId)));
    } on Object catch (e) {
      if (mounted) {
        setState(() {
          _joining = false;
          _error = '$e';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final info = _info;
    return Scaffold(
      appBar: AppBar(title: const Text('Club invite')),
      body: ListView(
        key: const Key('join-club'),
        padding: const EdgeInsets.fromLTRB(L360.gutter, 16, L360.gutter, 32),
        children: [
          if (_loading)
            const Center(child: CircularProgressIndicator())
          else if (info == null)
            Text(_error ?? 'This invite link is not valid.', textAlign: TextAlign.center)
          else ...[
            Row(
              children: [
                ClubAvatar(club: info.club, size: 64),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(info.name, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
                      Text(
                        [
                          'Leader: ${info.leaderName}',
                          '${info.memberCount} member${info.memberCount == 1 ? '' : 's'}',
                          if (info.region?.isNotEmpty ?? false) info.region!,
                        ].join(' · '),
                        style: const TextStyle(fontSize: 12, color: L360Colors.sand600),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            if (info.description?.isNotEmpty ?? false) ...[
              const SizedBox(height: 12),
              Text(info.description!, style: const TextStyle(fontSize: 14, height: 1.4)),
            ],
            const SizedBox(height: 16),
            if (_error != null) ...[ErrorBanner(_error!), const SizedBox(height: 10)],
            if (info.isMember)
              FilledButton(
                key: const Key('join-open'),
                onPressed: () =>
                    Navigator.of(context)
                        .pushReplacement(MaterialPageRoute<void>(builder: (_) => ClubPage(clubId: info.clubId))),
                child: const Text('You are a member · Open the club'),
              )
            else if (!info.valid)
              const ErrorBanner('This invite link has expired or was stopped. Ask the club for a new one.')
            else
              FilledButton(
                key: const Key('join-club-button'),
                onPressed: _joining ? null : _join,
                child: Text(ref.watch(authUserIdProvider.select((a) => a.value != null)) ? 'Join' : 'Sign in to join'),
              ),
          ],
        ],
      ),
    );
  }
}
