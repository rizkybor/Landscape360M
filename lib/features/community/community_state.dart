import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:geolocator/geolocator.dart' as geo;
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/providers.dart';
import '../../data/community/community_outbox.dart';
import '../../data/community/community_repository.dart';
import '../../data/community/photo_compress.dart';
import '../../domain/community/community.dart';
import '../../domain/community/community_attachments.dart';
import '../../domain/geo/spherical.dart';
import '../../domain/sos/sos_outbox.dart' show OutboxStorage;
import '../map/map_tools_state.dart';
import '../tracks/track_recorder_state.dart' show onlineProvider;

// Community (COMMUNITY_PRD.md): the feed with its filters and the copy kept for reading
// offline, the map layer of recent posts, the post shown on the map with its attachment,
// picking a post's location on the map, and the outbox of trail reports written offline.

final communityBackendProvider = Provider<CommunityBackend>(
  (ref) => SupabaseCommunityBackend(ref.watch(supabaseClientProvider)),
);

final communityPrefsProvider = Provider<SharedPreferencesAsync>((ref) => SharedPreferencesAsync());

/// Key-value storage in the app's preferences (feed cache, outbox, live sharing)
class PrefsOutboxStorage implements OutboxStorage {
  PrefsOutboxStorage(this.prefs);
  final SharedPreferencesAsync prefs;

  @override
  Future<String?> read(String key) => prefs.getString(key);

  @override
  Future<void> write(String key, String value) => prefs.setString(key, value);
}

final communityRepositoryProvider = Provider<CommunityRepository>(
  (ref) => CommunityRepository(
    backend: ref.watch(communityBackendProvider),
    cache: PrefsOutboxStorage(ref.watch(communityPrefsProvider)),
  ),
);

final communityOutboxFilesProvider = Provider<OutboxFiles>((ref) => DiskOutboxFiles());

final communityOutboxStoreProvider = Provider<CommunityOutbox>(
  (ref) => CommunityOutbox(
    storage: PrefsOutboxStorage(ref.watch(communityPrefsProvider)),
    files: ref.watch(communityOutboxFilesProvider),
    repository: () => ref.read(communityRepositoryProvider),
  ),
);

/// The time, for "old" reports and the 24 hours of editing (tests set it)
final communityClockProvider = Provider<DateTime Function()>((ref) => DateTime.now);

/// Public address of a photo
final communityPhotoUrlProvider = Provider<String Function(String path)>((ref) {
  final url = ref.watch(appConfigProvider).supabaseUrl;
  return (path) => photoUrl(url, path);
});

/// The phone's position (lng, lat): [ask] asks for permission and waits for a fix; without
/// it, only the last known position when location is already allowed. Null when unknown.
typedef CommunityGps = Future<LngLat?> Function({required bool ask});

final communityGpsProvider = Provider<CommunityGps>(
  (ref) => ({required bool ask}) async {
    try {
      var permission = await geo.Geolocator.checkPermission();
      if (permission == geo.LocationPermission.denied && ask) {
        permission = await geo.Geolocator.requestPermission();
      }
      if (permission != geo.LocationPermission.whileInUse && permission != geo.LocationPermission.always) {
        if (ask) throw const CommunityException('Location is off for Landscape 360. Allow it in Settings.');
        return null;
      }
      final p = ask
          ? await geo.Geolocator.getCurrentPosition(
              locationSettings: const geo.LocationSettings(
                accuracy: geo.LocationAccuracy.high,
                timeLimit: Duration(seconds: 15),
              ),
            )
          : await geo.Geolocator.getLastKnownPosition();
      return p == null ? null : (p.longitude, p.latitude);
    } on CommunityException {
      rethrow;
    } on Object {
      if (ask) throw const CommunityException('Could not get your location. Try again under open sky.');
      return null;
    }
  },
);

/// What a signed-in account may do today; null when signed out
final communityLimitsProvider = FutureProvider<CommunityLimits?>((ref) async {
  final userId = ref.watch(authUserIdProvider).value;
  if (userId == null) return null;
  return ref.watch(communityRepositoryProvider).limits();
});

// --- Clubs -------------------------------------------------------------------------------------

/// My clubs, owned first; empty when signed out
final myClubsProvider = FutureProvider<List<CommunityClub>>((ref) async {
  final userId = ref.watch(authUserIdProvider).value;
  if (userId == null) return const [];
  return ref.watch(communityRepositoryProvider).myClubs();
});

