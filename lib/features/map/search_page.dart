import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:geolocator/geolocator.dart' as geo;

import '../../core/theme/app_theme.dart';
import '../../domain/search/place_search.dart';
import 'map_tools_state.dart';

/// Opens the search; returns the chosen place, or null
Future<SearchResult?> showPlaceSearch(BuildContext context) =>
    Navigator.of(context)
        .push<SearchResult>(MaterialPageRoute(fullscreenDialog: true, builder: (_) => const SearchPage()));

/// Location search like the web's SearchPanel: the app's verified points first, then places
/// from Mapbox, or coordinates typed as "lat, lon"
class SearchPage extends ConsumerStatefulWidget {
  const SearchPage({super.key});

  @override
  ConsumerState<SearchPage> createState() => _SearchPageState();
}

class _SearchPageState extends ConsumerState<SearchPage> {
  final _query = TextEditingController();
  Timer? _debounce;
  int _run = 0;
  bool _loading = false;
  String? _error;
  List<SearchResult> _results = const [];
  ({double lng, double lat})? _near;

  @override
  void initState() {
    super.initState();
    unawaited(_locate());
  }

  // Results near the user rank first; without permission the server uses the IP location
  Future<void> _locate() async {
    try {
      final p = await geo.Geolocator.checkPermission();
      if (p != geo.LocationPermission.always && p != geo.LocationPermission.whileInUse) return;
      final last = await geo.Geolocator.getLastKnownPosition();
      if (last != null && mounted) _near = (lng: last.longitude, lat: last.latitude);
    } on Object {
      // No location: search without it
    }
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _query.dispose();
    super.dispose();
  }

  void _onChanged(String text) {
    setState(() {});
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 500), () => unawaited(_search(text.trim())));
  }

  Future<void> _search(String text) async {
    final run = ++_run;
    if (!isSearchable(text)) {
      setState(() {
        _results = const [];
        _loading = false;
        _error = null;
      });
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
    });
    final pois = ref.read(poisProvider).value ?? const <PointOfInterest>[];
    final verified = searchPois(pois, text);
    List<SearchResult> places = const [];
    String? error;
    try {
      places = await ref.read(geocodingServiceProvider).search(text, near: _near);
    } on Object {
      error = verified.isEmpty ? 'Search needs a connection. Check your signal and try again.' : null;
    }
    if (run != _run || !mounted) return;
    setState(() {
      _results = mergeResults(verified, places);
      _loading = false;
      _error = error;
    });
  }

  void _select(SearchResult r) {
    HapticFeedback.selectionClick();
    Navigator.of(context).pop(r);
  }

  @override
  Widget build(BuildContext context) {
    ref.watch(poisProvider); // loads the points as soon as the search opens
    final text = _query.text.trim();
    final coordinate = parseCoordinateQuery(text) != null;
    final verified = _results.where((r) => r.verified).toList();
    final places = _results.where((r) => !r.verified).toList();
    return Scaffold(
      appBar: AppBar(
        titleSpacing: 0,
        title: Padding(
          padding: const EdgeInsets.only(right: 12),
          child: TextField(
            key: const Key('search-field'),
            controller: _query,
            autofocus: true,
            textInputAction: TextInputAction.search,
            onChanged: _onChanged,
            onSubmitted: (_) {
              if (_results.isNotEmpty) _select(_results.first);
            },
            decoration: InputDecoration(
              hintText: 'Search mountains, basecamp, or cities...',
              prefixIcon: const Icon(Icons.search, size: 20),
              suffixIcon: _loading
                  ? const Padding(
                      padding: EdgeInsets.all(14),
                      child: SizedBox.square(dimension: 16, child: CircularProgressIndicator(strokeWidth: 2)),
                    )
                  : text.isEmpty
                  ? null
                  : IconButton(
                      tooltip: 'Clear',
                      icon: const Icon(Icons.close, size: 18),
                      onPressed: () {
                        _query.clear();
                        _onChanged('');
                      },
                    ),
              contentPadding: const EdgeInsets.symmetric(vertical: 10),
              isDense: true,
            ),
          ),
        ),
      ),
      body: ListView(
        keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
        padding: const EdgeInsets.fromLTRB(L360.gutter, 8, L360.gutter, 24),
        children: [
          if (coordinate)
            const Padding(
              padding: EdgeInsets.only(bottom: 12),
              child: Row(
                children: [
                  Icon(Icons.gps_fixed, size: 14, color: L360Colors.forest700),
                  SizedBox(width: 6),
                  Text('Coordinate search (Lat, Lon)', style: TextStyle(fontSize: 12, color: L360Colors.forest700)),
                ],
              ),
            ),
          if (_error != null) _Message(icon: Icons.wifi_off, title: 'Search unavailable', body: _error!),
          if (verified.isNotEmpty) ...[
            const _Header(icon: Icons.verified_outlined, text: 'Verified Locations'),
            for (final r in verified) _ResultTile(result: r, onTap: () => _select(r)),
            const SizedBox(height: 12),
          ],
          if (places.isNotEmpty) ...[
            const _Header(icon: Icons.place_outlined, text: 'Places'),
            for (final r in places) _ResultTile(result: r, onTap: () => _select(r)),
          ],
          if (_results.isEmpty && !_loading && _error == null && isSearchable(text))
            const _Message(
              icon: Icons.search_off,
              title: 'No locations found',
              body: 'Try a different keyword, or paste coordinates like -6.77, 106.98.',
            ),
          if (!isSearchable(text))
            const _Message(
              icon: Icons.travel_explore,
              title: 'Find a place',
              body: 'Mountains, basecamps, cities or coordinates like -6.77, 106.98.',
            ),
        ],
      ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(4, 8, 4, 6),
    child: Row(
      children: [
        Icon(icon, size: 14, color: L360Colors.sand500),
        const SizedBox(width: 6),
        Text(
          text.toUpperCase(),
          style: const TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.w700,
            letterSpacing: 0.9,
            color: L360Colors.sand500,
          ),
        ),
      ],
    ),
  );
}

