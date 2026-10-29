import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mapbox_maps_flutter/mapbox_maps_flutter.dart' as mbx;
import 'package:url_launcher/url_launcher.dart';

import '../../core/theme/app_theme.dart';
import '../../data/sos/sos_backend.dart';
import '../../domain/account/account_rules.dart';
import '../../domain/survey/survey_utils.dart';
import '../../domain/util/js_compat.dart';
import '../map/map_tools_state.dart';
import '../map/style_guard.dart';
import 'sos_state.dart';

// Admin side of S.O.S (SosAdminLayer.tsx + SosAlertsPanel.tsx): a red banner and a red
// marker for every active S.O.S, and the list with the message, full location, battery,
// times, call / WhatsApp, resolve with a note and delete from the history.

String _timeAgo(DateTime t) {
  final s = DateTime.now().difference(t).inSeconds;
  if (s < 60) return 'just now';
  if (s < 3600) return '${s ~/ 60} min ago';
  if (s < 86400) return '${s ~/ 3600} h ago';
  return '${s ~/ 86400} d ago';
}

String _when(DateTime? t) {
  if (t == null) return '—';
  String p(int n) => n.toString().padLeft(2, '0');
  return '${p(t.day)}/${p(t.month)}/${t.year} ${p(t.hour)}:${p(t.minute)}';
}

