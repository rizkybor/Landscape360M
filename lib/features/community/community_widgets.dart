import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/app_theme.dart';
import '../../domain/community/community.dart';
import 'community_state.dart';

// Pieces shared by the feed, the post and the map: condition chips with icon and colour,
// the club badge, the "old" label and the feed card.

Color hexColor(String hex) => Color(int.parse('FF${hex.replaceFirst('#', '')}', radix: 16));

/// Stories: gold (the web's kindColor)
const storyColor = '#d49b22';

/// Icon of each trail condition (the label is always shown with it)
const conditionIcons = <String, IconData>{
  'safe': Icons.check_circle_outline,
  'muddy': Icons.waves,
  'landslide': Icons.landslide_outlined,
  'fallen_tree': Icons.park_outlined,
  'water_ok': Icons.water_drop_outlined,
  'water_dry': Icons.format_color_reset_outlined,
  'closed': Icons.block,
  'bad_weather': Icons.thunderstorm_outlined,
  'wildlife': Icons.pets,
  'other': Icons.info_outline,
};

IconData conditionIcon(String id) => conditionIcons[id] ?? Icons.info_outline;

/// Icon and colour of a post on the map and in its card: its first condition, or a story
(IconData, Color) postMarker(CommunityPost p) {
  final c = mainCondition(p);
  return c == null ? (Icons.auto_stories_outlined, hexColor(storyColor)) : (conditionIcon(c.id), hexColor(c.color));
}

class ConditionChip extends StatelessWidget {
  const ConditionChip(this.id, {super.key, this.small = false});

  final String id;
  final bool small;

  @override
  Widget build(BuildContext context) {
    final c = conditionOf(id);
    final color = hexColor(c.color);
    return Container(
      padding: EdgeInsets.symmetric(horizontal: small ? 6 : 8, vertical: small ? 2 : 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: color.withValues(alpha: 0.35)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(conditionIcon(id), size: small ? 12 : 14, color: color),
          const SizedBox(width: 4),
          Text(
            c.label,
            style: TextStyle(fontSize: small ? 10 : 12, fontWeight: FontWeight.w700, color: color),
          ),
        ],
      ),
    );
  }
}

/// "Club: Mapala UI · Members only"
class ClubBadge extends StatelessWidget {
  const ClubBadge({super.key, required this.name});

  final String name;

  @override
  Widget build(BuildContext context) => Container(
    key: const Key('club-badge'),
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
    decoration: BoxDecoration(color: L360Colors.gold50, borderRadius: BorderRadius.circular(20)),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Icon(Icons.lock_outline, size: 12, color: L360Colors.gold700),
        const SizedBox(width: 4),
        Flexible(
          child: Text(
            'Club: $name · $membersOnlyLabel',
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: L360Colors.gold700),
          ),
        ),
      ],
    ),
  );
}

/// A club announcement, first in the club's feed
class PinnedBadge extends StatelessWidget {
  const PinnedBadge({super.key});

  @override
  Widget build(BuildContext context) => Container(
    key: const Key('pinned-badge'),
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
    decoration: BoxDecoration(color: L360Colors.forest50, borderRadius: BorderRadius.circular(20)),
    child: const Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(Icons.push_pin, size: 12, color: L360Colors.forest700),
        SizedBox(width: 4),
        Text(
          'Pinned',
          style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: L360Colors.forest700),
        ),
      ],
    ),
  );
}

class OldBadge extends StatelessWidget {
  const OldBadge({super.key});

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
    decoration: BoxDecoration(color: L360Colors.sand200, borderRadius: BorderRadius.circular(8)),
    child: const Text(
      'old',
      style: TextStyle(fontSize: 10, fontWeight: FontWeight.w700, color: L360Colors.sand700),
    ),
  );
}

/// Title, or the kind for a post without one
String postHeading(CommunityPost p) => (p.title?.trim().isNotEmpty ?? false)
    ? p.title!.trim()
    : (p.placeName?.trim().isNotEmpty ?? false)
    ? p.placeName!
    : p.kind.label;

/// Colour of a post's kind: its first condition for a trail report, gold for a story
Color kindColor(CommunityPost p) {
  final c = mainCondition(p);
  return p.kind == PostKind.report && c != null ? hexColor(c.color) : hexColor(storyColor);
}

/// The first letter of a name in a small circle
class InitialAvatar extends StatelessWidget {
  const InitialAvatar(this.name, {super.key, this.size = 18});

  final String name;
  final double size;

  @override
  Widget build(BuildContext context) => Container(
    width: size,
    height: size,
    alignment: Alignment.center,
    decoration: const BoxDecoration(color: L360Colors.sand200, shape: BoxShape.circle),
    child: Text(
      name.trim().isEmpty ? '?' : String.fromCharCode(name.trim().runes.first).toUpperCase(),
      style: TextStyle(fontSize: size * 0.5, fontWeight: FontWeight.w700, color: L360Colors.sand700),
    ),
  );
}