class _ResultTile extends StatelessWidget {
  const _ResultTile({required this.result, required this.onTap});

  final SearchResult result;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final (icon, fg, bg) = switch (result.kind) {
      ResultKind.mountain => (Icons.landscape_outlined, L360Colors.ember600, const Color(0xFFFEF3EC)),
      ResultKind.basecamp => (Icons.cabin_outlined, L360Colors.forest700, L360Colors.forest50),
      ResultKind.poi => (Icons.place_outlined, L360Colors.gold700, L360Colors.gold50),
      ResultKind.place => (Icons.near_me_outlined, L360Colors.sand600, L360Colors.sand100),
    };
    return ListTile(
      onTap: onTap,
      contentPadding: const EdgeInsets.symmetric(horizontal: 4),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(L360.radiusSmall)),
      leading: Container(
        width: 38,
        height: 38,
        decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(10)),
        child: Icon(icon, size: 20, color: fg),
      ),
      title: Row(
        children: [
          Flexible(child: Text(result.title, maxLines: 1, overflow: TextOverflow.ellipsis)),
          if (result.verified) ...[
            const SizedBox(width: 4),
            const Icon(Icons.verified, size: 14, color: L360Colors.forest600),
          ],
        ],
      ),
      subtitle: result.subtitle.isEmpty ? null : Text(result.subtitle, maxLines: 1, overflow: TextOverflow.ellipsis),
      trailing: const Icon(Icons.north_west, size: 16, color: L360Colors.sand400),
    );
  }
}

class _Message extends StatelessWidget {
  const _Message({required this.icon, required this.title, required this.body});

  final IconData icon;
  final String title;
  final String body;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 40, horizontal: 16),
    child: Column(
      children: [
        Icon(icon, size: 40, color: L360Colors.sand300),
        const SizedBox(height: 12),
        Text(title, style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 4),
        Text(
          body,
          textAlign: TextAlign.center,
          style: const TextStyle(color: L360Colors.sand500),
        ),
      ],
    ),
  );
}