/// "2 active S.O.S · View" at the top of the map
class SosBanner extends ConsumerWidget {
  const SosBanner({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final active = ref.watch(sosAlertsProvider.select((s) => s.active.length));
    if (active == 0) return const SizedBox.shrink();
    return Center(
      child: Material(
        key: const Key('sos-banner'),
        color: const Color(0xFF962620),
        shape: const StadiumBorder(),
        elevation: 6,
        child: InkWell(
          customBorder: const StadiumBorder(),
          onTap: () => showSosAlertsSheet(context),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.sos, color: Colors.white, size: 18),
                const SizedBox(width: 8),
                Text(
                  '$active active S.O.S · View',
                  style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w800, fontSize: 14),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

Future<void> showSosAlertsSheet(BuildContext context) => showModalBottomSheet<void>(
  context: context,
  isScrollControlled: true,
  useSafeArea: true,
  builder: (_) => DraggableScrollableSheet(
    expand: false,
    initialChildSize: 0.8,
    maxChildSize: 0.95,
    builder: (context, controller) => _AlertsSheet(controller: controller),
  ),
);

class _AlertsSheet extends ConsumerStatefulWidget {
  const _AlertsSheet({required this.controller});
  final ScrollController controller;

  @override
  ConsumerState<_AlertsSheet> createState() => _AlertsSheetState();
}

class _AlertsSheetState extends ConsumerState<_AlertsSheet> {
  bool _all = false;
  List<SosAlert>? _alerts;
  String? _error;
  bool _loading = false;
  Timer? _poll;

  @override
  void initState() {
    super.initState();
    unawaited(_refresh());
    _poll = Timer.periodic(sosReportEvery, (_) => unawaited(_refresh()));
  }

  @override
  void dispose() {
    _poll?.cancel();
    super.dispose();
  }

  SosBackend get _backend => ref.read(sosBackendProvider);

  Future<void> _refresh() async {
    setState(() => _loading = true);
    try {
      final list = await _backend.alerts(onlyActive: !_all);
      if (!mounted) return;
      setState(() {
        _alerts = list;
        _error = null;
      });
    } on Object catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _resolve(SosAlert a) async {
    final note = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog.adaptive(
        title: Text('Resolve S.O.S of ${a.shortName}?'),
        content: Material(
          type: MaterialType.transparency,
          child: TextField(
            controller: note,
            maxLength: 500,
            decoration: const InputDecoration(hintText: 'Note (optional), e.g. found safe by the SAR team'),
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.pop(context, true), child: const Text('Mark resolved')),
        ],
      ),
    );
    final text = note.text;
    note.dispose();
    if (ok != true) return;
    try {
      await _backend.resolve(a.id, text);
      await Future.wait([_refresh(), ref.read(sosAlertsProvider.notifier).refresh()]);
    } on Object catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
  }

  Future<void> _delete(SosAlert a) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog.adaptive(
        title: const Text('Delete this alert and its trail?'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            style: TextButton.styleFrom(foregroundColor: L360Colors.brick500),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await _backend.delete(a.id);
      if (mounted) setState(() => _alerts = _alerts?.where((x) => x.id != a.id).toList());
    } on Object catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final alerts = _alerts;
    return ListView(
      controller: widget.controller,
      padding: const EdgeInsets.fromLTRB(L360.gutter, 0, L360.gutter, 32),
      children: [
        Row(
          children: [
            const Icon(Icons.sos, color: L360Colors.brick500),
            const SizedBox(width: 8),
            Expanded(child: Text('S.O.S alerts', style: Theme.of(context).textTheme.titleLarge)),
            IconButton(
              tooltip: 'Refresh',
              onPressed: _loading ? null : _refresh,
              icon: _loading
                  ? const SizedBox.square(dimension: 18, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.refresh),
            ),
          ],
        ),
        const SizedBox(height: 8),
        SegmentedButton<bool>(
          showSelectedIcon: false,
          segments: const [
            ButtonSegment(value: false, label: Text('Active')),
            ButtonSegment(value: true, label: Text('All (history)')),
          ],
          selected: {_all},
          onSelectionChanged: (v) {
            setState(() {
              _all = v.first;
              _alerts = null;
            });
            unawaited(_refresh());
          },
        ),
        const SizedBox(height: 10),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Text(_error!, style: const TextStyle(color: L360Colors.brick500)),
          ),
        if (alerts == null)
          const Padding(
            padding: EdgeInsets.all(28),
            child: Center(child: CircularProgressIndicator()),
          )
        else if (alerts.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 28),
            child: Text(
              _all ? 'No S.O.S alerts yet' : 'No active S.O.S',
              textAlign: TextAlign.center,
              style: const TextStyle(color: L360Colors.sand500),
            ),
          )
        else
          for (final a in alerts)
            _AlertCard(
              alert: a,
              onMap: a.hasLocation
                  ? () {
                      ref.read(flyToProvider.notifier).go(a.lng!, a.lat!, zoom: 15);
                      Navigator.pop(context);
                    }
                  : null,
              onResolve: a.active ? () => _resolve(a) : null,
              onDelete: _all && !a.active ? () => _delete(a) : null,
            ),
      ],
    );
  }
}

// Side by side, not the theme's full-width buttons
final _compact = ButtonStyle(
  minimumSize: const WidgetStatePropertyAll(Size(0, 40)),
  padding: const WidgetStatePropertyAll(EdgeInsets.symmetric(horizontal: 14)),
);

class _AlertCard extends StatelessWidget {
  const _AlertCard({required this.alert, this.onMap, this.onResolve, this.onDelete});

  final SosAlert alert;
  final VoidCallback? onMap;
  final VoidCallback? onResolve;
  final VoidCallback? onDelete;

  @override
  Widget build(BuildContext context) {
    final a = alert;
    final wa = a.phone == null ? null : whatsappUrl(a.phone!);
    const small = TextStyle(fontSize: 12, color: L360Colors.sand600);
    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(L360.radiusSmall),
        side: BorderSide(color: a.active ? const Color(0xFFF6BDB7) : L360Colors.sand200),
      ),
      color: a.active ? L360Colors.brick50 : null,
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Flexible(
                            child: Text(
                              a.name ?? a.email,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w800),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                            decoration: BoxDecoration(
                              color: a.active ? L360Colors.brick500 : L360Colors.forest100,
                              borderRadius: BorderRadius.circular(6),
                            ),
                            child: Text(
                              a.active ? 'ACTIVE' : 'RESOLVED',
                              style: TextStyle(
                                fontSize: 10,
                                fontWeight: FontWeight.w800,
                                color: a.active ? Colors.white : L360Colors.forest700,
                              ),
                            ),
                          ),
                        ],
                      ),
                      Text(
                        [a.email, a.organization, a.phone].whereType<String>().where((x) => x.isNotEmpty).join(' · '),
                        style: small,
                      ),
                    ],
                  ),
                ),
                if (a.battery != null)
                  Row(
                    children: [
                      const Icon(Icons.battery_std, size: 15, color: L360Colors.sand600),
                      Text('${a.battery}%', style: small),
                    ],
                  ),
              ],
            ),
            if (a.message?.isNotEmpty ?? false) ...[
              const SizedBox(height: 8),
              Text('“${a.message}”', style: const TextStyle(fontWeight: FontWeight.w600)),
            ],
            const SizedBox(height: 8),
            if (a.hasLocation) ...[
              Text(
                '${toDMS(a.lat!, isLat: true)} ${toDMS(a.lng!, isLat: false)}',
                style: const TextStyle(fontWeight: FontWeight.w700),
              ),
              Text(
                '${a.lat!.toStringAsFixed(5)}, ${a.lng!.toStringAsFixed(5)} · UTM ${toUTM(a.lat!, a.lng!)}',
                style: small,
              ),
              Text(
                [
                  if (a.elevation != null) 'Elev ${jsRoundStr(a.elevation!)} m',
                  if (a.accuracy != null) '±${jsRoundStr(a.accuracy!)} m',
                  'fix ${a.locatedAt == null ? '—' : _timeAgo(a.locatedAt!)}',
                  '${a.pointCount} positions',
                ].join(' · '),
                style: small,
              ),
            ] else
              const Text('No location yet', style: small),
            const SizedBox(height: 8),
            Text('S.O.S raised ${_when(a.startedAt)} · received ${_when(a.receivedAt)}', style: small),
            Text('Last update ${_when(a.updatedAt)} (${_timeAgo(a.updatedAt)})', style: small),
            if (a.resolvedAt != null)
              Text(
                'Resolved ${_when(a.resolvedAt)}${a.resolvedNote == null ? '' : ': ${a.resolvedNote}'}',
                style: small,
              ),
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                if (onMap != null)
                  OutlinedButton.icon(
                    style: _compact,
                    onPressed: onMap,
                    icon: const Icon(Icons.near_me, size: 16),
                    label: const Text('Show on map'),
                  ),
                if (a.phone?.isNotEmpty ?? false)
                  OutlinedButton.icon(
                    style: _compact,
                    onPressed: () => launchUrl(Uri.parse('tel:${a.phone}')),
                    icon: const Icon(Icons.phone, size: 16),
                    label: const Text('Call'),
                  ),
                if (wa != null)
                  OutlinedButton.icon(
                    style: _compact,
                    onPressed: () => launchUrl(Uri.parse(wa), mode: LaunchMode.externalApplication),
                    icon: const Icon(Icons.chat_outlined, size: 16),
                    label: const Text('WhatsApp'),
                  ),
                if (onResolve != null)
                  FilledButton.icon(
                    style: _compact,
                    key: Key('sos-resolve-${a.id}'),
                    onPressed: onResolve,
                    icon: const Icon(Icons.check, size: 16),
                    label: const Text('Mark resolved'),
                  ),
                if (onDelete != null)
                  TextButton.icon(
                    onPressed: onDelete,
                    style: TextButton.styleFrom(foregroundColor: L360Colors.brick500, minimumSize: const Size(0, 40)),
                    icon: const Icon(Icons.delete_outline, size: 16),
                    label: const Text('Delete'),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

// --- Markers on the map -----------------------------------------------------------------------

const _source = 'sos-alerts';

Map<String, Object> sosAlertsGeoJson(List<SosAlert> alerts) => {
  'type': 'FeatureCollection',
  'features': [
    for (final a in alerts)
      if (a.hasLocation)
        {
          'type': 'Feature',
          'properties': {'label': 'SOS · ${a.shortName}'},
          'geometry': {
            'type': 'Point',
            'coordinates': [a.lng, a.lat],
          },
        },
  ],
};

class SosAlertsLayer {
  SosAlertsLayer(this.map);

  final mbx.MapboxMap map;
  bool _installed = false;

  Future<void> install() async {
    _installed = false;
    if (!await map.styleSourceExists(_source)) {
      await map.addStyleSource(_source, jsonEncode({'type': 'geojson', 'data': sosAlertsGeoJson(const [])}));
    }
    for (final layer in [
      {
        'id': '$_source-halo',
        'type': 'circle',
        'source': _source,
        'paint': {'circle-radius': 18, 'circle-color': '#B4302A', 'circle-opacity': 0.3},
      },
      {
        'id': '$_source-dot',
        'type': 'circle',
        'source': _source,
        'paint': {
          'circle-radius': 9,
          'circle-color': '#962620',
          'circle-stroke-color': '#ffffff',
          'circle-stroke-width': 2.5,
        },
      },
      {
        'id': '$_source-label',
        'type': 'symbol',
        'source': _source,
        'layout': {
          'text-field': ['get', 'label'],
          'text-size': 12,
          'text-offset': [0, 1.6],
          'text-anchor': 'top',
          'text-allow-overlap': true,
        },
        'paint': {'text-color': '#962620', 'text-halo-color': '#ffffff', 'text-halo-width': 2},
      },
    ]) {
      final id = layer['id']! as String;
      if (await map.styleLayerExists(id)) await map.removeStyleLayer(id);
      await map.addStyleLayer(jsonEncode(layer), null);
    }
    _installed = true;
  }

  Future<void> show(List<SosAlert> alerts) => onStyle(() => _show(alerts));

  Future<void> _show(List<SosAlert> alerts) async {
    if (!_installed) return;
    await map.setStyleSourceProperty(_source, 'data', sosAlertsGeoJson(alerts));
  }
}