/// Members of a club (for its members)
final clubMembersProvider = FutureProvider.family<List<ClubMember>, String>(
  (ref, clubId) => ref.watch(communityRepositoryProvider).clubMembers(clubId),
);

// --- Feed ----------------------------------------------------------------------------------------

class CommunityFeedState {
  const CommunityFeedState({
    this.filter = const FeedFilter(),
    this.posts = const [],
    this.loading = false,
    this.loadingMore = false,
    this.hasMore = false,
    this.error,
    this.savedAt,
  });

  final FeedFilter filter;
  final List<CommunityPost> posts;
  final bool loading;
  final bool loadingMore;
  final bool hasMore;
  final String? error;

  /// Set while the copy kept on the phone is shown (no connection)
  final DateTime? savedAt;

  bool get offline => savedAt != null;

  CommunityFeedState copyWith({
    FeedFilter? filter,
    List<CommunityPost>? posts,
    bool? loading,
    bool? loadingMore,
    bool? hasMore,
    String? Function()? error,
    DateTime? Function()? savedAt,
  }) => CommunityFeedState(
    filter: filter ?? this.filter,
    posts: posts ?? this.posts,
    loading: loading ?? this.loading,
    loadingMore: loadingMore ?? this.loadingMore,
    hasMore: hasMore ?? this.hasMore,
    error: error == null ? this.error : error(),
    savedAt: savedAt == null ? this.savedAt : savedAt(),
  );
}

final communityFeedProvider = NotifierProvider<CommunityFeedController, CommunityFeedState>(
  CommunityFeedController.new,
);

class CommunityFeedController extends Notifier<CommunityFeedState> {
  int _request = 0;

  @override
  CommunityFeedState build() => const CommunityFeedState();

  CommunityRepository get _repo => ref.read(communityRepositoryProvider);

  /// The map's view for "Near the map" (around the centre until the map has settled once)
  Bounds _view() {
    final b = ref.read(mapBoundsProvider);
    if (b != null) return b;
    final c = ref.read(mapCenterProvider);
    return (c.lng - 0.1, c.lat - 0.1, c.lng + 0.1, c.lat + 0.1);
  }

  Future<List<CommunityPost>> _page(DateTime? before) {
    final f = state.filter;
    return _repo.feed(
      bounds: f.scope == FeedScope.nearMap ? _view() : null,
      kinds: f.kinds,
      conditions: f.conditions,
      before: before,
      clubId: f.clubId,
    );
  }

  /// The first page again (the filter or the map changed, pulled to refresh)
  Future<void> load() async {
    final id = ++_request;
    state = state.copyWith(loading: true, error: () => null);
    try {
      final posts = await _page(null);
      if (id != _request) return;
      state = state.copyWith(posts: posts, hasMore: posts.length >= feedPageSize, loading: false, savedAt: () => null);
      unawaited(_repo.saveFeed(posts, userId: ref.read(authUserIdProvider).value));
      // A club's feed seen: its "new posts" badge starts again
      final club = state.filter.clubId;
      if (club != null) {
        unawaited(
          _repo
              .markClubRead(club)
              .then((_) => ref.mounted ? ref.invalidate(myClubsProvider) : null)
              .catchError((Object _) {}),
        );
      }
    } on Object catch (e) {
      if (id != _request) return;
      // No signal: the last page read, to read offline
      final cached = e is CommunityException && e.offline
          ? await _repo.cachedFeed(userId: ref.read(authUserIdProvider).value)
          : null;
      if (id != _request) return;
      state = cached == null
          ? state.copyWith(loading: false, error: () => '$e')
          : state.copyWith(posts: cached.posts, hasMore: false, loading: false, savedAt: () => cached.savedAt);
    }
  }

  Future<void> loadMore() async {
    if (state.loading || state.loadingMore || !state.hasMore || state.posts.isEmpty) return;
    final id = _request;
    state = state.copyWith(loadingMore: true, error: () => null);
    try {
      // A club's pinned posts lead its first page out of time order: page on from the others
      final paged = state.filter.clubId == null ? state.posts : state.posts.where((p) => !p.pinned);
      final more = await _page((paged.lastOrNull ?? state.posts.last).createdAt);
      if (id != _request) return;
      state = state.copyWith(
        posts: [...state.posts, ...more],
        hasMore: more.length >= feedPageSize,
        loadingMore: false,
      );
    } on Object catch (e) {
      if (id != _request) return;
      state = state.copyWith(loadingMore: false, error: () => '$e');
    }
  }

