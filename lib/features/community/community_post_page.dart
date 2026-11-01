import 'dart:async';

import 'package:flutter/material.dart';
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
import 'community_compose.dart';
import 'community_state.dart';
import 'community_widgets.dart';

// One post (COMMUNITY_PRD.md 8.1, 8.5): its photos, conditions and text, the attached map data
// with "Show on map", Helpful, comments, reporting, and for the author editing (24 hours),
// deleting and sharing its link. A club post shows its badge and has no public link.

Future<void> openCommunityPost(BuildContext context, String id, {CommunityPost? initial}) =>
    Navigator.of(context, rootNavigator: true).push(
      MaterialPageRoute<void>(
        builder: (_) => CommunityPostPage(id: id, initial: initial),
      ),
    );

class CommunityPostPage extends ConsumerStatefulWidget {
  const CommunityPostPage({super.key, required this.id, this.initial});

  final String id;
  final CommunityPost? initial; // the feed's copy, shown while the full post loads

  @override
  ConsumerState<CommunityPostPage> createState() => _CommunityPostPageState();
}

class _CommunityPostPageState extends ConsumerState<CommunityPostPage> {
  late CommunityPost? _post = widget.initial;
  List<CommunityComment> _comments = const [];
  bool _loading = true;
  bool _gone = false;
  String? _error;
  bool _busy = false;
  final _comment = TextEditingController();

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  @override
  void dispose() {
    _comment.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final repo = ref.read(communityRepositoryProvider);
    try {
      final post = await repo.post(widget.id);
      final comments = post == null ? const <CommunityComment>[] : await repo.comments(widget.id);
      if (!mounted) return;
      setState(() {
        _post = post ?? _post;
        _gone = post == null;
        _comments = comments;
        _loading = false;
        _error = null;
      });
      if (post != null) ref.read(communityFeedProvider.notifier).replace(post.copyWith());
    } on Object catch (e) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = '$e';
        });
      }
    }
  }

  bool get _signedIn => ref.read(authUserIdProvider).value != null;

  Future<bool> _needSignIn(String reason) async {
    if (_signedIn) return false;
    await showSignInSheet(context, title: 'Community', reason: reason);
    return true;
  }

  Future<void> _run(Future<void> Function() task) async {
    setState(() => _busy = true);
    try {
      await task();
    } on Object catch (e) {
      if (mounted) showSnack(context, '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _helpful() async {
    final p = _post;
    if (p == null || await _needSignIn('Sign in to mark posts as helpful.')) return;
    await _run(() async {
      final r = await ref.read(communityRepositoryProvider).toggleHelpful(p.id);
      final next = p.copyWith(iFoundHelpful: r.helpful, helpfulCount: r.count);
      setState(() => _post = next);
      ref.read(communityFeedProvider.notifier).replace(next);
    });
  }

  Future<void> _addComment() async {
    final p = _post;
    final text = _comment.text.trim();
    if (p == null || text.isEmpty) return;
    if (textLength(text) > commentLimit) {
      showSnack(context, 'A comment is at most $commentLimit characters.');
      return;
    }
    await _run(() async {
      await ref.read(communityRepositoryProvider).addComment(p.id, text);
      _comment.clear();
      if (mounted) FocusScope.of(context).unfocus();
      await _load();
    });
  }

  Future<void> _deleteComment(CommunityComment c) async {
    if (!await confirmDialog(context, title: 'Delete comment?', message: c.body, action: 'Delete')) return;
    await _run(() async {
      await ref.read(communityRepositoryProvider).deleteComment(c.id);
      await _load();
    });
  }

  Future<void> _report(String kind, String id) async {
    if (await _needSignIn('Sign in to report a post or comment.')) return;
    if (!mounted) return;
    final sent = await showReportSheet(context, kind: kind, id: id);
    if (sent == true && mounted) showSnack(context, 'Thank you. The admin will look at it.');
  }

  Future<void> _delete() async {
    final p = _post;
    if (p == null) return;
    if (!await confirmDialog(
      context,
      title: 'Delete this post?',
      message: 'The post, its photos, comments and Helpful marks are deleted for good.',
      action: 'Delete',
    )) {
      return;
    }
    await _run(() async {
      await ref.read(communityRepositoryProvider).delete(p.id);
      ref.read(communityFeedProvider.notifier).remove(p.id);
      ref.invalidate(communityLimitsProvider);
      if (ref.read(communityFocusProvider)?.post?.id == p.id) ref.read(communityFocusProvider.notifier).clear();
      if (mounted) Navigator.pop(context);
    });
  }

  /// A club leader or admin pins it first in the club's feed (up to 3), or unpins it
  Future<void> _pin(bool pinned) async {
    final p = _post;
    if (p == null) return;
    await _run(() async {
      await ref.read(communityRepositoryProvider).pinPost(p.id, pinned);
      final next = p.copyWith(pinned: pinned);
      setState(() => _post = next);
      ref.read(communityFeedProvider.notifier).replace(next);
      if (mounted) showSnack(context, pinned ? 'Pinned to the top of the club feed.' : 'Unpinned.');
    });
  }

  Future<void> _edit() async {
    final p = _post;
    if (p == null) return;
    final saved = await openCompose(context, editing: p);
    if (saved == true) await _load();
  }

  Future<void> _share() async {
    final p = _post;
    if (p == null || p.membersOnly) return;
    await SharePlus.instance.share(
      ShareParams(
        text: ['${p.kind == PostKind.report ? '🥾' : '📖'} ${postHeading(p)}', postUrl(p.id)].join('\n'),
        subject: postHeading(p),
      ),
    );
  }

  void _showOnMap() {
    final p = _post;
    if (p == null) return;
    ref.read(communityFocusProvider.notifier).show(p);
    Navigator.of(context).popUntil((r) => r.isFirst);
  }

  void _openClassic(ClassicAttachment a) {
    unawaited(ref.read(sharedLinkProvider.notifier).open(ClassicLink(a.token)));
    Navigator.of(context).popUntil((r) => r.isFirst);
  }

  @override
  Widget build(BuildContext context) {
    final p = _post;
    final now = ref.watch(communityClockProvider)();
    final isAdmin = ref.watch(profileProvider.select((x) => x.value?.isAdmin ?? false));
    final signedIn = ref.watch(authUserIdProvider.select((a) => a.value != null));
    return Scaffold(
      appBar: AppBar(
        title: Text(p?.kind.label ?? 'Community'),
        actions: [
          if (p != null && !p.membersOnly && !_gone)
            IconButton(
              key: const Key('post-share'),
              tooltip: 'Share link',
              icon: const Icon(Icons.share),
              onPressed: _share,
            ),
          if (p != null && !_gone)
            PopupMenuButton<String>(
              key: const Key('post-menu'),
              onSelected: (v) => switch (v) {
                'edit' => _edit(),
                'delete' => _delete(),
                'pin' => _pin(true),
                'unpin' => _pin(false),
                _ => _report('post', p.id),
              },
              itemBuilder: (_) => [
                if (p.canPin && !p.pinned) const PopupMenuItem(value: 'pin', child: Text('Pin to the club')),
                if (p.canPin && p.pinned) const PopupMenuItem(value: 'unpin', child: Text('Unpin')),
                if (canEdit(p, now)) const PopupMenuItem(value: 'edit', child: Text('Edit')),
                if (p.isMine) const PopupMenuItem(value: 'delete', child: Text('Delete')),
                if (!p.isMine) const PopupMenuItem(value: 'report', child: Text('Report')),
              ],
            ),
        ],
      ),
      body: p == null && _loading
          ? const Center(child: CircularProgressIndicator())
          : p == null || _gone
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text(
                  _error ?? 'This post is no longer available. It may have been deleted or hidden.',
                  key: const Key('post-gone'),
                  textAlign: TextAlign.center,
                ),
              ),
            )
          : RefreshIndicator(
              onRefresh: _load,
              child: ListView(
                padding: const EdgeInsets.fromLTRB(L360.gutter, 8, L360.gutter, 32),
                children: [
                  if (_error != null) ...[ErrorBanner(_error!), const SizedBox(height: 10)],
                  if (p.status != PostStatus.visible) ...[
                    ErrorBanner(
                      p.status == PostStatus.hidden
                          ? 'This post is hidden from Community until the admin has looked at it.'
                          : 'This post was removed by the admin.',
                    ),
                    const SizedBox(height: 10),
                  ],
                  _Header(post: p, now: now),
                  const SizedBox(height: 12),
                  SelectableText(p.body, style: const TextStyle(fontSize: 15, height: 1.45)),
                  if (p.truncated && _loading)
                    const Padding(padding: EdgeInsets.only(top: 6), child: LinearProgressIndicator(minHeight: 2)),
                  if (p.photos.isNotEmpty) ...[const SizedBox(height: 12), _Photos(photos: p.photos)],
                  const SizedBox(height: 12),
                  if (p.attachment != null) ...[
                    _AttachmentCard(attachment: p.attachment!, onShow: _showOnMap, onOpenClassic: _openClassic),
                    const SizedBox(height: 10),
                  ],
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      OutlinedButton.icon(
                        key: const Key('post-helpful'),
                        style: OutlinedButton.styleFrom(
                          minimumSize: const Size(0, 42),
                          foregroundColor: p.iFoundHelpful ? L360Colors.forest700 : null,
                          backgroundColor: p.iFoundHelpful ? L360Colors.forest50 : null,
                        ),
                        onPressed: _busy || p.status != PostStatus.visible ? null : _helpful,
                        icon: Icon(p.iFoundHelpful ? Icons.thumb_up : Icons.thumb_up_outlined, size: 18),
                        label: Text('Helpful · ${p.helpfulCount}'),
                      ),
                      OutlinedButton.icon(
                        key: const Key('post-show-on-map'),
                        style: OutlinedButton.styleFrom(minimumSize: const Size(0, 42)),
                        onPressed: _showOnMap,
                        icon: const Icon(Icons.map_outlined, size: 18),
                        label: const Text('Show on map'),
                      ),
                    ],
                  ),
                  const SizedBox(height: 18),
                  Text(
                    'Comments (${_comments.length})',
                    style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
                  ),
                  const SizedBox(height: 6),
                  if (_comments.isEmpty && !_loading)
                    const Padding(
                      padding: EdgeInsets.symmetric(vertical: 8),
                      child: Text('No comments yet.', style: TextStyle(color: L360Colors.sand500, fontSize: 13)),
                    ),
                  for (final c in _comments)
                    _CommentTile(
                      comment: c,
                      now: now,
                      onDelete: c.isMine || isAdmin ? () => _deleteComment(c) : null,
                      onReport: !c.isMine && signedIn ? () => _report('comment', c.id) : null,
                    ),
                  const SizedBox(height: 8),
                  if (signedIn && p.status == PostStatus.visible)
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        Expanded(
                          child: TextField(
                            key: const Key('comment-field'),
                            controller: _comment,
                            minLines: 1,
                            maxLines: 4,
                            maxLength: commentLimit,
                            textCapitalization: TextCapitalization.sentences,
                            decoration: const InputDecoration(hintText: 'Ask or add something…', counterText: ''),
                          ),
                        ),
                        IconButton(
                          key: const Key('comment-send'),
                          tooltip: 'Send',
                          icon: const Icon(Icons.send),
                          onPressed: _busy ? null : _addComment,
                        ),
                      ],
                    )
                  else if (!signedIn)
                    TextButton(
                      onPressed: () => _needSignIn('Sign in to comment on posts.'),
                      child: const Text('Sign in to comment'),
                    ),
                ],
              ),
            ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({required this.post, required this.now});

  final CommunityPost post;
  final DateTime now;

  @override
  Widget build(BuildContext context) {
    final (icon, color) = postMarker(post);
    final day = post.happenedDay;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (post.clubName != null || post.pinned) ...[
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              if (post.pinned) const PinnedBadge(),
              if (post.clubName != null) ClubBadge(name: post.clubName!),
            ],
          ),
          const SizedBox(height: 8),
        ],
        Row(
          children: [
            Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(color: color, shape: BoxShape.circle),
              child: Icon(icon, size: 20, color: Colors.white),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(postHeading(post), style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
                  Text(
                    [post.byline, timeAgo(post.createdAt, now), if (post.editedAt != null) 'edited'].join(' · '),
                    key: const Key('post-byline'),
                    style: const TextStyle(fontSize: 12, color: L360Colors.sand600),
                  ),
                ],
              ),
            ),
            if (isOldReport(post, now)) const OldBadge(),
          ],
        ),
        const SizedBox(height: 8),
        Text(
          [
            if (post.placeName?.isNotEmpty ?? false) post.placeName!,
            if (day != null) '${post.kind == PostKind.report ? 'Seen on' : 'On'} ${formatDay(day)}',
          ].join(' · '),
          style: const TextStyle(fontSize: 13, color: L360Colors.sand700),
        ),
        if (post.conditions.isNotEmpty) ...[
          const SizedBox(height: 8),
          Wrap(spacing: 6, runSpacing: 6, children: [for (final c in post.conditions) ConditionChip(c)]),
        ],
      ],
    );
  }
}

