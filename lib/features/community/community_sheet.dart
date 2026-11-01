import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers.dart';
import '../../core/theme/app_theme.dart';
import '../../core/ui/widgets.dart';
import '../../data/community/community_outbox.dart';
import '../../domain/community/community.dart';
import '../account/sign_in_sheet.dart';
import 'community_admin.dart';
import 'community_clubs.dart';
import 'community_compose.dart';
import 'community_post_page.dart';
import 'community_state.dart';
import 'community_widgets.dart';

// Community from the Tools section (COMMUNITY_PRD.md 8.3, 8.6; "Tabs + cards" like the web's
// CommunityPanel.tsx): a header with minimize and close (and Reported posts for the admin);
// for a signed-in account the tabs Feed / Clubs / Mine; the feed's filter chips (near the map
// or everywhere, kind, condition, audience), post cards, the empty states and "+ Post"; trail
// reports waiting to be sent; the copy kept for reading offline. Posts, compose, clubs and the
// reports open as pages over the sheet, and their back arrow returns to the tab.

const _sheetFull = 0.88;
const _sheetLow = 0.3;

Future<void> showCommunitySheet(BuildContext context) {
  final sheet = DraggableScrollableController();
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (_) => DraggableScrollableSheet(
      expand: false,
      controller: sheet,
      initialChildSize: _sheetFull,
      minChildSize: _sheetLow - 0.05,
      maxChildSize: 0.95,
      builder: (context, controller) => CommunityFeed(controller: controller, sheet: sheet),
    ),
  ).whenComplete(sheet.dispose);
}

/// Opens the compose form, or explains that posting needs an account
Future<void> startCompose(BuildContext context, WidgetRef ref) async {
  if (ref.read(authUserIdProvider).value == null) {
    await showSignInSheet(
      context,
      title: 'Community',
      reason: 'Sign in to post trail reports and stories, mark posts as helpful and comment.',
    );
    return;
  }
  await openCompose(context);
}

enum CommunityTab { feed, clubs, mine }

/// The Community sheet's content
class CommunityFeed extends ConsumerStatefulWidget {
  const CommunityFeed({super.key, required this.controller, this.sheet});

  final ScrollController controller;

  /// The sheet, for minimize (none in tests)
  final DraggableScrollableController? sheet;

  @override
  ConsumerState<CommunityFeed> createState() => _CommunityFeedState();
}

class _CommunityFeedState extends ConsumerState<CommunityFeed> {
  CommunityTab _tab = CommunityTab.feed;