  Future<void> setFilter(FeedFilter f) async {
    if (f == state.filter) return;
    state = state.copyWith(filter: f);
    await load();
  }

  /// A post changed (Helpful, comments, edit)
  void replace(CommunityPost post) {
    if (!state.posts.any((p) => p.id == post.id)) return;
    state = state.copyWith(posts: [for (final p in state.posts) p.id == post.id ? post : p]);
  }

  void remove(String id) => state = state.copyWith(posts: state.posts.where((p) => p.id != id).toList());
}

// --- Mine ----------------------------------------------------------------------------------------

class MyPostsState {
  const MyPostsState({this.posts = const [], this.loading = false, this.hasMore = false, this.error});

  final List<CommunityPost> posts;
  final bool loading;
  final bool hasMore;
  final String? error;

  /// "found helpful" on the Mine tab
  int get helpful => posts.fold(0, (n, p) => n + p.helpfulCount);
}

final myPostsProvider = NotifierProvider<MyPostsController, MyPostsState>(MyPostsController.new);

/// The Mine tab: my posts (my_community_posts), paged like the feed
class MyPostsController extends Notifier<MyPostsState> {
  int _request = 0;

  @override
  MyPostsState build() => const MyPostsState();

  Future<void> load({bool more = false}) async {
    if (state.loading || (more && !state.hasMore)) return;
    final id = more ? _request : ++_request;
    final before = more && state.posts.isNotEmpty ? state.posts.last.createdAt : null;
    state = MyPostsState(posts: more ? state.posts : const [], loading: true, hasMore: state.hasMore);
    try {
      final rows = await ref.read(communityRepositoryProvider).myPosts(before: before);
      if (id != _request) return;
      state = MyPostsState(
        posts: [...(more ? state.posts : const <CommunityPost>[]), ...rows],
        hasMore: rows.length >= feedPageSize,
      );
    } on Object catch (e) {
      if (id != _request) return;
      state = MyPostsState(posts: state.posts, hasMore: state.hasMore, error: '$e');
    }
  }
}

// --- Map layer -----------------------------------------------------------------------------------

const communityLayerKey = 'l360-community-layer';

class CommunityLayerState {
  const CommunityLayerState({this.shown = false, this.posts = const []});

  final bool shown;
  final List<CommunityPost> posts; // in view, last 30 days, no old trail reports
}

final communityLayerProvider = NotifierProvider<CommunityLayerController, CommunityLayerState>(
  CommunityLayerController.new,
);

class CommunityLayerController extends Notifier<CommunityLayerState> {
  int _request = 0;

  @override
  CommunityLayerState build() {
    // The switch is remembered on the phone
    unawaited(
      Future(() async {
        try {
          final on = await ref.read(communityPrefsProvider).getBool(communityLayerKey) ?? false;
          if (ref.mounted && on != state.shown) state = CommunityLayerState(shown: on, posts: state.posts);
        } on Object {
          // Not readable (tests): off
        }
      }),
    );
    return const CommunityLayerState();
  }

  void setShown(bool on) {
    state = CommunityLayerState(shown: on, posts: on ? state.posts : const []);
    unawaited(ref.read(communityPrefsProvider).setBool(communityLayerKey, on).catchError((Object _) {}));
  }

  /// Posts in [bounds] for the layer; the feed's kind and condition filter apply too
  Future<void> refresh(Bounds bounds) async {
    if (!state.shown) return;
    final id = ++_request;
    final now = ref.read(communityClockProvider)();
    final f = ref.read(communityFeedProvider).filter;
    try {
      final posts = await ref
          .read(communityRepositoryProvider)
          .feed(
            bounds: bounds,
            kinds: f.kinds,
            conditions: f.conditions,
            since: now.subtract(const Duration(days: reportFreshDays)),
            limit: layerLimit,
            clubId: f.clubId,
          );
      if (id != _request || !state.shown) return;
      state = CommunityLayerState(shown: true, posts: postsForMap(posts, now));
    } on Object {
      // Kept as it was; tried again when the map moves
    }
  }
}

// --- A post (or a club workspace item) shown on the map -----------------------------------------