/// White, rounded 12, a light shadow: the card of the Community lists
class CommunityCard extends StatelessWidget {
  const CommunityCard({super.key, required this.child, this.onTap});

  final Widget child;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) => Material(
    color: Colors.white,
    elevation: 1,
    shadowColor: const Color(0x22000000),
    shape: RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(12),
      side: const BorderSide(color: L360Colors.sand200),
    ),
    clipBehavior: Clip.antiAlias,
    child: InkWell(onTap: onTap, child: child),
  );
}

/// A post in a list (PostCard on the web): a colour stripe for its kind; the kind, Pinned,
/// "old" and the time; the title, conditions, two lines of text and the first photo; the
/// author, place, club and the Helpful / comment counts. [status] marks my hidden or removed posts.
class PostCard extends ConsumerWidget {
  const PostCard({super.key, required this.post, required this.onTap, this.status});

  final CommunityPost post;
  final VoidCallback onTap;
  final PostStatus? status;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final now = ref.watch(communityClockProvider)();
    final url = ref.watch(communityPhotoUrlProvider);
    final color = kindColor(post);
    final title = post.title?.trim() ?? '';
    const small = TextStyle(fontSize: 10, color: L360Colors.sand600);
    final top = TextStyle(fontSize: 9, fontWeight: FontWeight.w800, letterSpacing: 0.8, color: color);
    return CommunityCard(
      key: Key('post-${post.id}'),
      onTap: onTap,
      child: IntrinsicHeight(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Container(key: const Key('post-stripe'), width: 4, color: color),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Text(post.kind.label.toUpperCase(), style: top),
                        if (post.pinned) ...[
                          const SizedBox(width: 6),
                          const Icon(Icons.push_pin, size: 10, color: L360Colors.brick600),
                          Text('PINNED', style: top.copyWith(color: L360Colors.brick600)),
                        ],
                        if (isOldReport(post, now)) Text(' · OLD', style: top.copyWith(color: L360Colors.sand500)),
                        if (status != null && status != PostStatus.visible)
                          Text(
                            ' · ${status!.name.toUpperCase()}',
                            key: const Key('post-status'),
                            style: top.copyWith(color: L360Colors.brick600),
                          ),
                        const Spacer(),
                        Text(timeAgo(post.createdAt, now), style: small.copyWith(color: L360Colors.sand500)),
                      ],
                    ),
                    const SizedBox(height: 6),
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              if (title.isNotEmpty)
                                Padding(
                                  padding: const EdgeInsets.only(bottom: 4),
                                  child: Text(
                                    title,
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700, height: 1.3),
                                  ),
                                ),
                              if (post.conditions.isNotEmpty)
                                Padding(
                                  padding: const EdgeInsets.only(bottom: 4),
                                  child: Wrap(
                                    spacing: 4,
                                    runSpacing: 4,
                                    children: [for (final c in post.conditions) ConditionChip(c, small: true)],
                                  ),
                                ),
                              Text(
                                '${post.body}${post.truncated ? '…' : ''}',
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(fontSize: 11, height: 1.45, color: L360Colors.sand700),
                              ),
                            ],
                          ),
                        ),
                        if (post.photos.isNotEmpty) ...[
                          const SizedBox(width: 10),
                          ClipRRect(
                            borderRadius: BorderRadius.circular(8),
                            child: Image.network(
                              url(post.photos.first.path),
                              key: const Key('post-thumb'),
                              width: 64,
                              height: 64,
                              fit: BoxFit.cover,
                              errorBuilder: (_, _, _) => Container(width: 64, height: 64, color: L360Colors.sand100),
                            ),
                          ),
                        ],
                      ],
                    ),
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        InitialAvatar(post.authorName),
                        const SizedBox(width: 6),
                        Flexible(
                          child: Text.rich(
                            TextSpan(
                              children: [
                                TextSpan(
                                  text: post.authorName,
                                  style: const TextStyle(fontWeight: FontWeight.w700, color: L360Colors.ink),
                                ),
                                if (post.placeName?.isNotEmpty ?? false) TextSpan(text: ' · ${post.placeName}'),
                              ],
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: small,
                          ),
                        ),
                        if (post.clubName != null) ...[
                          const SizedBox(width: 6),
                          Flexible(child: ClubBadge(name: post.clubName!)),
                        ],
                        const Spacer(),
                        Icon(
                          post.iFoundHelpful ? Icons.thumb_up : Icons.thumb_up_outlined,
                          size: 11,
                          color: post.iFoundHelpful ? L360Colors.forest700 : L360Colors.sand600,
                        ),
                        const SizedBox(width: 3),
                        Text(
                          '${post.helpfulCount}',
                          key: const Key('post-helpful-count'),
                          style: small.copyWith(
                            color: post.iFoundHelpful ? L360Colors.forest700 : L360Colors.sand600,
                            fontWeight: post.iFoundHelpful ? FontWeight.w700 : null,
                          ),
                        ),
                        const SizedBox(width: 10),
                        const Icon(Icons.chat_bubble_outline, size: 11, color: L360Colors.sand600),
                        const SizedBox(width: 3),
                        Text('${post.commentCount}', style: small),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Nothing to list: a gold icon tile, a title, a short text and actions
class EmptyState extends StatelessWidget {
  const EmptyState({super.key, required this.icon, required this.title, required this.text, this.actions = const []});

  final IconData icon;
  final String title;
  final String text;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) => Padding(
    key: const Key('empty-state'),
    padding: const EdgeInsets.symmetric(vertical: 28, horizontal: 16),
    child: Column(
      children: [
        Container(
          width: 48,
          height: 48,
          decoration: BoxDecoration(
            color: L360Colors.gold50,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: L360Colors.gold100),
          ),
          child: Icon(icon, size: 22, color: L360Colors.gold700),
        ),
        const SizedBox(height: 10),
        Text(
          title,
          textAlign: TextAlign.center,
          style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 4),
        ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 280),
          child: Text(
            text,
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 12, height: 1.45, color: L360Colors.sand600),
          ),
        ),
        if (actions.isNotEmpty) ...[
          const SizedBox(height: 10),
          Wrap(alignment: WrapAlignment.center, spacing: 8, runSpacing: 8, children: actions),
        ],
      ],
    ),
  );
}