  CommunityFeedController get _feed => ref.read(communityFeedProvider.notifier);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(_feed.load());
    });
  }

  void _open(CommunityPost p) => unawaited(openCommunityPost(context, p.id, initial: p));

  void _setTab(CommunityTab t) {
    setState(() => _tab = t);
    if (t == CommunityTab.mine) unawaited(ref.read(myPostsProvider.notifier).load());
    if (t == CommunityTab.clubs) ref.invalidate(myClubsProvider);
  }

  void _minimize() {
    final sheet = widget.sheet;
    if (sheet == null || !sheet.isAttached) return;
    final low = sheet.size <= _sheetLow + 0.02;
    unawaited(
      sheet.animateTo(
        low ? _sheetFull : _sheetLow,
        duration: const Duration(milliseconds: 250),
        curve: Curves.easeOutCubic,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final signedIn = ref.watch(authUserIdProvider.select((a) => a.value != null));
    final isAdmin = ref.watch(profileProvider.select((p) => p.value?.isAdmin ?? false));
    final tab = signedIn ? _tab : CommunityTab.feed;
    final feedPosts = ref.watch(communityFeedProvider.select((s) => s.posts.isNotEmpty));
    final minePosts = ref.watch(myPostsProvider.select((s) => s.posts.isNotEmpty));
    final showPost = signedIn && (tab == CommunityTab.feed ? feedPosts : tab == CommunityTab.mine && minePosts);
    return Stack(
      children: [
        ListView(
          key: const Key('community-feed'),
          controller: widget.controller,
          padding: const EdgeInsets.fromLTRB(L360.gutter, 0, L360.gutter, 96),
          children: [
            _Header(isAdmin: isAdmin, onMinimize: _minimize),
            if (signedIn) ...[const SizedBox(height: 10), _Tabs(value: tab, onChanged: _setTab)],
            const SizedBox(height: 12),
            ...switch (tab) {
              CommunityTab.feed => _feedView(signedIn),
              CommunityTab.clubs => const [ClubsList()],
              CommunityTab.mine => _mineView(),
            },
          ],
        ),
        if (showPost)
          Positioned(
            right: L360.gutter,
            bottom: 16 + MediaQuery.paddingOf(context).bottom,
            child: FloatingActionButton.extended(
              key: const Key('community-write'),
              heroTag: null,
              backgroundColor: L360Colors.forest800,
              foregroundColor: Colors.white,
              onPressed: () => startCompose(context, ref),
              icon: const Icon(Icons.add),
              label: const Text('Post', style: TextStyle(fontWeight: FontWeight.w700)),
            ),
          ),
      ],
    );
  }

  List<Widget> _feedView(bool signedIn) {
    final s = ref.watch(communityFeedProvider);
    final outbox = ref.watch(communityOutboxProvider);
    final now = ref.watch(communityClockProvider)();
    final clubs = signedIn ? ref.watch(myClubsProvider).value ?? const <CommunityClub>[] : const <CommunityClub>[];
    final f = s.filter;
    final club = clubs.where((c) => c.id == f.clubId).firstOrNull;
    final filtered = f.kinds.isNotEmpty || f.conditions.isNotEmpty;
    Widget write(String label) => PillChip(
      key: const Key('empty-write'),
      label: label,
      on: true,
      leading: const Icon(Icons.add, size: 14, color: Colors.white),
      onTap: () => startCompose(context, ref),
    );
    return [
      if (!signedIn) ...[
        Container(
          key: const Key('community-guest'),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          decoration: BoxDecoration(
            color: L360Colors.gold50,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: L360Colors.gold100),
          ),
          child: Row(
            children: [
              const Icon(Icons.forum_outlined, size: 18, color: L360Colors.gold700),
              const SizedBox(width: 10),
              const Expanded(
                child: Text.rich(
                  TextSpan(
                    children: [
                      TextSpan(
                        text: 'Read freely. ',
                        style: TextStyle(fontWeight: FontWeight.w700),
                      ),
                      TextSpan(text: 'Sign in to post trail reports, comment and join clubs.'),
                    ],
                  ),
                  style: TextStyle(fontSize: 12, color: L360Colors.sand700, height: 1.35),
                ),
              ),
              TextButton(
                key: const Key('community-sign-in'),
                onPressed: () => startCompose(context, ref),
                child: const Text('Sign in to post'),
              ),
            ],
          ),
        ),
        const SizedBox(height: 10),
      ],
      _Filters(filter: f, clubs: clubs),
      const SizedBox(height: 8),
      const CommunityLayerSwitch(),
      if (outbox.items.isNotEmpty) ...[const SizedBox(height: 10), _Outbox(state: outbox)],
      if (s.offline) ...[
        const SizedBox(height: 10),
        Container(
          key: const Key('community-offline'),
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(color: L360Colors.sand100, borderRadius: BorderRadius.circular(L360.radiusSmall)),
          child: Row(
            children: [
              const Icon(Icons.cloud_off, size: 18, color: L360Colors.sand600),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'No connection. Showing the posts saved ${timeAgo(s.savedAt!, now)}.',
                  style: const TextStyle(fontSize: 12, color: L360Colors.sand700),
                ),
              ),
            ],
          ),
        ),
      ],
      if (s.error != null) ...[const SizedBox(height: 10), ErrorBanner(s.error!)],
      const SizedBox(height: 12),
      if (s.loading && s.posts.isEmpty)
        const LoadingCards()
      else if (s.posts.isEmpty && s.error == null)
        club != null
            ? EmptyState(
                icon: Icons.lock_outline,
                title: 'Nothing in ${club.name} yet',
                text: 'Posts for members only show up here. Share news, plans or trail conditions with your club.',
                actions: [if (signedIn) write('Write a post')],
              )
            : filtered
            ? EmptyState(
                icon: Icons.place_outlined,
                title: 'No posts match',
                text: 'Try another condition or type.',
                actions: [
                  PillChip(
                    key: const Key('empty-clear'),
                    label: 'Clear filters',
                    on: false,
                    onTap: () => _feed.setFilter(f.copyWith(kinds: const {}, conditions: const {})),
                  ),
                  if (signedIn) write('Write a post'),
                ],
              )
            : f.scope == FeedScope.nearMap
            ? EmptyState(
                icon: Icons.place_outlined,
                title: 'Quiet around here',
                text: 'No one has posted in this part of the map in a while. Look everywhere, or be the first to report how the trail is.',
                actions: [
                  PillChip(
                    key: const Key('empty-everywhere'),
                    label: 'Look everywhere',
                    on: false,
                    onTap: () => _feed.setFilter(f.copyWith(scope: FeedScope.all)),
                  ),
                  if (signedIn) write('Write a post'),
                ],
              )
            : EmptyState(
                icon: Icons.place_outlined,
                title: 'No posts yet',
                text: 'Be the first to share how a trail is.',
                actions: [if (signedIn) write('Write a post')],
              ),
      for (final p in s.posts) ...[PostCard(post: p, onTap: () => _open(p)), const SizedBox(height: 8)],
      if (s.loadingMore)
        const Padding(
          padding: EdgeInsets.all(8),
          child: Center(child: SizedBox.square(dimension: 18, child: CircularProgressIndicator(strokeWidth: 2))),
        )
      else if (s.hasMore)
        OutlinedButton(key: const Key('community-more'), onPressed: _feed.loadMore, child: const Text('Show more')),
      const SizedBox(height: 10),
      const Text(
        'Posts come from other hikers. Always check with the park or trail managers before you go.',
        textAlign: TextAlign.center,
        style: TextStyle(fontSize: 11, color: L360Colors.sand500),
      ),
    ];
  }

  List<Widget> _mineView() {
    final s = ref.watch(myPostsProvider);
    Widget stat(String value, String label, Color color) => Expanded(
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: L360Colors.sand200),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              value,
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700, color: color),
            ),
            const SizedBox(height: 2),
            Text(label, style: const TextStyle(fontSize: 11, color: L360Colors.sand500)),
          ],
        ),
      ),
    );
    return [
      if (s.posts.isNotEmpty) ...[
        Row(
          key: const Key('mine-stats'),
          children: [
            stat('${s.posts.length}${s.hasMore ? '+' : ''}', 'posts', L360Colors.ink),
            const SizedBox(width: 8),
            stat('${s.helpful}', 'found helpful', L360Colors.forest700),
          ],
        ),
        const SizedBox(height: 12),
      ],
      if (s.error != null) ...[ErrorBanner(s.error!), const SizedBox(height: 10)],
      if (s.loading && s.posts.isEmpty)
        const LoadingCards(count: 2)
      else if (s.posts.isEmpty && s.error == null)
        EmptyState(
          icon: Icons.edit_outlined,
          title: 'You have not posted yet',
          text: 'Tell other hikers how the trail is: muddy, a landslide, a dry water source. It helps them plan.',
          actions: [
            PillChip(
              key: const Key('empty-write'),
              label: 'Write your first post',
              on: true,
              leading: const Icon(Icons.add, size: 14, color: Colors.white),
              onTap: () => startCompose(context, ref),
            ),
          ],
        ),
      for (final p in s.posts) ...[
        PostCard(post: p, status: p.status, onTap: () => _open(p)),
        const SizedBox(height: 8),
      ],
      if (s.hasMore && !s.loading)
        OutlinedButton(
          key: const Key('mine-more'),
          onPressed: () => ref.read(myPostsProvider.notifier).load(more: true),
          child: const Text('Show more'),
        ),
    ];
  }
}