/// What "Show on map" put on the map: a post with its attachment, or a workspace item
class MapFocus {
  const MapFocus({required this.title, this.attachment, this.point, this.post});

  factory MapFocus.post(CommunityPost p) => MapFocus(
    title: p.title?.trim().isNotEmpty ?? false ? p.title!.trim() : (p.placeName ?? p.kind.label),
    attachment: p.attachment,
    point: (p.lng, p.lat),
    post: p,
  );

  final String title;
  final Attachment? attachment;
  final LngLat? point; // the post's location
  final CommunityPost? post; // null for a workspace item

  List<LngLat> get coords => [...?attachment?.coords, ?point];
}

class CommunityFocus extends Notifier<MapFocus?> {
  @override
  MapFocus? build() => null;

  void show(CommunityPost post) => showFocus(MapFocus.post(post));

  /// Puts it on the map and moves there (fits a shape, flies to a point)
  void showFocus(MapFocus f) {
    state = f;
    final coords = f.coords;
    if (coords.length > 1) {
      ref.read(fitPointsProvider.notifier).go(coords);
    } else if (coords.isNotEmpty) {
      ref.read(flyToProvider.notifier).go(coords.first.$1, coords.first.$2, zoom: 15);
    }
  }

  void clear() => state = null;
}

final communityFocusProvider = NotifierProvider<CommunityFocus, MapFocus?>(CommunityFocus.new);

/// A post asked for by a link (`/community/<id>`); the map screen opens it
class CommunityOpenRequest extends Notifier<String?> {
  @override
  String? build() => null;

  void open(String id) => state = id;
  void done() => state = null;
}

final communityOpenProvider = NotifierProvider<CommunityOpenRequest, String?>(CommunityOpenRequest.new);

/// A club invite asked for by a link (`/?join=<token>`); the map screen opens it
class CommunityJoinRequest extends Notifier<String?> {
  @override
  String? build() => null;

  void open(String token) => state = token;
  void done() => state = null;
}

final communityJoinProvider = NotifierProvider<CommunityJoinRequest, String?>(CommunityJoinRequest.new);

// --- Compose draft, kept while the location is picked on the map --------------------------------

class ComposeDraft {
  const ComposeDraft({
    this.kind = PostKind.report,
    this.title = '',
    this.body = '',
    this.conditions = const [],
    required this.happenedOn,
    this.lat,
    this.lng,
    this.placeName = '',
    this.placeEdited = false,
    this.photos = const [],
    this.attachment,
    this.clubId,
  });

  final PostKind kind;
  final String title;
  final String body;
  final List<String> conditions;
  final String happenedOn;
  final double? lat;
  final double? lng;
  final String placeName;
  final bool placeEdited; // typed by the user: a new location does not replace it
  final List<CompressedPhoto> photos;
  final Attachment? attachment;
  final String? clubId; // audience: null is Everyone

  ComposeDraft at(double lng, double lat) => ComposeDraft(
    kind: kind,
    title: title,
    body: body,
    conditions: conditions,
    happenedOn: happenedOn,
    lat: lat,
    lng: lng,
    placeName: placeName,
    placeEdited: placeEdited,
    photos: photos,
    attachment: attachment,
    clubId: clubId,
  );
}

/// A club event's form, kept while its meeting point is picked on the map
class EventDraft {
  const EventDraft({
    required this.clubId,
    this.eventId,
    this.title = '',
    this.description = '',
    this.startsAt,
    this.endsAt,
    this.meetingName = '',
    this.meetingLat,
    this.meetingLng,
    this.routeItemId,
    this.quota = '',
    this.needsApproval = false,
  });

  final String clubId;
  final String? eventId; // editing
  final String title;
  final String description;
  final DateTime? startsAt;
  final DateTime? endsAt;
  final String meetingName;
  final double? meetingLat;
  final double? meetingLng;
  final String? routeItemId;
  final String quota; // as typed
  final bool needsApproval;

  EventDraft at(double lng, double lat) => EventDraft(
    clubId: clubId,
    eventId: eventId,
    title: title,
    description: description,
    startsAt: startsAt,
    endsAt: endsAt,
    meetingName: meetingName,
    meetingLat: double.parse(lat.toStringAsFixed(6)),
    meetingLng: double.parse(lng.toStringAsFixed(6)),
    routeItemId: routeItemId,
    quota: quota,
    needsApproval: needsApproval,
  );
}

