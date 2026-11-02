import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/theme/app_theme.dart';
import '../../core/ui/widgets.dart';
import '../../data/community/community_events_repository.dart';
import '../../domain/community/community.dart';
import '../../domain/community/community_attachments.dart';
import '../../domain/community/community_events.dart';
import '../../domain/marked/marked_areas.dart' show formatLength;
import '../../domain/tracks/track_recorder_geo.dart' show TrackStats, formatDuration;
import '../map/map_tools_state.dart';
import 'community_club_page.dart' show clubItemsProvider;
import 'community_compose.dart';
import 'community_live_state.dart';
import 'community_state.dart';
import 'community_widgets.dart';

// Club expeditions (20261102000029): the Events tab of a club (upcoming and running first, past on
// request), the event page (times, meeting point and route on the map, joining with an optional
// emergency contact, participants, the gear checklist, live position sharing and the live map,
// and after the event my summary with "Save my track to the workspace" and "Write a story"), and
// the organisers' form.

final clubEventsProvider = FutureProvider.family<List<EventSummary>, (String, bool)>(
  (ref, key) => ref.watch(communityEventsRepositoryProvider).events(key.$1, past: key.$2),
);

// --- State badge ---------------------------------------------------------------------------------

/// Upcoming / Running now (green, pulsing dot) / Ended / Cancelled
class EventStateBadge extends StatefulWidget {
  const EventStateBadge(this.state, {super.key});

  final EventState state;

  @override
  State<EventStateBadge> createState() => _EventStateBadgeState();
}

class _EventStateBadgeState extends State<EventStateBadge> with SingleTickerProviderStateMixin {
  AnimationController? _pulse;

  @override
  void initState() {
    super.initState();
    _sync();
  }

  @override
  void didUpdateWidget(EventStateBadge old) {
    super.didUpdateWidget(old);
    _sync();
  }

  void _sync() {
    if (widget.state == EventState.running && _pulse == null) {
      _pulse = AnimationController(vsync: this, duration: const Duration(milliseconds: 900))..repeat(reverse: true);
    } else if (widget.state != EventState.running) {
      _pulse?.dispose();
      _pulse = null;
    }
  }

  @override
  void dispose() {
    _pulse?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final (bg, fg) = switch (widget.state) {
      EventState.planned => (L360Colors.gold50, L360Colors.gold700),
      EventState.running => (L360Colors.forest50, L360Colors.forest700),
      EventState.ended => (L360Colors.sand100, L360Colors.sand600),
      EventState.cancelled => (L360Colors.brick50, L360Colors.brick600),
    };
    final pulse = _pulse;
    return Container(
      key: Key('event-state-${widget.state.name}'),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(20)),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (pulse != null) ...[
            FadeTransition(
              opacity: Tween<double>(begin: 0.3, end: 1).animate(pulse),
              child: Container(
                width: 7,
                height: 7,
                decoration: const BoxDecoration(color: L360Colors.forest600, shape: BoxShape.circle),
              ),
            ),
            const SizedBox(width: 5),
          ],
          Text(
            widget.state.label,
            style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: fg),
          ),
        ],
      ),
    );
  }
}

// --- Events tab ----------------------------------------------------------------------------------

class ClubEventsTab extends ConsumerStatefulWidget {
  const ClubEventsTab({super.key, required this.club});

  final CommunityClub club;

  @override
  ConsumerState<ClubEventsTab> createState() => _ClubEventsTabState();
}

class _ClubEventsTabState extends ConsumerState<ClubEventsTab> {
  bool _past = false;