/// A rounded chip: filters, and the actions of an empty state ([on]: forest green)
class PillChip extends StatelessWidget {
  const PillChip({super.key, required this.label, required this.on, required this.onTap, this.leading, this.trailing});

  final String label;
  final bool on;
  final VoidCallback onTap;
  final Widget? leading;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) => Material(
    color: on ? L360Colors.forest800 : Colors.white,
    shape: StadiumBorder(side: BorderSide(color: on ? L360Colors.forest800 : L360Colors.sand200)),
    child: InkWell(
      customBorder: const StadiumBorder(),
      onTap: onTap,
      child: Container(
        height: 30,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (leading != null) ...[leading!, const SizedBox(width: 4)],
            Text(
              label,
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: on ? Colors.white : L360Colors.sand700,
              ),
            ),
            if (trailing != null) ...[const SizedBox(width: 4), trailing!],
          ],
        ),
      ),
    ),
  );
}

/// A small red count (new club posts)
class CountBadge extends StatelessWidget {
  const CountBadge(this.count, {super.key});

  final int count;

  @override
  Widget build(BuildContext context) => Container(
    constraints: const BoxConstraints(minWidth: 16),
    height: 16,
    padding: const EdgeInsets.symmetric(horizontal: 4),
    alignment: Alignment.center,
    decoration: BoxDecoration(color: L360Colors.brick600, borderRadius: BorderRadius.circular(8)),
    child: Text(
      count > 99 ? '99+' : '$count',
      style: const TextStyle(fontSize: 9, fontWeight: FontWeight.w700, color: Colors.white),
    ),
  );
}

/// Three grey cards pulsing while the list loads
class LoadingCards extends StatefulWidget {
  const LoadingCards({super.key, this.count = 3});

  final int count;

  @override
  State<LoadingCards> createState() => _LoadingCardsState();
}

class _LoadingCardsState extends State<LoadingCards> with SingleTickerProviderStateMixin {
  late final _pulse = AnimationController(vsync: this, duration: const Duration(milliseconds: 900))
    ..repeat(reverse: true);

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => FadeTransition(
    key: const Key('loading-cards'),
    opacity: Tween<double>(begin: 0.45, end: 1).animate(_pulse),
    child: Column(
      children: [
        for (var i = 0; i < widget.count; i++)
          Container(
            height: 96,
            margin: const EdgeInsets.only(bottom: 8),
            decoration: BoxDecoration(color: L360Colors.sand100, borderRadius: BorderRadius.circular(12)),
          ),
      ],
    ),
  );
}

void showSnack(BuildContext context, String text) => ScaffoldMessenger.maybeOf(context)
  ?..hideCurrentSnackBar()
  ..showSnackBar(SnackBar(content: Text(text)));

Future<bool> confirmDialog(
  BuildContext context, {
  required String title,
  required String message,
  required String action,
  bool destructive = true,
}) async =>
    await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: Text(message),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          TextButton(
            key: const Key('confirm-action'),
            style: destructive ? TextButton.styleFrom(foregroundColor: L360Colors.brick500) : null,
            onPressed: () => Navigator.pop(context, true),
            child: Text(action),
          ),
        ],
      ),
    ) ??
    false;