/// A form waiting for a point picked on the map: a post's location or an event's meeting point
class CommunityPick {
  const CommunityPick(this.draft, [this.picked, this.event]);

  final ComposeDraft? draft;
  final LngLat? picked; // set by the map tap
  final EventDraft? event;
}

/// While non-null and not picked yet, the next map tap sets the point
class CommunityPicking extends Notifier<CommunityPick?> {
  @override
  CommunityPick? build() => null;

  void start(ComposeDraft draft) => state = CommunityPick(draft);
  void startEvent(EventDraft event) => state = CommunityPick(null, null, event);
  void set(double lng, double lat) {
    final s = state;
    if (s != null && s.picked == null) state = CommunityPick(s.draft, (lng, lat), s.event);
  }

  void cancel() => state = null;
}

final communityPickProvider = NotifierProvider<CommunityPicking, CommunityPick?>(CommunityPicking.new);

// --- Outbox --------------------------------------------------------------------------------------

class CommunityOutboxState {
  const CommunityOutboxState({this.items = const [], this.sending = false});

  final List<OutboxItem> items;
  final bool sending;
}

final communityOutboxProvider = NotifierProvider<CommunityOutboxController, CommunityOutboxState>(
  CommunityOutboxController.new,
);

class CommunityOutboxController extends Notifier<CommunityOutboxState> {
  String? _userId;

  @override
  CommunityOutboxState build() {
    ref.listen(authUserIdProvider, (_, next) {
      if (!next.hasValue) return;
      _userId = next.value;
      unawaited(
        Future(() async {
          if (!ref.mounted) return;
          if (_userId == null) {
            state = const CommunityOutboxState();
          } else {
            await flush();
          }
        }),
      );
    }, fireImmediately: true);
    // The signal is back: send what waits
    ref.listen(onlineProvider, (prev, next) {
      if (next.value == true && prev?.value != true) unawaited(flush());
    });
    return const CommunityOutboxState();
  }

  CommunityOutbox get _box => ref.read(communityOutboxStoreProvider);

  Future<void> _reload() async {
    final userId = _userId;
    if (userId == null) return;
    try {
      final items = await _box.pending(userId);
      if (ref.mounted && _userId == userId) state = CommunityOutboxState(items: items, sending: state.sending);
    } on Object {
      // Storage not readable: nothing shown
    }
  }

  /// Keeps a trail report on the phone and tries to send it now
  Future<void> queue(NewPost post, List<CompressedPhoto> photos) async {
    final userId = _userId ?? ref.read(authUserIdProvider).value;
    if (userId == null) throw const CommunityException('Sign in to post in Community');
    _userId = userId;
    await _box.queue(userId, post, photos);
    await _reload();
    unawaited(flush());
  }

  /// Sends every report waiting for this account; the feed shows the ones that went
  Future<void> flush() async {
    final userId = _userId;
    if (userId == null || state.sending) return;
    // No network: nothing to try until it is back (the listener above sends then)
    if (ref.read(onlineProvider).value == false) {
      await _reload();
      return;
    }
    try {
      final waiting = await _box.pending(userId);
      if (waiting.every((x) => x.error != null)) {
        if (ref.mounted) state = CommunityOutboxState(items: waiting);
        return;
      }
      state = CommunityOutboxState(items: waiting, sending: true);
      final result = await _box.flush(userId);
      if (!ref.mounted) return;
      state = CommunityOutboxState(items: state.items);
      if (result.sentPostIds.isNotEmpty) {
        ref.invalidate(communityLimitsProvider);
        unawaited(ref.read(communityFeedProvider.notifier).load());
      }
    } on Object {
      if (ref.mounted) state = CommunityOutboxState(items: state.items);
    }
    await _reload();
  }

  Future<void> discard(String clientId) async {
    await _box.discard(clientId);
    await _reload();
  }

  Future<void> retry(String clientId) async {
    await _box.retry(clientId);
    await _reload();
    await flush();
  }
}

/// Compresses picked photo bytes (in the background in the app; tests replace it)
final communityCompressorProvider = Provider<Future<CompressedPhoto> Function(Uint8List)>(
  (ref) => compressPhotoInBackground,
);

/// The same for a club photo (640 px)
final clubPhotoCompressorProvider = Provider<Future<CompressedPhoto> Function(Uint8List)>(
  (ref) =>
      (bytes) => compressPhotoInBackground(bytes, maxSide: clubPhotoSide),
);