  @override
  Widget build(BuildContext context) {
    final events = ref.watch(clubEventsProvider((widget.club.id, _past)));
    return RefreshIndicator(
      onRefresh: () => ref.refresh(clubEventsProvider((widget.club.id, _past)).future),
      child: ListView(
        key: const Key('club-events'),
        padding: const EdgeInsets.fromLTRB(L360.gutter, 12, L360.gutter, 32),
        children: [
          Row(
            children: [
              PillChip(
                key: const Key('events-upcoming'),
                label: 'Upcoming',
                on: !_past,
                onTap: () => setState(() => _past = false),
              ),
              const SizedBox(width: 6),
              PillChip(
                key: const Key('events-past'),
                label: 'Past',
                on: _past,
                onTap: () => setState(() => _past = true),
              ),
              const Spacer(),
              if (widget.club.canManage)
                Flexible(
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    alignment: Alignment.centerRight,
                    child: FilledButton.icon(
                      key: const Key('event-new'),
                      style: FilledButton.styleFrom(minimumSize: const Size(0, 38)),
                      onPressed: () => openEventForm(context, EventDraft(clubId: widget.club.id)),
                      icon: const Icon(Icons.add, size: 18),
                      label: const Text('New event'),
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 12),
          ...switch (events) {
            AsyncData(:final value) when value.isEmpty => [
              EmptyState(
                icon: Icons.event_outlined,
                title: _past ? 'No past events' : 'No events planned',
                text: widget.club.canManage
                    ? 'Plan an expedition or field day: time, meeting point, route, gear checklist and live tracking.'
                    : 'The club leader and admins plan events here.',
              ),
            ],
            AsyncData(:final value) => [
              for (final e in value) ...[_EventCard(event: e), const SizedBox(height: 8)],
            ],
            AsyncError(:final error) => [ErrorBanner('$error')],
            _ => [const LoadingCards(count: 2)],
          },
        ],
      ),
    );
  }
}

class _EventCard extends StatelessWidget {
  const _EventCard({required this.event});

  final EventSummary event;

  @override
  Widget build(BuildContext context) {
    const small = TextStyle(fontSize: 12, color: L360Colors.sand600);
    return CommunityCard(
      key: Key('event-${event.id}'),
      onTap: () => openEvent(context, event.id),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                EventStateBadge(event.state),
                const Spacer(),
                if (event.myStatus != null)
                  Text(
                    event.myStatus!.label,
                    style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: L360Colors.forest700),
                  ),
              ],
            ),
            const SizedBox(height: 6),
            Text(event.title, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700)),
            const SizedBox(height: 2),
            Text(formatEventRange(event.startsAt, event.endsAt), style: small),
            if (event.meetingName?.isNotEmpty ?? false) Text('Meet at ${event.meetingName}', style: small),
            const SizedBox(height: 6),
            // Wraps on narrow screens and large text
            Wrap(
              spacing: 10,
              runSpacing: 2,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.people_outline, size: 14, color: L360Colors.sand600),
                    const SizedBox(width: 4),
                    Text(event.goingText, key: const Key('event-going'), style: small),
                  ],
                ),
                if (event.pendingCount > 0) Text('${event.pendingCount} waiting', style: small),
                if (event.sharingCount > 0)
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.my_location, size: 14, color: L360Colors.forest700),
                      const SizedBox(width: 4),
                      Text(
                        '${event.sharingCount} sharing live',
                        style: const TextStyle(fontSize: 12, color: L360Colors.forest700, fontWeight: FontWeight.w600),
                      ),
                    ],
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

// --- Event page ----------------------------------------------------------------------------------

Future<void> openEvent(BuildContext context, String eventId) => Navigator.of(
  context,
  rootNavigator: true,
).push(MaterialPageRoute<void>(builder: (_) => EventPage(eventId: eventId)));

class EventPage extends ConsumerStatefulWidget {
  const EventPage({super.key, required this.eventId});

  final String eventId;

  @override
  ConsumerState<EventPage> createState() => _EventPageState();
}

class _EventPageState extends ConsumerState<EventPage> {
  CommunityEvent? _event;
  List<EventParticipant> _people = const [];
  List<ChecklistItem> _checklist = const [];
  List<TrailPoint>? _myTrail; // after the event, when I shared
  bool _loading = true;
  bool _busy = false;
  String? _error;
  Timer? _timer;
  final _newItem = TextEditingController();

  CommunityEventsRepository get _repo => ref.read(communityEventsRepositoryProvider);