class _Header extends ConsumerWidget {
  const _Header({required this.isAdmin, required this.onMinimize});

  final bool isAdmin;
  final VoidCallback onMinimize;

  @override
  Widget build(BuildContext context, WidgetRef ref) => Row(
    children: [
      Container(
        width: 30,
        height: 30,
        decoration: BoxDecoration(
          color: L360Colors.gold50,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: L360Colors.gold100),
        ),
        child: const Icon(Icons.forum_outlined, size: 16, color: L360Colors.gold700),
      ),
      const SizedBox(width: 10),
      Expanded(child: Text('Community', style: Theme.of(context).textTheme.titleLarge)),
      if (isAdmin)
        IconButton(
          key: const Key('community-reports'),
          tooltip: 'Reported posts',
          color: L360Colors.brick600,
          icon: const Icon(Icons.shield_outlined),
          onPressed: () => openCommunityReports(context),
        ),
      IconButton(
        key: const Key('community-minimize'),
        tooltip: 'Minimize',
        icon: const Icon(Icons.expand_more),
        onPressed: onMinimize,
      ),
      IconButton(
        key: const Key('community-close'),
        tooltip: 'Close',
        icon: const Icon(Icons.close),
        onPressed: () => Navigator.maybePop(context),
      ),
    ],
  );
}