class _Photos extends ConsumerWidget {
  const _Photos({required this.photos});

  final List<CommunityPhoto> photos;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final url = ref.watch(communityPhotoUrlProvider);
    return SizedBox(
      height: 200,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        itemCount: photos.length,
        separatorBuilder: (_, _) => const SizedBox(width: 8),
        itemBuilder: (context, i) {
          final ph = photos[i];
          final width = ph.height > 0 ? (200 * ph.width / ph.height).clamp(120.0, 320.0) : 200.0;
          return GestureDetector(
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                fullscreenDialog: true,
                builder: (_) => Scaffold(
                  backgroundColor: Colors.black,
                  appBar: AppBar(backgroundColor: Colors.black, foregroundColor: Colors.white),
                  body: InteractiveViewer(child: Center(child: Image.network(url(ph.path)))),
                ),
              ),
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(L360.radiusSmall),
              child: Image.network(
                url(ph.path),
                width: width,
                height: 200,
                fit: BoxFit.cover,
                errorBuilder: (_, _, _) => Container(
                  width: width,
                  height: 200,
                  color: L360Colors.sand100,
                  child: const Icon(Icons.broken_image_outlined, color: L360Colors.sand400),
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

class _AttachmentCard extends StatelessWidget {
  const _AttachmentCard({required this.attachment, required this.onShow, required this.onOpenClassic});

  final Attachment attachment;
  final VoidCallback onShow;
  final ValueChanged<ClassicAttachment> onOpenClassic;

  @override
  Widget build(BuildContext context) {
    final a = attachment;
    final (icon, detail) = switch (a) {
      PlaceAttachment() => (Icons.pin_drop_outlined, a.label),
      AreaAttachment() => (Icons.hexagon_outlined, a.label),
      TrackAttachment(:final distanceM) => (Icons.timeline, '${a.label} · ${formatLength(distanceM)}'),
      ClassicAttachment() => (Icons.architecture, a.label),
    };
    return Container(
      key: const Key('post-attachment'),
      padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
      decoration: BoxDecoration(
        color: L360Colors.sand50,
        borderRadius: BorderRadius.circular(L360.radiusSmall),
        border: Border.all(color: L360Colors.sand200),
      ),
      child: Row(
        children: [
          Icon(icon, color: L360Colors.forest700),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(a.name, style: const TextStyle(fontWeight: FontWeight.w700)),
                Text(detail, style: const TextStyle(fontSize: 12, color: L360Colors.sand600)),
              ],
            ),
          ),
          if (a is ClassicAttachment)
            TextButton(onPressed: () => onOpenClassic(a), child: const Text('Open'))
          else
            TextButton(key: const Key('attachment-show'), onPressed: onShow, child: const Text('Show on map')),
        ],
      ),
    );
  }
}

class _CommentTile extends StatelessWidget {
  const _CommentTile({required this.comment, required this.now, this.onDelete, this.onReport});

  final CommunityComment comment;
  final DateTime now;
  final VoidCallback? onDelete;
  final VoidCallback? onReport;

  @override
  Widget build(BuildContext context) => Padding(
    key: Key('comment-${comment.id}'),
    padding: const EdgeInsets.symmetric(vertical: 6),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                [comment.authorName, ?comment.authorOrganization, timeAgo(comment.createdAt, now)].join(' · '),
                style: const TextStyle(fontSize: 11, color: L360Colors.sand600),
              ),
              const SizedBox(height: 2),
              Text(comment.body, style: const TextStyle(fontSize: 14, height: 1.35)),
            ],
          ),
        ),
        if (onDelete != null)
          IconButton(
            tooltip: 'Delete comment',
            visualDensity: VisualDensity.compact,
            icon: const Icon(Icons.delete_outline, size: 18),
            onPressed: onDelete,
          ),
        if (onReport != null)
          IconButton(
            tooltip: 'Report comment',
            visualDensity: VisualDensity.compact,
            icon: const Icon(Icons.flag_outlined, size: 18),
            onPressed: onReport,
          ),
      ],
    ),
  );
}