  @override
  void initState() {
    super.initState();
    unawaited(_load());
    // Live positions and who is seen change while the page is open
    _timer = Timer.periodic(liveRefreshEvery, (_) {
      if (_event?.state == EventState.running) unawaited(_load());
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    _newItem.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final e = await _repo.event(widget.eventId);
      if (e == null) {
        if (mounted) {
          setState(() {
            _event = null;
            _loading = false;
          });
        }
        return;
      }
      final people = await _repo.participants(e.id);
      final checklist = await _repo.checklist(e.id);
      List<TrailPoint>? trail;
      if (e.state == EventState.ended && _myTrail == null) {
        final me = (await _repo.liveLatest(e.id)).where((p) => p.isMe).firstOrNull;
        if (me != null) trail = await _repo.liveTrail(e.id, me.userId);
      }
      if (!mounted) return;
      setState(() {
        _event = e;
        _people = people;
        _checklist = checklist;
        _myTrail = trail ?? _myTrail;
        _loading = false;
        _error = null;
      });
    } on Object catch (err) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = '$err';
        });
      }
    }
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

  void _changed() => ref.invalidate(clubEventsProvider);

  Future<void> _join() async {
    final e = _event!;
    final contact = await showEmergencySheet(context, name: e.myEmergencyName ?? '', phone: e.myEmergencyPhone ?? '');
    if (contact == null) return;
    await _run(() async {
      final status = await _repo.join(e.id, emergencyName: contact.$1, emergencyPhone: contact.$2);
      _changed();
      await _load();
      if (mounted && e.myStatus == null) {
        showSnack(context, status == ParticipantStatus.pending ? 'Waiting for approval.' : 'You are going.');
      }
    });
  }

  Future<void> _leave() async {
    if (!await confirmDialog(
      context,
      title: 'Leave this event?',
      message: 'Your place and your emergency contact are removed; sharing stops.',
      action: 'Leave',
    )) {
      return;
    }
    await _run(() async {
      if (ref.read(communityLiveProvider).eventId == widget.eventId) {
        await ref.read(communityLiveProvider.notifier).stop();
      }
      await _repo.leave(widget.eventId);
      _changed();
      await _load();
    });
  }

  Future<void> _share(CommunityEvent e) async {
    final live = ref.read(communityLiveProvider);
    if (live.on && live.eventId != e.id) {
      if (!await confirmDialog(
        context,
        title: 'Share for this event instead?',
        message: 'You are sharing your position for ${live.title}. Only one event can share at a time.',
        action: 'Switch',
        destructive: false,
      )) {
        return;
      }
    }
    final problem = await ref.read(communityLiveProvider.notifier).start(e);
    if (problem != null && mounted) showSnack(context, problem);
    await _load();
  }

  Future<void> _stopSharing() async {
    await ref.read(communityLiveProvider.notifier).stop();
    await _load();
  }

  void _liveMap(CommunityEvent e) {
    unawaited(ref.read(communityLiveViewProvider.notifier).open(e.id, e.title));
    if (e.hasMeetingPoint) ref.read(flyToProvider.notifier).go(e.meetingLng!, e.meetingLat!, zoom: 13);
    Navigator.of(context).popUntil((r) => r.isFirst);
  }

  /// The meeting point and the planned route on the map
  Future<void> _showOnMap(CommunityEvent e) => _run(() async {
    final route = e.routeItemId == null
        ? null
        : await ref.read(communityRepositoryProvider).clubItemData(e.routeItemId!);
    ref
        .read(communityFocusProvider.notifier)
        .showFocus(
          MapFocus(title: e.title, attachment: route, point: e.hasMeetingPoint ? (e.meetingLng!, e.meetingLat!) : null),
        );
    if (mounted) Navigator.of(context).popUntil((r) => r.isFirst);
  });

  Future<void> _decide(EventParticipant p, bool going) => _run(() async {
    await _repo.decide(widget.eventId, p.userId, going: going);
    _changed();
    await _load();
  });

  Future<void> _toggle(ChecklistItem i) => _run(() async {
    final on = await _repo.toggleCheck(i.id);
    setState(() => _checklist = [for (final x in _checklist) x.id == i.id ? x.toggled(on) : x]);
  });

  Future<void> _addItem() async {
    final label = _newItem.text.trim();
    if (label.isEmpty) return;
    await _run(() async {
      await _repo.addChecklistItem(widget.eventId, label);
      _newItem.clear();
      if (mounted) FocusScope.of(context).unfocus();
      await _load();
    });
  }

  Future<void> _deleteItem(ChecklistItem i) => _run(() async {
    await _repo.deleteChecklistItem(i.id);
    await _load();
  });

  Future<void> _cancel() async {
    if (!await confirmDialog(
      context,
      title: 'Cancel this event?',
      message: 'It stays in the list as cancelled; live sharing stops.',
      action: 'Cancel event',
    )) {
      return;
    }
    await _run(() async {
      await _repo.cancel(widget.eventId);
      _changed();
      await _load();
    });
  }

  Future<void> _delete() async {
    if (!await confirmDialog(
      context,
      title: 'Delete this event?',
      message: 'The event, its participants, checklist and positions are deleted for good.',
      action: 'Delete',
    )) {
      return;
    }
    await _run(() async {
      await _repo.delete(widget.eventId);
      _changed();
      if (mounted) Navigator.pop(context);
    });
  }

  Future<void> _edit(CommunityEvent e) async {
    await openEventForm(
      context,
      EventDraft(
        clubId: e.clubId,
        eventId: e.id,
        title: e.title,
        description: e.description ?? '',
        startsAt: e.startsAt.toLocal(),
        endsAt: e.endsAt.toLocal(),
        meetingName: e.meetingName ?? '',
        meetingLat: e.meetingLat,
        meetingLng: e.meetingLng,
        routeItemId: e.routeItemId,
        quota: e.quota?.toString() ?? '',
        needsApproval: e.needsApproval,
      ),
    );
    await _load();
  }

  Future<void> _saveTrack(CommunityEvent e, List<TrailPoint> trail, TrackStats stats) => _run(() async {
    final data = trackAttachment(
      name: e.title,
      distanceM: stats.distanceM,
      points: [for (final p in trail) (p.lng, p.lat)],
      maxPoints: workspaceTrackPoints,
    );
    await ref
        .read(communityRepositoryProvider)
        .addClubItem(e.clubId, null, data, note: formatEventRange(e.startsAt, e.endsAt));
    ref.invalidate(clubItemsProvider(e.clubId));
    if (mounted) showSnack(context, 'Your track was saved to the club workspace.');
  });

  void _story(CommunityEvent e) {
    final trail = _myTrail ?? const <TrailPoint>[];
    final at = trail.isNotEmpty
        ? (trail.last.lng, trail.last.lat)
        : e.hasMeetingPoint
        ? (e.meetingLng!, e.meetingLat!)
        : null;
    unawaited(
      openCompose(
        context,
        draft: ComposeDraft(
          kind: PostKind.story,
          title: e.title,
          happenedOn: dateOnly(e.startsAt.toLocal()),
          lat: at?.$2,
          lng: at?.$1,
          placeName: e.meetingName ?? '',
          placeEdited: e.meetingName?.isNotEmpty ?? false,
          clubId: e.clubId,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final e = _event;
    final now = ref.watch(communityClockProvider)();
    final live = ref.watch(communityLiveProvider);
    return Scaffold(
      appBar: AppBar(
        title: Text(e?.title ?? 'Event'),
        actions: [
          if (e != null && e.canManage)
            PopupMenuButton<String>(
              key: const Key('event-menu'),
              onSelected: (v) => switch (v) {
                'edit' => _edit(e),
                'cancel' => _cancel(),
                _ => _delete(),
              },
              itemBuilder: (_) => [
                if (e.state != EventState.cancelled) const PopupMenuItem(value: 'edit', child: Text('Edit')),
                if (e.state == EventState.planned || e.state == EventState.running)
                  const PopupMenuItem(value: 'cancel', child: Text('Cancel event')),
                const PopupMenuItem(value: 'delete', child: Text('Delete')),
              ],
            ),
        ],
      ),
      body: e == null
          ? Center(
              child: _loading
                  ? const CircularProgressIndicator()
                  : Padding(
                      padding: const EdgeInsets.all(24),
                      child: Text(_error ?? 'This event is no longer available.', textAlign: TextAlign.center),
                    ),
            )
          : RefreshIndicator(
              onRefresh: _load,
              child: ListView(
                key: const Key('event-page'),
                padding: const EdgeInsets.fromLTRB(L360.gutter, 12, L360.gutter, 32),
                children: [
                  if (_busy) const LinearProgressIndicator(minHeight: 2),
                  if (_error != null) ...[ErrorBanner(_error!), const SizedBox(height: 8)],
                  ..._about(e),
                  const SizedBox(height: 12),
                  ..._myPart(e, live),
                  if (e.state == EventState.ended && (_myTrail?.length ?? 0) >= 2) ...[
                    const SizedBox(height: 16),
                    ..._summary(e, _myTrail!),
                  ],
                  const SizedBox(height: 16),
                  ..._participants(e, now),
                  const SizedBox(height: 16),
                  ..._checklistView(e),
                ],
              ),
            ),
    );
  }

  List<Widget> _about(CommunityEvent e) {
    const small = TextStyle(fontSize: 13, color: L360Colors.sand700);
    return [
      Row(
        children: [
          EventStateBadge(e.state),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              e.clubName,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 12, color: L360Colors.sand600),
            ),
          ),
        ],
      ),
      const SizedBox(height: 8),
      Text(e.title, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w700)),
      const SizedBox(height: 4),
      Row(
        children: [
          const Icon(Icons.schedule, size: 16, color: L360Colors.sand600),
          const SizedBox(width: 6),
          Expanded(
            child: Text(formatEventRange(e.startsAt, e.endsAt), key: const Key('event-range'), style: small),
          ),
        ],
      ),
      if ((e.meetingName?.isNotEmpty ?? false) || e.hasMeetingPoint)
        Row(
          children: [
            const Icon(Icons.place_outlined, size: 16, color: L360Colors.sand600),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                'Meet at ${e.meetingName?.isNotEmpty ?? false ? e.meetingName : 'the marked point'}',
                style: small,
              ),
            ),
          ],
        ),
      if (e.routeName != null)
        Row(
          children: [
            const Icon(Icons.timeline, size: 16, color: L360Colors.sand600),
            const SizedBox(width: 6),
            Expanded(child: Text('Route: ${e.routeName}', style: small)),
          ],
        ),
      Row(
        children: [
          const Icon(Icons.people_outline, size: 16, color: L360Colors.sand600),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              [
                e.goingText,
                if (e.pendingCount > 0) '${e.pendingCount} waiting',
                if (e.needsApproval) 'organisers approve',
              ].join(' · '),
              style: small,
            ),
          ),
        ],
      ),
      if (e.description?.isNotEmpty ?? false) ...[
        const SizedBox(height: 10),
        Text(e.description!, style: const TextStyle(fontSize: 14, height: 1.45)),
      ],
      const SizedBox(height: 10),
      Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          if (e.hasMeetingPoint || e.routeItemId != null)
            OutlinedButton.icon(
              key: const Key('event-show-on-map'),
              onPressed: _busy ? null : () => _showOnMap(e),
              icon: const Icon(Icons.map_outlined, size: 18),
              label: const Text('Show on map'),
            ),
          if (e.hasLiveMap)
            OutlinedButton.icon(
              key: const Key('event-live-map'),
              onPressed: () => _liveMap(e),
              icon: const Icon(Icons.share_location, size: 18),
              label: const Text('Live map'),
            ),
        ],
      ),
    ];
  }

  List<Widget> _myPart(CommunityEvent e, LiveShareState live) {
    final sharingHere = live.eventId == e.id;
    return [
      if (e.myStatus == ParticipantStatus.pending)
        Container(
          key: const Key('event-pending'),
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(color: L360Colors.gold50, borderRadius: BorderRadius.circular(L360.radiusSmall)),
          child: const Row(
            children: [
              Icon(Icons.hourglass_top, size: 18, color: L360Colors.gold700),
              SizedBox(width: 8),
              Expanded(
                child: Text(
                  'Waiting for approval',
                  style: TextStyle(fontWeight: FontWeight.w700, color: L360Colors.gold700),
                ),
              ),
            ],
          ),
        ),
      if (e.myStatus == ParticipantStatus.declined)
        const ErrorBanner('The organisers declined your request for this event.'),
      if (e.myStatus == ParticipantStatus.going)
        const Row(
          children: [
            Icon(Icons.check_circle, size: 18, color: L360Colors.forest700),
            SizedBox(width: 6),
            Text(
              "You're going",
              style: TextStyle(fontWeight: FontWeight.w700, color: L360Colors.forest700),
            ),
          ],
        ),
      const SizedBox(height: 8),
      Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          if (e.canJoin)
            FilledButton.icon(
              key: const Key('event-join'),
              style: FilledButton.styleFrom(minimumSize: const Size(0, 44)),
              onPressed: _busy ? null : _join,
              icon: const Icon(Icons.how_to_reg_outlined, size: 18),
              label: Text(e.needsApproval ? 'Ask to join' : 'Join'),
            ),
          if (e.myStatus == ParticipantStatus.going || e.myStatus == ParticipantStatus.pending) ...[
            if (e.state != EventState.ended && e.state != EventState.cancelled)
              OutlinedButton.icon(
                key: const Key('event-contact'),
                onPressed: _busy ? null : _join,
                icon: const Icon(Icons.contact_emergency_outlined, size: 18),
                label: Text(
                  e.myEmergencyName?.isNotEmpty ?? false
                      ? 'Emergency contact: ${e.myEmergencyName}'
                      : 'Add emergency contact',
                ),
              ),
            if (e.state != EventState.ended)
              TextButton(
                key: const Key('event-leave'),
                style: TextButton.styleFrom(foregroundColor: L360Colors.brick500),
                onPressed: _busy ? null : _leave,
                child: const Text('Leave'),
              ),
          ],
        ],
      ),
      // Never offered for an ended or cancelled event, whatever the row says
      if ((e.canShare && e.state != EventState.ended && e.state != EventState.cancelled) || sharingHere) ...[
        const SizedBox(height: 12),
        Container(
          key: const Key('event-live'),
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: sharingHere ? L360Colors.forest50 : L360Colors.sand50,
            borderRadius: BorderRadius.circular(L360.radiusSmall),
            border: Border.all(color: sharingHere ? L360Colors.forest200 : L360Colors.sand200),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                sharingHere
                    ? 'Sharing your position with ${e.clubName} until ${formatUntil(e.endsAt, ref.read(communityClockProvider)())}'
                    : 'Share your position with the club while the event runs. Only club members see it; it stops by '
                          'itself at the end. Works with the screen off.',
                style: const TextStyle(fontSize: 13, height: 1.4),
              ),
              if (sharingHere && live.pending > 0)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(
                    '${live.pending} position${live.pending == 1 ? '' : 's'} waiting for signal',
                    style: const TextStyle(fontSize: 12, color: L360Colors.sand600),
                  ),
                ),
              if (sharingHere && live.gpsError != null)
                Text(live.gpsError!, style: const TextStyle(fontSize: 12, color: L360Colors.brick500)),
              const SizedBox(height: 8),
              if (sharingHere)
                OutlinedButton.icon(
                  key: const Key('event-share-stop'),
                  style: OutlinedButton.styleFrom(foregroundColor: L360Colors.brick500),
                  onPressed: _stopSharing,
                  icon: const Icon(Icons.location_disabled, size: 18),
                  label: const Text('Stop sharing'),
                )
              else
                FilledButton.icon(
                  key: const Key('event-share'),
                  style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(44)),
                  onPressed: () => _share(e),
                  icon: const Icon(Icons.share_location, size: 18),
                  label: const Text('Share my position'),
                ),
            ],
          ),
        ),
      ],
    ];
  }

  List<Widget> _summary(CommunityEvent e, List<TrailPoint> trail) {
    final stats = trailSummary(trail);
    Widget tile(String value, String label) => Expanded(
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: L360Colors.sand200),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(value, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
            Text(label, style: const TextStyle(fontSize: 11, color: L360Colors.sand500)),
          ],
        ),
      ),
    );
    return [
      const Text('My summary', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
      const SizedBox(height: 6),
      Row(
        key: const Key('event-summary'),
        children: [
          tile(formatLength(stats.distanceM), 'distance'),
          const SizedBox(width: 6),
          tile(formatDuration(stats.movingTimeMs), 'moving'),
          const SizedBox(width: 6),
          tile('${stats.elevationGainM.round()} m', 'climbed'),
        ],
      ),
      const SizedBox(height: 8),
      Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          OutlinedButton.icon(
            key: const Key('event-save-track'),
            onPressed: _busy ? null : () => _saveTrack(e, trail, stats),
            icon: const Icon(Icons.save_alt, size: 18),
            label: const Text('Save my track to the workspace'),
          ),
          OutlinedButton.icon(
            key: const Key('event-story'),
            onPressed: () => _story(e),
            icon: const Icon(Icons.auto_stories_outlined, size: 18),
            label: const Text('Write a story'),
          ),
        ],
      ),
    ];
  }

  List<Widget> _participants(CommunityEvent e, DateTime now) {
    final going = _people.where((p) => p.status == ParticipantStatus.going).length;
    return [
      Text('Participants ($going)', style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
      if (_people.isEmpty)
        const Padding(
          padding: EdgeInsets.symmetric(vertical: 8),
          child: Text('No one has joined yet.', style: TextStyle(fontSize: 13, color: L360Colors.sand500)),
        ),
      for (final p in _people)
        ListTile(
          key: Key('participant-${p.userId}'),
          contentPadding: EdgeInsets.zero,
          leading: InitialAvatar(p.name, size: 32),
          title: Row(
            children: [
              Flexible(child: Text(p.isMe ? '${p.name} (you)' : p.name, overflow: TextOverflow.ellipsis)),
              if (p.sharing) ...[
                const SizedBox(width: 6),
                const Icon(Icons.my_location, size: 14, color: L360Colors.forest700),
              ],
            ],
          ),
          subtitle: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                [
                  if (p.status != ParticipantStatus.going) p.status.label,
                  if (_checklist.isNotEmpty) '${p.checkedCount}/${_checklist.length} ticked',
                  ?p.organization,
                ].join(' · '),
              ),
              if (e.canManage && (p.emergencyPhone?.isNotEmpty ?? false))
                InkWell(
                  key: Key('emergency-${p.userId}'),
                  onTap: () => launchUrl(Uri(scheme: 'tel', path: p.emergencyPhone!.replaceAll(RegExp(r'[^\d+]'), ''))),
                  child: Text(
                    'Emergency: ${[?p.emergencyName, p.emergencyPhone!].join(', ')}',
                    style: const TextStyle(color: L360Colors.forest700, decoration: TextDecoration.underline),
                  ),
                ),
              if (e.canManage && p.notSeenFor(now))
                Text(
                  'Not seen for over 60 min',
                  key: Key('stale-${p.userId}'),
                  style: const TextStyle(color: L360Colors.brick600, fontWeight: FontWeight.w700),
                ),
            ],
          ),
          trailing: e.canManage && p.status == ParticipantStatus.pending
              ? Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    IconButton(
                      key: Key('approve-${p.userId}'),
                      tooltip: 'Approve',
                      color: L360Colors.forest700,
                      icon: const Icon(Icons.check_circle_outline),
                      onPressed: _busy ? null : () => _decide(p, true),
                    ),
                    IconButton(
                      key: Key('decline-${p.userId}'),
                      tooltip: 'Decline',
                      color: L360Colors.brick500,
                      icon: const Icon(Icons.cancel_outlined),
                      onPressed: _busy ? null : () => _decide(p, false),
                    ),
                  ],
                )
              : null,
        ),
    ];
  }

  List<Widget> _checklistView(CommunityEvent e) {
    final mine = e.myStatus == ParticipantStatus.going || e.myStatus == ParticipantStatus.pending;
    if (_checklist.isEmpty && !e.canManage) return const [];
    final total = _people.where((p) => p.status == ParticipantStatus.going).length;
    return [
      const Text('Checklist', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
      for (final i in _checklist)
        CheckboxListTile(
          key: Key('check-${i.id}'),
          contentPadding: EdgeInsets.zero,
          dense: true,
          controlAffinity: ListTileControlAffinity.leading,
          value: i.checked,
          onChanged: mine && !_busy ? (_) => _toggle(i) : null,
          title: Text(i.label),
          subtitle: Text('${i.checkedCount}/$total ticked'),
          secondary: e.canManage
              ? IconButton(
                  tooltip: 'Delete item',
                  icon: const Icon(Icons.delete_outline, size: 20),
                  onPressed: _busy ? null : () => _deleteItem(i),
                )
              : null,
        ),
      if (e.canManage)
        Row(
          children: [
            Expanded(
              child: TextField(
                key: const Key('checklist-new'),
                controller: _newItem,
                maxLength: checklistLabelMax,
                decoration: const InputDecoration(hintText: 'Add an item (headlamp, raincoat…)', counterText: ''),
                onSubmitted: (_) => _addItem(),
              ),
            ),
            IconButton(
              key: const Key('checklist-add'),
              tooltip: 'Add',
              icon: const Icon(Icons.add),
              onPressed: _addItem,
            ),
          ],
        ),
    ];
  }
}

