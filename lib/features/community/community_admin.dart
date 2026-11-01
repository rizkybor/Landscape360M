import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/app_theme.dart';
import '../../core/ui/widgets.dart';
import '../../domain/community/community.dart';
import 'community_post_page.dart';
import 'community_state.dart';
import 'community_widgets.dart';

// Community Reports for the admin (COMMUNITY_PRD.md 8.5): reported posts and comments, most
// reported first. Restore (visible again, reports cleared), hide or remove; block the author
// from Community for 7 days or until lifted, or lift a block. The server checks is_admin().

Future<void> openCommunityReports(BuildContext context) => Navigator.of(
  context,
  rootNavigator: true,
).push(MaterialPageRoute<void>(builder: (_) => const CommunityReportsPage()));

final reportQueueProvider = FutureProvider.autoDispose<List<ReportQueueItem>>(
  (ref) => ref.watch(communityRepositoryProvider).reportQueue(),
);

class CommunityReportsPage extends ConsumerStatefulWidget {
  const CommunityReportsPage({super.key});

  @override
  ConsumerState<CommunityReportsPage> createState() => _CommunityReportsPageState();
}

class _CommunityReportsPageState extends ConsumerState<CommunityReportsPage> {
  bool _busy = false;

  Future<void> _run(Future<void> Function() task, String done) async {
    setState(() => _busy = true);
    try {
      await task();
      ref.invalidate(reportQueueProvider);
      unawaited(ref.read(communityFeedProvider.notifier).load());
      if (mounted) showSnack(context, done);
    } on Object catch (e) {
      if (mounted) showSnack(context, '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _moderate(ReportQueueItem item, String action) {
    final repo = ref.read(communityRepositoryProvider);
    return _run(() => repo.moderate(item.targetKind, item.targetId, action), switch (action) {
      'restore' => 'Restored.',
      'hide' => 'Hidden.',
      _ => 'Removed.',
    });
  }

  Future<void> _ban(ReportQueueItem item, int? days) async {
    final what = switch (days) {
      0 => 'Lift the block on ${item.authorName}?',
      null => 'Block ${item.authorName} from Community until lifted?',
      _ => 'Block ${item.authorName} from Community for $days days?',
    };
    if (!await confirmDialog(
      context,
      title: what,
      message: days == 0
          ? 'They can post and comment again.'
          : 'They cannot post or comment in Community, but can still use the app.',
      action: days == 0 ? 'Lift' : 'Block',
      destructive: days != 0,
    )) {
      return;
    }
    final repo = ref.read(communityRepositoryProvider);
    await _run(
      () => repo.setBan(item.authorId, days, reason: item.reasons.map(reportReasonLabel).join(', ')),
      days == 0 ? 'Block lifted.' : 'Blocked.',
    );
  }

  @override
  Widget build(BuildContext context) {
    final queue = ref.watch(reportQueueProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('Community Reports')),
      body: RefreshIndicator(
        onRefresh: () => ref.refresh(reportQueueProvider.future),
        child: ListView(
          key: const Key('report-queue'),
          padding: const EdgeInsets.fromLTRB(L360.gutter, 8, L360.gutter, 32),
          children: [
            if (_busy) const LinearProgressIndicator(minHeight: 2),
            ...switch (queue) {
              AsyncData(:final value) when value.isEmpty => [
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 32),
                  child: Text('No reports waiting.', textAlign: TextAlign.center),
                ),
              ],
              AsyncData(:final value) => [for (final item in value) _item(item)],
              AsyncError(:final error) => [ErrorBanner('$error')],
              _ => [
                const Padding(
                  padding: EdgeInsets.all(24),
                  child: Center(child: CircularProgressIndicator()),
                ),
              ],
            },
          ],
        ),
      ),
    );
  }

  Widget _item(ReportQueueItem item) => Card(
    key: Key('queue-${item.targetId}'),
    margin: const EdgeInsets.only(bottom: 10),
    child: Padding(
      padding: const EdgeInsets.fromLTRB(12, 10, 4, 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Pill(
                item.targetKind == 'post' ? 'Post' : 'Comment',
                background: L360Colors.sand100,
                foreground: L360Colors.sand700,
              ),
              const SizedBox(width: 6),
              Pill(
                item.status.name,
                background: item.status == PostStatus.visible ? L360Colors.forest50 : L360Colors.brick50,
                foreground: item.status == PostStatus.visible ? L360Colors.forest700 : L360Colors.brick600,
              ),
              const Spacer(),
              Text(
                '${item.reports} report${item.reports == 1 ? '' : 's'}',
                style: const TextStyle(fontWeight: FontWeight.w700, color: L360Colors.brick600),
              ),
              const SizedBox(width: 8),
            ],
          ),
          const SizedBox(height: 8),
          Text(item.excerpt, style: const TextStyle(fontSize: 14)),
          const SizedBox(height: 4),
          Text(
            [
              'by ${item.authorName}',
              if (item.authorBanned) 'blocked',
              item.reasons.map(reportReasonLabel).join(', '),
            ].join(' · '),
            style: const TextStyle(fontSize: 12, color: L360Colors.sand600),
          ),
          for (final n in item.notes)
            Text(
              '“$n”',
              style: const TextStyle(fontSize: 12, fontStyle: FontStyle.italic, color: L360Colors.sand700),
            ),
          Wrap(
            spacing: 4,
            children: [
              TextButton(
                onPressed: _busy ? null : () => openCommunityPost(context, item.postId),
                child: const Text('Open post'),
              ),
              TextButton(
                key: Key('restore-${item.targetId}'),
                onPressed: _busy ? null : () => _moderate(item, 'restore'),
                child: const Text('Restore'),
              ),
              TextButton(
                key: Key('hide-${item.targetId}'),
                onPressed: _busy ? null : () => _moderate(item, 'hide'),
                child: const Text('Hide'),
              ),
              TextButton(
                key: Key('remove-${item.targetId}'),
                style: TextButton.styleFrom(foregroundColor: L360Colors.brick500),
                onPressed: _busy ? null : () => _moderate(item, 'remove'),
                child: const Text('Remove'),
              ),
              PopupMenuButton<int>(
                key: Key('ban-${item.targetId}'),
                tooltip: 'Block author',
                enabled: !_busy,
                // -1: until lifted (a null value would read as cancelled)
                onSelected: (days) => _ban(item, days < 0 ? null : days),
                itemBuilder: (_) => [
                  const PopupMenuItem(value: 7, child: Text('Block author 7 days')),
                  const PopupMenuItem(value: -1, child: Text('Block author permanently')),
                  if (item.authorBanned) const PopupMenuItem(value: 0, child: Text('Lift block')),
                ],
                child: const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                  child: Text(
                    'Block…',
                    style: TextStyle(color: L360Colors.brick500, fontWeight: FontWeight.w600),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    ),
  );
}