/// Feed / Clubs / Mine: a white pill on sand; Clubs counts the new club posts
class _Tabs extends ConsumerWidget {
  const _Tabs({required this.value, required this.onChanged});

  final CommunityTab value;
  final ValueChanged<CommunityTab> onChanged;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final newPosts = (ref.watch(myClubsProvider).value ?? const <CommunityClub>[]).fold(0, (n, c) => n + c.newPosts);
    return Container(
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(color: L360Colors.sand100, borderRadius: BorderRadius.circular(12)),
      child: Row(
        children: [
          for (final (t, label) in const [
            (CommunityTab.feed, 'Feed'),
            (CommunityTab.clubs, 'Clubs'),
            (CommunityTab.mine, 'Mine'),
          ])
            Expanded(
              child: GestureDetector(
                key: Key('community-tab-${t.name}'),
                behavior: HitTestBehavior.opaque,
                onTap: () => onChanged(t),
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 180),
                  height: 34,
                  decoration: BoxDecoration(
                    color: t == value ? Colors.white : Colors.transparent,
                    borderRadius: BorderRadius.circular(9),
                    boxShadow: t == value
                        ? const [BoxShadow(color: Color(0x1A000000), blurRadius: 4, offset: Offset(0, 1))]
                        : null,
                  ),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Text(
                        label,
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w700,
                          color: t == value ? L360Colors.ink : L360Colors.sand600,
                        ),
                      ),
                      if (t == CommunityTab.clubs && newPosts > 0) ...[
                        const SizedBox(width: 6),
                        CountBadge(newPosts, key: const Key('clubs-tab-badge')),
                      ],
                    ],
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// The map layer of recent posts, on or off (remembered)
class CommunityLayerSwitch extends ConsumerWidget {
  const CommunityLayerSwitch({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) => Material(
    color: L360Colors.sand50,
    shape: RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(L360.radiusSmall),
      side: const BorderSide(color: L360Colors.sand200),
    ),
    clipBehavior: Clip.antiAlias,
    child: SwitchListTile.adaptive(
      key: const Key('community-layer'),
      dense: true,
      secondary: const Icon(Icons.forum_outlined, color: L360Colors.forest700),
      title: const Text('Show on the map', style: TextStyle(fontWeight: FontWeight.w700)),
      subtitle: const Text('Posts of the last 30 days in view'),
      value: ref.watch(communityLayerProvider.select((s) => s.shown)),
      onChanged: ref.read(communityLayerProvider.notifier).setShown,
    ),
  );
}

/// One scrolling row of chips (near the map / everywhere, kind, condition); a second row for
/// the audience (Everyone / each club) when I am in clubs
class _Filters extends ConsumerWidget {
  const _Filters({required this.filter, required this.clubs});

  final FeedFilter filter;
  final List<CommunityClub> clubs;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final feed = ref.read(communityFeedProvider.notifier);
    final f = filter;
    Widget gap() => const SizedBox(width: 6);
    Widget divider() =>
        Container(width: 1, height: 20, margin: const EdgeInsets.symmetric(horizontal: 4), color: L360Colors.sand200);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SingleChildScrollView(
          key: const Key('community-filters'),
          scrollDirection: Axis.horizontal,
          child: Row(
            children: [
              PillChip(
                key: const Key('community-scope-near'),
                label: 'Near the map',
                on: f.scope == FeedScope.nearMap,
                leading: Icon(
                  Icons.place_outlined,
                  size: 13,
                  color: f.scope == FeedScope.nearMap ? Colors.white : L360Colors.sand700,
                ),
                onTap: () => feed.setFilter(f.copyWith(scope: FeedScope.nearMap)),
              ),
              gap(),
              PillChip(
                key: const Key('community-scope-all'),
                label: 'Everywhere',
                on: f.scope == FeedScope.all,
                onTap: () => feed.setFilter(f.copyWith(scope: FeedScope.all)),
              ),
              divider(),
              for (final (k, label) in const [(PostKind.report, 'Trail reports'), (PostKind.story, 'Stories')]) ...[
                PillChip(
                  key: Key('community-kind-${k.name}'),
                  label: label,
                  on: f.kinds.contains(k),
                  onTap: () => feed.setFilter(f.copyWith(kinds: f.kinds.contains(k) ? const {} : {k})),
                ),
                gap(),
              ],
              divider(),
              for (final c in trailConditions) ...[
                PillChip(
                  key: Key('community-cond-${c.id}'),
                  label: c.label,
                  on: f.conditions.contains(c.id),
                  leading: Container(
                    width: 8,
                    height: 8,
                    decoration: BoxDecoration(color: hexColor(c.color), shape: BoxShape.circle),
                  ),
                  onTap: () => feed.setFilter(f.copyWith(conditions: f.conditions.contains(c.id) ? const {} : {c.id})),
                ),
                gap(),
              ],
            ],
          ),
        ),
        if (clubs.isNotEmpty) ...[
          const SizedBox(height: 6),
          SingleChildScrollView(
            key: const Key('community-audience'),
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                PillChip(
                  key: const Key('community-everyone'),
                  label: everyoneLabel,
                  on: f.clubId == null,
                  onTap: () => feed.setFilter(f.copyWith(clubId: () => null)),
                ),
                for (final c in clubs) ...[
                  gap(),
                  PillChip(
                    key: Key('community-club-${c.id}'),
                    label: c.name,
                    on: f.clubId == c.id,
                    leading: Icon(
                      Icons.lock_outline,
                      size: 12,
                      color: f.clubId == c.id ? Colors.white : L360Colors.sand700,
                    ),
                    trailing: c.newPosts > 0 && f.clubId != c.id ? CountBadge(c.newPosts) : null,
                    onTap: () => feed.setFilter(f.copyWith(clubId: () => c.id)),
                  ),
                ],
              ],
            ),
          ),
        ],
      ],
    );
  }
}