/// Name and phone of someone to call in an emergency; (name, phone), or null when cancelled
Future<(String, String)?> showEmergencySheet(BuildContext context, {String name = '', String phone = ''}) =>
    showModalBottomSheet<(String, String)>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (_) => _EmergencySheet(name: name, phone: phone),
    );

class _EmergencySheet extends StatefulWidget {
  const _EmergencySheet({required this.name, required this.phone});

  final String name;
  final String phone;

  @override
  State<_EmergencySheet> createState() => _EmergencySheetState();
}

class _EmergencySheetState extends State<_EmergencySheet> {
  late final _name = TextEditingController(text: widget.name);
  late final _phone = TextEditingController(text: widget.phone);

  @override
  void dispose() {
    _name.dispose();
    _phone.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Padding(
    key: const Key('emergency-sheet'),
    padding: EdgeInsets.fromLTRB(L360.gutter, 4, L360.gutter, 16 + MediaQuery.viewInsetsOf(context).bottom),
    child: SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text('Emergency contact', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
          const SizedBox(height: 4),
          const Text(
            'Optional. Only the organisers see it, to call someone if something happens to you.',
            style: TextStyle(fontSize: 12, color: L360Colors.sand600),
          ),
          const SizedBox(height: 10),
          TextField(
            key: const Key('emergency-name'),
            controller: _name,
            maxLength: emergencyNameMax,
            textCapitalization: TextCapitalization.words,
            decoration: const InputDecoration(labelText: 'Name'),
          ),
          TextField(
            key: const Key('emergency-phone'),
            controller: _phone,
            maxLength: emergencyPhoneMax,
            keyboardType: TextInputType.phone,
            decoration: const InputDecoration(labelText: 'Phone'),
          ),
          const SizedBox(height: 8),
          FilledButton(
            key: const Key('emergency-save'),
            onPressed: () => Navigator.pop(context, (_name.text, _phone.text)),
            child: const Text('Continue'),
          ),
        ],
      ),
    ),
  );
}

