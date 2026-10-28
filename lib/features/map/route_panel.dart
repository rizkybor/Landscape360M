import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/app_theme.dart';
import '../../domain/route/route_planner.dart';
import 'map_tools_state.dart';

/// Route Planner panel above the sheet, like the web's phone layout: start / destination
/// (tap the map), travel mode, distance and time, clear and recalculate. Kept compact so
/// the map stays visible while points are picked.
class RoutePanel extends ConsumerWidget {
  const RoutePanel({super.key});

  static const _modeIcons = {
    RouteMode.drivingToll: Icons.directions_car_outlined,
    RouteMode.drivingNoToll: Icons.directions_car_filled_outlined,
    RouteMode.walking: Icons.directions_walk,
  };

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(routePlannerProvider);
    final c = ref.read(routePlannerProvider.notifier);
    final r = s.result;
    return Material(
      key: const Key('route-panel'),
      color: Colors.white,
      elevation: 6,
      shadowColor: const Color(0x40000000),
      borderRadius: BorderRadius.circular(L360.radius),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 4, 8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Title; the result replaces the subtitle once there is a route
            Row(
              children: [
                const Icon(Icons.alt_route, size: 20, color: L360Colors.forest700),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text('Route Planner', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700)),
                      if (s.loading)
                        const Text('Calculating…', style: TextStyle(fontSize: 11, color: L360Colors.sand500))
                      else if (r != null)
                        Text.rich(
                          TextSpan(
                            children: [
                              TextSpan(
                                text: '${formatRouteKm(r.distanceM)} km',
                                style: const TextStyle(fontWeight: FontWeight.w700, color: L360Colors.ink),
                              ),
                              const TextSpan(text: '  ·  '),
                              TextSpan(
                                text: formatRouteDuration(r.durationS),
                                style: const TextStyle(fontWeight: FontWeight.w700, color: L360Colors.ink),
                              ),
                            ],
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 12, color: L360Colors.sand500),
                        )
                      else
                        const Text(
                          'Plan a route between two points',
                          style: TextStyle(fontSize: 11, color: L360Colors.sand500),
                        ),
                    ],
                  ),
                ),
                IconButton(
                  key: const Key('route-close'),
                  tooltip: 'Close',
                  visualDensity: VisualDensity.compact,
                  icon: const Icon(Icons.close, size: 20),
                  onPressed: c.disable,
                ),
              ],
            ),
            const SizedBox(height: 6),
            // Start and destination in one card, with the swap button
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: Container(
                decoration: BoxDecoration(
                  color: L360Colors.sand50,
                  borderRadius: BorderRadius.circular(L360.radiusSmall),
                  border: Border.all(color: L360Colors.sand200),
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: Column(
                        children: [
                          _PointRow(step: 'start', point: s.draft.start, isNext: s.nextStep == 'start', waiting: false),
                          const Divider(indent: 34),
                          _PointRow(
                            step: 'end',
                            point: s.draft.end,
                            isNext: s.nextStep == 'end',
                            waiting: s.draft.start == null,
                          ),
                        ],
                      ),
                    ),
                    IconButton(
                      tooltip: 'Swap start and destination',
                      visualDensity: VisualDensity.compact,
                      onPressed: s.draft.complete ? c.swap : null,
                      icon: const Icon(Icons.swap_vert, size: 20),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 8),
            // Travel mode
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: Container(
                padding: const EdgeInsets.all(3),
                decoration: BoxDecoration(color: L360Colors.sand100, borderRadius: BorderRadius.circular(10)),
                child: Row(
                  children: [
                    for (final mode in RouteMode.values)
                      Expanded(
                        child: GestureDetector(
                          key: Key('route-mode-${mode.id}'),
                          behavior: HitTestBehavior.opaque,
                          onTap: () {
                            HapticFeedback.selectionClick();
                            c.setMode(mode);
                          },
                          child: AnimatedContainer(
                            duration: const Duration(milliseconds: 150),
                            height: 38,
                            decoration: BoxDecoration(
                              color: s.mode == mode ? Colors.white : Colors.transparent,
                              borderRadius: BorderRadius.circular(8),
                              boxShadow: s.mode == mode
                                  ? const [BoxShadow(color: Color(0x14000000), blurRadius: 3)]
                                  : null,
                            ),
                            child: Row(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                Icon(
                                  _modeIcons[mode],
                                  size: 17,
                                  color: s.mode == mode ? Color(mode.color) : L360Colors.sand500,
                                ),
                                const SizedBox(width: 5),
                                Flexible(
                                  child: Column(
                                    mainAxisSize: MainAxisSize.min,
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        mode.label,
                                        style: TextStyle(
                                          fontSize: 11,
                                          height: 1.1,
                                          fontWeight: FontWeight.w700,
                                          color: s.mode == mode ? L360Colors.forest800 : L360Colors.sand600,
                                        ),
                                      ),
                                      Text(
                                        mode.hint,
                                        maxLines: 1,
                                        style: const TextStyle(fontSize: 9, height: 1.1, color: L360Colors.sand500),
                                      ),
                                    ],
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
            if (s.error != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(2, 8, 8, 0),
                child: Text(s.error!, style: const TextStyle(fontSize: 12, color: L360Colors.brick500)),
              ),
            Row(
              children: [
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.only(left: 2),
                    child: Text(
                      s.nextStep == null ? 'Tap the map again to start a new route.' : '',
                      style: const TextStyle(fontSize: 11, color: L360Colors.sand500),
                    ),
                  ),
                ),
                TextButton.icon(
                  style: TextButton.styleFrom(visualDensity: VisualDensity.compact),
                  onPressed: s.draft.start == null && s.draft.end == null ? null : c.clear,
                  icon: const Icon(Icons.delete_outline, size: 16),
                  label: const Text('Clear'),
                ),
                TextButton.icon(
                  style: TextButton.styleFrom(visualDensity: VisualDensity.compact),
                  onPressed: s.draft.complete && !s.loading ? c.compute : null,
                  icon: const Icon(Icons.refresh, size: 16),
                  label: const Text('Recalculate'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _PointRow extends StatelessWidget {
  const _PointRow({required this.step, required this.point, required this.isNext, required this.waiting});

  final String step;
  final RoutePoint? point;
  final bool isNext;
  final bool waiting;

  @override
  Widget build(BuildContext context) {
    final start = step == 'start';
    return Container(
      color: isNext ? L360Colors.forest50 : null,
      padding: const EdgeInsets.fromLTRB(10, 6, 6, 6),
      child: Row(
        children: [
          Icon(
            start ? Icons.trip_origin : Icons.flag,
            size: 16,
            color: start ? L360Colors.forest600 : L360Colors.ember500,
          ),
          const SizedBox(width: 8),
          SizedBox(
            width: 76,
            child: Text(
              start ? 'Start' : 'Destination',
              style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: L360Colors.sand600),
            ),
          ),
          Expanded(
            child: Text(
              point != null
                  ? formatRoutePoint(point!)
                  : isNext
                  ? 'Tap on the map to set this point'
                  : waiting
                  ? 'Waiting for start point'
                  : '',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 12,
                fontWeight: point != null ? FontWeight.w600 : FontWeight.w400,
                color: point != null ? L360Colors.ink : (isNext ? L360Colors.forest700 : L360Colors.sand500),
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