/// Trail reports written offline, waiting to be sent
class _Outbox extends ConsumerWidget {
  const _Outbox({required this.state});

  final CommunityOutboxState state;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final box = ref.read(communityOutboxProvider.notifier);
    return Container(
      key: const Key('community-outbox'),
      padding: const EdgeInsets.fromLTRB(12, 10, 4, 6),
      decoration: BoxDecoration(
        color: L360Colors.gold50,
        borderRadius: BorderRadius.circular(L360.radiusSmall),
        border: Border.all(color: L360Colors.gold100),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              const Icon(Icons.outbox_outlined, size: 18, color: L360Colors.gold700),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  state.sending
                      ? 'Sending…'
                      : '${state.items.length} trail report${state.items.length == 1 ? '' : 's'} waiting to be sent',
                  style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: L360Colors.gold700),
                ),
              ),
              TextButton(onPressed: state.sending ? null : box.flush, child: const Text('Send now')),
            ],
          ),
          for (final OutboxItem x in state.items)
            Row(
              children: [
                Expanded(
                  child: Text(
                    [
                      x.post.title.trim().isNotEmpty
                          ? x.post.title.trim()
                          : x.post.placeName.trim().isNotEmpty
                          ? x.post.placeName.trim()
                          : 'Trail report',
                      if (x.error != null) x.error!,
                    ].join(' · '),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 12, color: x.error == null ? L360Colors.sand700 : L360Colors.brick600),
                  ),
                ),
                if (x.error != null)
                  IconButton(
                    tooltip: 'Try again',
                    visualDensity: VisualDensity.compact,
                    icon: const Icon(Icons.refresh, size: 18),
                    onPressed: () => box.retry(x.clientId),
                  ),
                IconButton(
                  tooltip: 'Discard',
                  visualDensity: VisualDensity.compact,
                  icon: const Icon(Icons.delete_outline, size: 18),
                  onPressed: () async {
                    if (await confirmDialog(
                      context,
                      title: 'Discard this report?',
                      message: 'It has not been sent and will be removed from this phone.',
                      action: 'Discard',
                    )) {
                      await box.discard(x.clientId);
                    }
                  },
                ),
              ],
            ),
        ],
      ),
    );
  }
}