// --- Event form ----------------------------------------------------------------------------------

Future<void> openEventForm(BuildContext context, EventDraft draft) => Navigator.of(
  context,
  rootNavigator: true,
).push(MaterialPageRoute<void>(fullscreenDialog: true, builder: (_) => EventFormPage(draft: draft)));

class EventFormPage extends ConsumerStatefulWidget {
  const EventFormPage({super.key, required this.draft});

  final EventDraft draft;

  @override
  ConsumerState<EventFormPage> createState() => _EventFormPageState();
}

class _EventFormPageState extends ConsumerState<EventFormPage> {
  late final _title = TextEditingController(text: widget.draft.title);
  late final _description = TextEditingController(text: widget.draft.description);
  late final _meeting = TextEditingController(text: widget.draft.meetingName);
  late final _quota = TextEditingController(text: widget.draft.quota);
  late DateTime? _start = widget.draft.startsAt;
  late DateTime? _end = widget.draft.endsAt;
  late double? _lat = widget.draft.meetingLat;
  late double? _lng = widget.draft.meetingLng;
  late String? _route = widget.draft.routeItemId;
  late bool _approval = widget.draft.needsApproval;
  bool _saving = false;
  bool _locating = false;
  String? _error;

  bool get _editing => widget.draft.eventId != null;