/// Why a post or comment is reported; true once sent
Future<bool?> showReportSheet(BuildContext context, {required String kind, required String id}) =>
    showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (_) => _ReportSheet(kind: kind, id: id),
    );

class _ReportSheet extends ConsumerStatefulWidget {
  const _ReportSheet({required this.kind, required this.id});

  final String kind;
  final String id;

  @override
  ConsumerState<_ReportSheet> createState() => _ReportSheetState();
}

class _ReportSheetState extends ConsumerState<_ReportSheet> {
  String? _reason;
  final _note = TextEditingController();
  bool _sending = false;
  String? _error;

  @override
  void dispose() {
    _note.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    final reason = _reason;
    if (reason == null) return;
    setState(() {
      _sending = true;
      _error = null;
    });
    try {
      await ref.read(communityRepositoryProvider).report(widget.kind, widget.id, reason, _note.text);
      if (mounted) Navigator.pop(context, true);
    } on Object catch (e) {
      if (mounted) {
        setState(() {
          _sending = false;
          _error = '$e';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) => Padding(
    key: const Key('report-sheet'),
    padding: EdgeInsets.fromLTRB(L360.gutter, 4, L360.gutter, 16 + MediaQuery.viewInsetsOf(context).bottom),
    child: SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            widget.kind == 'post' ? 'Report post' : 'Report comment',
            style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 8),
          RadioGroup<String>(
            groupValue: _reason,
            onChanged: (v) => setState(() => _reason = v),
            child: Column(
              children: [
                for (final (id, label) in reportReasons)
                  RadioListTile<String>(key: Key('reason-$id'), dense: true, value: id, title: Text(label)),
              ],
            ),
          ),
          TextField(
            controller: _note,
            maxLength: reportNoteLimit,
            minLines: 1,
            maxLines: 3,
            decoration: const InputDecoration(labelText: 'Note (optional)'),
          ),
          if (_error != null) ...[const SizedBox(height: 8), ErrorBanner(_error!)],
          const SizedBox(height: 10),
          FilledButton(
            key: const Key('report-send'),
            onPressed: _reason == null || _sending ? null : _send,
            child: const Text('Send report'),
          ),
        ],
      ),
    ),
  );
}