  @override
  void dispose() {
    for (final c in [_title, _description, _meeting, _quota]) {
      c.dispose();
    }
    super.dispose();
  }

  EventDraft get _draft => EventDraft(
    clubId: widget.draft.clubId,
    eventId: widget.draft.eventId,
    title: _title.text,
    description: _description.text,
    startsAt: _start,
    endsAt: _end,
    meetingName: _meeting.text,
    meetingLat: _lat,
    meetingLng: _lng,
    routeItemId: _route,
    quota: _quota.text,
    needsApproval: _approval,
  );

  Future<DateTime?> _pick(DateTime? initial) async {
    final now = ref.read(communityClockProvider)();
    final base = initial ?? DateTime(now.year, now.month, now.day, 6);
    final day = await showDatePicker(
      context: context,
      initialDate: base,
      firstDate: DateTime(now.year - 1),
      lastDate: DateTime(now.year + 2),
    );
    if (day == null || !mounted) return null;
    final time = await showTimePicker(context: context, initialTime: TimeOfDay.fromDateTime(base));
    if (time == null) return null;
    return DateTime(day.year, day.month, day.day, time.hour, time.minute);
  }

  Future<void> _myPosition() async {
    setState(() {
      _locating = true;
      _error = null;
    });
    try {
      final p = await ref.read(communityGpsProvider)(ask: true);
      if (p != null && mounted) {
        setState(() {
          _lng = double.parse(p.$1.toStringAsFixed(6));
          _lat = double.parse(p.$2.toStringAsFixed(6));
        });
      }
    } on Object catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _locating = false);
    }
  }

  void _pickOnMap() {
    ref.read(communityPickProvider.notifier).startEvent(_draft);
    Navigator.of(context).popUntil((r) => r.isFirst);
  }

  Future<void> _save() async {
    final quota = _quota.text.trim().isEmpty ? null : int.tryParse(_quota.text.trim());
    final problem = _quota.text.trim().isNotEmpty && quota == null
        ? 'The quota is a number of people.'
        : eventInputError(
            title: _title.text,
            description: _description.text,
            startsAt: _start,
            endsAt: _end,
            quota: quota,
            editing: _editing,
            now: ref.read(communityClockProvider)(),
          );
    if (problem != null) {
      setState(() => _error = problem);
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final id = await ref
          .read(communityEventsRepositoryProvider)
          .save(
            widget.draft.clubId,
            widget.draft.eventId,
            EventInput(
              title: _title.text,
              description: _description.text,
              startsAt: _start!,
              endsAt: _end!,
              meetingName: _meeting.text,
              meetingLat: _lat,
              meetingLng: _lng,
              routeItemId: _route,
              quota: quota,
              needsApproval: _approval,
            ),
          );
      ref.invalidate(clubEventsProvider);
      if (!mounted) return;
      if (_editing) {
        Navigator.pop(context);
      } else {
        await Navigator.of(context).pushReplacement(MaterialPageRoute<void>(builder: (_) => EventPage(eventId: id)));
      }
    } on Object catch (e) {
      if (mounted) {
        setState(() {
          _saving = false;
          _error = '$e';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final routes = [
      for (final i in ref.watch(clubItemsProvider(widget.draft.clubId)).value ?? const <ClubItem>[])
        if (i.kind == 'track' || i.kind == 'area') i,
    ];
    const label = TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: L360Colors.sand600);
    String when(DateTime? d) => d == null
        ? 'Choose'
        : '${formatDay(d)} ${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';
    return Scaffold(
      appBar: AppBar(
        title: Text(_editing ? 'Edit event' : 'New event'),
        leading: IconButton(tooltip: 'Cancel', icon: const Icon(Icons.close), onPressed: () => Navigator.pop(context)),
      ),
      body: ListView(
        key: const Key('event-form'),
        padding: const EdgeInsets.fromLTRB(L360.gutter, 8, L360.gutter, 32),
        children: [
          TextField(
            key: const Key('event-title'),
            controller: _title,
            maxLength: eventTitleMax,
            textCapitalization: TextCapitalization.sentences,
            decoration: const InputDecoration(labelText: 'Title *', hintText: 'e.g. Gede–Pangrango traverse'),
          ),
          TextField(
            key: const Key('event-description'),
            controller: _description,
            maxLength: eventDescriptionMax,
            minLines: 2,
            maxLines: 6,
            textCapitalization: TextCapitalization.sentences,
            decoration: const InputDecoration(labelText: 'Description', alignLabelWithHint: true),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('Starts *', style: label),
                    OutlinedButton(
                      key: const Key('event-start'),
                      onPressed: () async {
                        final d = await _pick(_start);
                        if (d != null) {
                          setState(() {
                            _start = d;
                            if (_end == null || !_end!.isAfter(d)) _end = d.add(const Duration(hours: 8));
                          });
                        }
                      },
                      child: Text(when(_start)),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('Ends *', style: label),
                    OutlinedButton(
                      key: const Key('event-end'),
                      onPressed: () async {
                        final d = await _pick(_end ?? _start);
                        if (d != null) setState(() => _end = d);
                      },
                      child: Text(when(_end)),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          const Text('Meeting point', style: label),
          const SizedBox(height: 6),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              FilledButton.tonalIcon(
                key: const Key('event-pick'),
                onPressed: _pickOnMap,
                icon: const Icon(Icons.my_location, size: 18),
                label: const Text('Pick on map'),
              ),
              OutlinedButton.icon(
                key: const Key('event-gps'),
                onPressed: _locating ? null : _myPosition,
                icon: const Icon(Icons.gps_fixed, size: 18),
                label: const Text('My position'),
              ),
              if (_lat != null)
                TextButton(onPressed: () => setState(() => _lat = _lng = null), child: const Text('Clear')),
            ],
          ),
          if (_lat != null)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                '${_lat!.toStringAsFixed(5)}, ${_lng!.toStringAsFixed(5)}',
                key: const Key('event-point'),
                style: const TextStyle(fontSize: 12, color: L360Colors.sand700),
              ),
            ),
          TextField(
            key: const Key('event-meeting'),
            controller: _meeting,
            maxLength: eventMeetingNameMax,
            decoration: const InputDecoration(labelText: 'Meeting point name', hintText: 'e.g. Basecamp Cibodas'),
          ),
          const SizedBox(height: 8),
          DropdownButtonFormField<String?>(
            key: const Key('event-route'),
            isExpanded: true,
            initialValue: routes.any((r) => r.id == _route) ? _route : null,
            decoration: const InputDecoration(labelText: 'Route (from the workspace)'),
            items: [
              const DropdownMenuItem<String?>(value: null, child: Text('None')),
              for (final r in routes)
                DropdownMenuItem<String?>(
                  value: r.id,
                  child: Text('${r.kind == 'track' ? 'Track' : 'Area'}: ${r.name}'),
                ),
            ],
            onChanged: (v) => setState(() => _route = v),
          ),
          const SizedBox(height: 8),
          TextField(
            key: const Key('event-quota'),
            controller: _quota,
            keyboardType: TextInputType.number,
            decoration: const InputDecoration(labelText: 'Quota (people)', hintText: 'No limit'),
          ),
          SwitchListTile.adaptive(
            key: const Key('event-approval'),
            contentPadding: EdgeInsets.zero,
            title: const Text('Needs approval'),
            subtitle: const Text('The leader or an admin lets each person in'),
            value: _approval,
            onChanged: (v) => setState(() => _approval = v),
          ),
          if (_error != null) ...[const SizedBox(height: 8), ErrorBanner(_error!)],
          const SizedBox(height: 12),
          FilledButton(
            key: const Key('event-save'),
            onPressed: _saving ? null : _save,
            child: Text(_editing ? 'Save changes' : 'Create event'),
          ),
        ],
      ),
    );
  }
}
