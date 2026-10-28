import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/providers.dart';
import '../../core/theme/app_theme.dart';
import '../../core/ui/widgets.dart';
import '../../domain/account/profile.dart';
import '../../domain/map/grid_dms.dart';
import '../../domain/map/map_settings.dart';
import '../../domain/share/share_location.dart';
import '../../domain/terrain/contours.dart';
import '../areas/area_state.dart';
import '../basemaps/basemap_sheet.dart';
import '../basemaps/basemap_state.dart';
import '../guide/quick_guide.dart';
import '../marked/marked_sheet.dart';
import '../marked/marked_state.dart';
import '../navigator/navigator_state.dart';
import '../offline/offline_state.dart';
import '../offline/offline_ui.dart';
import '../tracks/track_recorder_state.dart';
import 'map_settings_controller.dart';
import 'map_tools_state.dart';
import 'search_page.dart';

/// Height of the sheet's always-visible part (grabber, header, section tabs) until it has
/// been measured, without the bottom safe area
const mapSheetPeekHeight = 140.0;

enum _Section { tools, map, terrain }

/// Bottom sheet like the mobile web: header (Guide, account), Tools / Map / Terrain
/// sections and the footer links
class MapSheet extends ConsumerStatefulWidget {
  const MapSheet({
    super.key,
    required this.scrollController,
    this.onContentHeight,
    this.onHeaderHeight,
    this.bodyVisibility = 1,
    this.onSectionChanged,
    this.onHandleDrag,
    this.onHandleDragEnd,
    this.onGrabberTap,
  });

  final ScrollController scrollController;

  /// Height of the part that stays visible when the sheet is closed (grabber, header, tabs)
  final ValueChanged<double>? onHeaderHeight;

  /// 0 while the sheet is closed (only the header shows), 1 once it is opened
  final double bodyVisibility;

  /// A section tab was tapped (the map opens the sheet to show it)
  final VoidCallback? onSectionChanged;

  /// The header works as the sheet's handle: dragged by [onHandleDrag] (pixels, down is
  /// positive), released with [onHandleDragEnd] (velocity in px/s), tapped on the grabber
  /// with [onGrabberTap]
  final ValueChanged<double>? onHandleDrag;
  final ValueChanged<double>? onHandleDragEnd;
  final VoidCallback? onGrabberTap;

  /// Height of everything in the sheet; the map limits how far the sheet opens to it, so
  /// it never shows empty space below short sections
  final ValueChanged<double>? onContentHeight;

  @override
  ConsumerState<MapSheet> createState() => _MapSheetState();
}

class _MapSheetState extends ConsumerState<MapSheet> {
  _Section _section = _Section.tools;

  // The Map section's pictures are decoded once up front, so they do not show blank for a
  // frame each time the section opens
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    for (final image in [
      ..._MapSection._styleImages.values,
      'assets/images/view_2d.jpg',
      'assets/images/view_3d.jpg',
    ]) {
      unawaited(precacheImage(AssetImage(image), context));
    }
  }

  double? _headerHeight;
  double? _bodyHeight;

  /// The whole sheet's height (header plus section), once both are measured
  void _reportHeight() {
    final h = _headerHeight, b = _bodyHeight;
    if (h != null && b != null) widget.onContentHeight?.call(h + b);
  }

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: const BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
        boxShadow: [BoxShadow(color: Color(0x33000000), blurRadius: 24, offset: Offset(0, -2))],
      ),
      child: ClipRRect(
        borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
        // The header (grabber, title, section tabs) stays put; only the section scrolls, so
        // the tabs are always there to switch. When the screen gets shorter than the header
        // for a moment (keyboard, resize) it is clipped instead of squeezed.
        child: LayoutBuilder(
          builder: (context, c) {
            // Before the header is measured (first frame) leave it room enough
            final h = math.max(c.maxHeight, _headerHeight ?? 400);
            return OverflowBox(
              alignment: Alignment.topCenter,
              minHeight: h,
              maxHeight: h,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  MeasureSize(
                    onChange: (size) {
                      _headerHeight = size.height;
                      widget.onHeaderHeight?.call(size.height);
                      _reportHeight();
                    },
                    child: GestureDetector(
                      behavior: HitTestBehavior.translucent,
                      onVerticalDragUpdate: widget.onHandleDrag == null
                          ? null
                          : (d) => widget.onHandleDrag!(d.delta.dy),
                      onVerticalDragEnd: widget.onHandleDragEnd == null
                          ? null
                          : (d) => widget.onHandleDragEnd!(d.velocity.pixelsPerSecond.dy),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          GestureDetector(
                            key: const Key('sheet-grabber'),
                            behavior: HitTestBehavior.opaque,
                            onTap: widget.onGrabberTap,
                            child: const _Grabber(),
                          ),
                          const _Header(),
                          Padding(
                            padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
                            child: _SectionTabs(
                              value: _section,
                              onChanged: (s) {
                                setState(() => _section = s);
                                widget.onSectionChanged?.call();
                              },
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  Expanded(
                    child: SingleChildScrollView(
                      controller: widget.scrollController,
                      // No bounce past the end: the sheet never shows empty space below its content
                      physics: const ClampingScrollPhysics(),
                      child: MeasureSize(
                        // The whole sheet's height: header plus this
                        onChange: (size) {
                          _bodyHeight = size.height;
                          _reportHeight();
                        },
                        child: IgnorePointer(
                          ignoring: widget.bodyVisibility < 0.5,
                          child: Opacity(
                            opacity: widget.bodyVisibility,
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                const Divider(),
                                Padding(
                                  padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
                                  // The section changes at once; the sheet itself slides to the new height
                                  child: KeyedSubtree(
                                    key: ValueKey(_section),
                                    child: switch (_section) {
                                      _Section.tools => const _ToolsSection(),
                                      _Section.map => const _MapSection(),
                                      _Section.terrain => const _TerrainSection(),
                                    },
                                  ),
                                ),
                                const _Footer(),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            );
          },
        ),
      ),
    );
  }
}

class _Grabber extends StatelessWidget {
  const _Grabber();

  @override
  Widget build(BuildContext context) => Center(
    child: Container(
      margin: const EdgeInsets.only(top: 10, bottom: 8),
      width: 38,
      height: 5,
      decoration: BoxDecoration(color: L360Colors.sand300, borderRadius: BorderRadius.circular(3)),
    ),
  );
}

class _Header extends ConsumerWidget {
  const _Header();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final profile = ref.watch(profileProvider).value;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 8, 4),
      child: Row(
        children: [
          Image.asset('assets/images/logo.png', width: 36, height: 36),
          const SizedBox(width: 10),
          const Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                BrandName(),
                Text('Explore without Limits', style: TextStyle(fontSize: 12, color: L360Colors.sand500)),
              ],
            ),
          ),
          // Same header icons as the mobile web: Guide, Weather, Search (no app sharing here)
          _HeaderButton(
            key: const Key('guide'),
            tooltip: 'Quick Guide',
            icon: Icons.help_outline,
            onPressed: () => showQuickGuide(context),
          ),
          _HeaderButton(
            key: const Key('weather'),
            tooltip: 'Weather',
            icon: ref.watch(weatherShownProvider) ? Icons.wb_cloudy : Icons.wb_cloudy_outlined,
            active: ref.watch(weatherShownProvider),
            onPressed: () => ref.read(weatherShownProvider.notifier).toggle(),
          ),
          _HeaderButton(
            key: const Key('search'),
            tooltip: 'Search location',
            icon: Icons.search,
            onPressed: () async {
              final r = await showPlaceSearch(context);
              if (r != null) ref.read(flyToProvider.notifier).go(r.lng, r.lat);
            },
          ),
          _AccountButton(profile: profile),
        ],
      ),
    );
  }
}

class _HeaderButton extends StatelessWidget {
  const _HeaderButton({
    super.key,
    required this.tooltip,
    required this.icon,
    required this.onPressed,
    this.active = false,
  });

  final String tooltip;
  final IconData icon;
  final VoidCallback onPressed;
  final bool active;

  @override
  Widget build(BuildContext context) => IconButton(
    tooltip: tooltip,
    visualDensity: VisualDensity.compact,
    constraints: const BoxConstraints.tightFor(width: 40, height: 44),
    padding: EdgeInsets.zero,
    color: active ? L360Colors.forest700 : null,
    icon: Icon(icon),
    onPressed: () {
      HapticFeedback.selectionClick();
      onPressed();
    },
  );
}

class _AccountButton extends StatelessWidget {
  const _AccountButton({required this.profile});

  final AccountProfile? profile;

  @override
  Widget build(BuildContext context) {
    final p = profile;
    final name = p == null ? '' : (p.displayName.isEmpty ? p.email : p.displayName);
    return IconButton(
      key: const Key('account-button'),
      constraints: const BoxConstraints.tightFor(width: 44, height: 44),
      padding: EdgeInsets.zero,
      tooltip: p == null ? 'Sign in' : 'User Account',
      onPressed: () => context.push(p == null ? '/login' : '/account'),
      icon: p == null
          ? const Icon(Icons.account_circle_outlined)
          : CircleAvatar(
              radius: 14,
              backgroundColor: L360Colors.forest700,
              child: Text(
                name.isEmpty ? '?' : name.characters.first.toUpperCase(),
                style: const TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.w700),
              ),
            ),
    );
  }
}

class _SectionTabs extends StatelessWidget {
  const _SectionTabs({required this.value, required this.onChanged});

  final _Section value;
  final ValueChanged<_Section> onChanged;

  static const _items = [
    (_Section.tools, 'Tools', Icons.explore_outlined),
    (_Section.map, 'Map', Icons.layers_outlined),
    (_Section.terrain, 'Terrain', Icons.terrain_outlined),
  ];

  static const _duration = Duration(milliseconds: 220);

  // One white pill slides to the chosen tab (each tab fading its own in and out made the
  // bar blink while both were half visible)
  @override
  Widget build(BuildContext context) {
    final index = _items.indexWhere((i) => i.$1 == value);
    return Container(
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(color: L360Colors.sand100, borderRadius: BorderRadius.circular(12)),
      child: Stack(
        children: [
          Positioned.fill(
            child: AnimatedAlign(
              key: const Key('section-indicator'),
              duration: _duration,
              curve: Curves.easeOutCubic,
              alignment: Alignment(-1 + index * 1.0, 0),
              child: FractionallySizedBox(
                widthFactor: 1 / _items.length,
                heightFactor: 1,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(9),
                    boxShadow: const [BoxShadow(color: Color(0x1A000000), blurRadius: 4, offset: Offset(0, 1))],
                  ),
                ),
              ),
            ),
          ),
          Row(
            children: [
              for (final (section, label, icon) in _items)
                Expanded(
                  child: GestureDetector(
                    key: Key('section-${section.name}'),
                    behavior: HitTestBehavior.opaque,
                    // The chosen tab again still counts: closed, it opens the sheet
                    onTap: () {
                      if (section != value) HapticFeedback.selectionClick();
                      onChanged(section);
                    },
                    child: SizedBox(
                      height: 36,
                      child: TweenAnimationBuilder<double>(
                        duration: _duration,
                        tween: Tween(end: section == value ? 1 : 0),
                        builder: (context, t, _) {
                          final color = Color.lerp(L360Colors.sand600, L360Colors.forest800, t);
                          return Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Icon(icon, size: 16, color: Color.lerp(L360Colors.sand500, L360Colors.forest800, t)),
                              const SizedBox(width: 6),
                              Text(
                                label,
                                style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: color),
                              ),
                            ],
                          );
                        },
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

// --- Tools -----------------------------------------------------------------------------------

class _ToolsSection extends ConsumerWidget {
  const _ToolsSection();

  // Same tools, order and short names as the web's phone layout (ControlPanel.tsx)
  static const List<(IconData, String, int?)> tools = [
    (Icons.straighten, 'Navigator', null),
    (Icons.alt_route, 'Route', null),
    (Icons.place_outlined, 'POIs', null),
    (Icons.directions_walk, 'Track', null),
    (Icons.pin_drop_outlined, 'Marked', null),
    (Icons.hexagon_outlined, 'Areas', null),
    (Icons.layers_outlined, 'Basemaps', null),
  ];

  // One panel at a time: opening Route, Navigator or Track closes the others (a recording
  // keeps going with its panel closed)
  static void _toggleRoute(WidgetRef ref) {
    final planner = ref.read(routePlannerProvider.notifier);
    if (ref.read(routePlannerProvider).enabled) {
      planner.disable();
    } else {
      ref.read(navigatorProvider.notifier).close();
      ref.read(trackRecorderProvider.notifier).setPanelOpen(false);
      ref.read(areasProvider.notifier).setPanelOpen(false);
      planner.enable();
    }
  }

  static void _toggleNavigator(WidgetRef ref) {
    final nav = ref.read(navigatorProvider.notifier);
    if (ref.read(navigatorProvider).enabled) {
      nav.close();
    } else {
      ref.read(routePlannerProvider.notifier).disable();
      ref.read(trackRecorderProvider.notifier).setPanelOpen(false);
      ref.read(areasProvider.notifier).setPanelOpen(false);
      nav.open();
    }
  }

  // Any signed-in account opens it (own and shared tracks); recording needs Enterprise
  static void _toggleTrack(BuildContext context, WidgetRef ref) {
    if (ref.read(authUserIdProvider).value == null) {
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(const SnackBar(content: Text('Sign in to record and view tracks.')));
      return;
    }
    final rec = ref.read(trackRecorderProvider.notifier);
    if (ref.read(trackRecorderProvider).panelOpen) {
      rec.setPanelOpen(false);
    } else {
      ref.read(routePlannerProvider.notifier).disable();
      ref.read(navigatorProvider.notifier).close();
      ref.read(areasProvider.notifier).setPanelOpen(false);
      rec.setPanelOpen(true);
    }
  }

  // Any signed-in account; the plan sets how many locations and whether they can be shared
  static void _openMarked(BuildContext context, WidgetRef ref) {
    if (ref.read(authUserIdProvider).value == null) {
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(const SnackBar(content: Text('Sign in to save your own locations.')));
      return;
    }
    unawaited(showMarkedSheet(context, markedHost(ref)));
  }

  static void _openBasemaps(BuildContext context, WidgetRef ref) {
    if (ref.read(authUserIdProvider).value == null) {
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(const SnackBar(content: Text('Sign in to use your custom basemaps.')));
      return;
    }
    unawaited(showBasemapSheet(context));
  }

  static void _toggleAreas(BuildContext context, WidgetRef ref) {
    if (ref.read(authUserIdProvider).value == null) {
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(const SnackBar(content: Text('Sign in to draw and save areas.')));
      return;
    }
    final areas = ref.read(areasProvider.notifier);
    if (ref.read(areasProvider).panelOpen) {
      areas.setPanelOpen(false);
    } else {
      ref.read(routePlannerProvider.notifier).disable();
      ref.read(navigatorProvider.notifier).close();
      ref.read(trackRecorderProvider.notifier).setPanelOpen(false);
      areas.setPanelOpen(true);
    }
  }

  static const _columns = 4;
  static const _gap = 10.0;

  // Square tiles of one exact size (a quarter of the width less the gaps); a shorter last
  // row is centered so the grid has no hole on the right
  @override
  Widget build(BuildContext context, WidgetRef ref) => LayoutBuilder(
    builder: (context, constraints) {
      final side = ((constraints.maxWidth - _gap * (_columns - 1)) / _columns).floorToDouble();
      return Wrap(
        alignment: WrapAlignment.center,
        spacing: _gap,
        runSpacing: _gap,
        children: [
          for (final (icon, label, phase) in tools)
            SizedBox.square(
              dimension: side,
              child: ToolTile(
                icon: icon,
                label: label,
                availableInPhase: phase,
                active: switch (label) {
                  'Route' => ref.watch(routePlannerProvider.select((s) => s.enabled)),
                  'Navigator' => ref.watch(navigatorProvider.select((s) => s.enabled)),
                  'Track' => ref.watch(trackRecorderProvider.select((s) => s.panelOpen || s.active != null)),
                  'POIs' => ref.watch(mapSettingsProvider.select((s) => s.showPois)),
                  'Marked' => ref.watch(markedProvider.select((s) => s.picking)),
                  'Basemaps' => ref.watch(basemapsProvider.select((s) => s.basemaps.any((b) => b.active))),
                  'Areas' => ref.watch(areasProvider.select((s) => s.panelOpen || s.drawing || s.focusId != null)),
                  _ => false,
                },
                onTap: switch (label) {
                  'Route' => () => _toggleRoute(ref),
                  'Navigator' => () => _toggleNavigator(ref),
                  'Track' => () => _toggleTrack(context, ref),
                  'Marked' => () => _openMarked(context, ref),
                  'Areas' => () => _toggleAreas(context, ref),
                  'Basemaps' => () => _openBasemaps(context, ref),
                  // A map layer that stays on (remembered); switching it on lowers the sheet
                  'POIs' =>
                    () => ref.read(mapSettingsProvider.notifier).setShowPois(!ref.read(mapSettingsProvider).showPois),
                  _ => null,
                },
              ),
            ),
        ],
      );
    },
  );
}

/// A tool of the Tools section. Tools that are not in the app yet show "Soon".
class ToolTile extends StatelessWidget {
  const ToolTile({
    super.key,
    required this.icon,
    required this.label,
    this.availableInPhase,
    this.onTap,
    this.active = false,
  });

  final IconData icon;
  final String label;
  final int? availableInPhase; // set while the tool is not built yet
  final VoidCallback? onTap;
  final bool active; // the tool is switched on

  bool get enabled => availableInPhase == null && onTap != null;

  @override
  Widget build(BuildContext context) => Material(
    color: active ? L360Colors.forest50 : L360Colors.sand50,
    shape: RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(14),
      side: BorderSide(color: active ? L360Colors.forest200 : L360Colors.sand200),
    ),
    clipBehavior: Clip.antiAlias,
    child: InkWell(
      key: Key('tool-$label'),
      onTap: () {
        HapticFeedback.selectionClick();
        if (enabled) {
          onTap!();
        } else {
          ScaffoldMessenger.of(context)
            ..hideCurrentSnackBar()
            ..showSnackBar(SnackBar(content: Text('$label is coming to the app soon.')));
        }
      },
      child: Opacity(
        opacity: enabled ? 1 : 0.55,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Container(
                width: 34,
                height: 34,
                decoration: BoxDecoration(
                  color: active ? L360Colors.forest700 : L360Colors.sand100,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(icon, size: 19, color: active ? Colors.white : L360Colors.sand700),
              ),
              const SizedBox(height: 6),
              Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 11,
                  height: 1.2,
                  fontWeight: FontWeight.w700,
                  color: active ? L360Colors.ink : L360Colors.sand700,
                ),
              ),
              if (active)
                const Text(
                  'Active',
                  style: TextStyle(fontSize: 9, height: 1.2, fontWeight: FontWeight.w600, color: L360Colors.forest700),
                )
              else if (!enabled)
                const Text(
                  'Soon',
                  style: TextStyle(fontSize: 9, height: 1.2, fontWeight: FontWeight.w600, color: L360Colors.sand500),
                ),
            ],
          ),
        ),
      ),
    ),
  );
}

// --- Map -------------------------------------------------------------------------------------

class _MapSection extends ConsumerWidget {
  const _MapSection();

  static const _styleImages = {
    MapStyle.streets: 'assets/images/style_streets.png',
    MapStyle.outdoors: 'assets/images/style_outdoors.png',
    MapStyle.satellite: 'assets/images/style_satellite.png',
  };

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(mapSettingsProvider);
    final c = ref.read(mapSettingsProvider.notifier);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SectionLabel('Map Style'),
        Row(
          children: [
            // Same order as the web: Streets, Outdoors, Satellite
            for (final style in [MapStyle.streets, MapStyle.outdoors, MapStyle.satellite]) ...[
              if (style != MapStyle.streets) const SizedBox(width: 10),
              Expanded(
                child: _ImageChoice(
                  key: Key('style-${style.name}'),
                  image: _styleImages[style]!,
                  label: style.label,
                  height: 86,
                  selected: s.style == style,
                  onTap: () => c.setStyle(style),
                ),
              ),
            ],
          ],
        ),
        const SizedBox(height: 20),
        const SectionLabel('Map View'),
        Row(
          children: [
            Expanded(
              child: _ImageChoice(
                key: const Key('view-2d'),
                image: 'assets/images/view_2d.jpg',
                label: '2D Topo',
                height: 74,
                selected: !s.is3D,
                onTap: () => c.setView(MapView.twoD),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: _ImageChoice(
                key: const Key('view-3d'),
                image: 'assets/images/view_3d.jpg',
                label: '3D Terrain',
                height: 74,
                selected: s.is3D,
                onTap: () => c.setView(MapView.threeD),
              ),
            ),
          ],
        ),
        const SizedBox(height: 20),
        const SectionLabel('Offline'),
        Material(
          color: L360Colors.sand50,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
            side: const BorderSide(color: L360Colors.sand200),
          ),
          clipBehavior: Clip.antiAlias,
          child: ListTile(
            key: const Key('offline-maps'),
            leading: const Icon(Icons.download_for_offline_outlined, color: L360Colors.forest700),
            title: const Text('Offline maps', style: TextStyle(fontWeight: FontWeight.w700)),
            subtitle: Consumer(
              builder: (context, ref, _) {
                final o = ref.watch(offlineProvider);
                final running = o.progress.length;
                return Text(
                  running > 0
                      ? 'Downloading $running area${running == 1 ? '' : 's'}…'
                      : 'Use the map without signal: ${o.stored.length} area${o.stored.length == 1 ? '' : 's'} on this phone',
                );
              },
            ),
            trailing: const Icon(Icons.chevron_right, color: L360Colors.sand400),
            onTap: () {
              if (ref.read(authUserIdProvider).value == null) {
                ScaffoldMessenger.of(context)
                  ..hideCurrentSnackBar()
                  ..showSnackBar(const SnackBar(content: Text('Sign in to download offline maps.')));
                return;
              }
              unawaited(showOfflineSheet(context));
            },
          ),
        ),
      ],
    );
  }
}

class _ImageChoice extends StatelessWidget {
  const _ImageChoice({
    super.key,
    required this.image,
    required this.label,
    required this.height,
    required this.selected,
    required this.onTap,
  });

  final String image;
  final String label;
  final double height;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Semantics(
    selected: selected,
    button: true,
    label: label,
    child: GestureDetector(
      onTap: () {
        HapticFeedback.selectionClick();
        onTap();
      },
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        height: height,
        padding: const EdgeInsets.all(2.5),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: selected ? L360Colors.forest600 : Colors.transparent, width: 2),
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(10),
          child: Stack(
            fit: StackFit.expand,
            children: [
              Image.asset(image, fit: BoxFit.cover),
              const DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [Colors.transparent, Color(0xB3000000)],
                    stops: [0.45, 1],
                  ),
                ),
              ),
              Positioned(
                left: 8,
                right: 8,
                bottom: 6,
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        label,
                        style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.w700),
                      ),
                    ),
                    if (selected) const Icon(Icons.check_circle, size: 16, color: Colors.white),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

// --- Terrain ---------------------------------------------------------------------------------

class _TerrainSection extends ConsumerWidget {
  const _TerrainSection();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(mapSettingsProvider);
    final c = ref.read(mapSettingsProvider.notifier);
    // Like the web: contour and height controls work in 3D; the grid works in both views
    final terrainOn = s.is3D;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (!terrainOn) ...[
          Container(
            key: const Key('terrain-hint'),
            padding: const EdgeInsets.fromLTRB(12, 10, 4, 10),
            decoration: BoxDecoration(
              color: L360Colors.gold50,
              borderRadius: BorderRadius.circular(L360.radiusSmall),
              border: Border.all(color: L360Colors.gold100),
            ),
            child: Row(
              children: [
                const Icon(Icons.info_outline, size: 18, color: L360Colors.gold700),
                const SizedBox(width: 10),
                const Expanded(
                  child: Text(
                    'Contours work in 3D. Switch Map View to 3D Terrain to use them. The grid works in both.',
                    style: TextStyle(fontSize: 13, height: 1.35, color: L360Colors.gold700),
                  ),
                ),
                TextButton(onPressed: () => c.setView(MapView.threeD), child: const Text('3D Terrain')),
              ],
            ),
          ),
          const SizedBox(height: 16),
        ],
        const SectionLabel('Contours Config'),
        _ControlCard(
          enabled: terrainOn,
          children: [
            _SwitchRow(
              key: const Key('contours-toggle'),
              label: 'Contours',
              value: s.showContours,
              onChanged: terrainOn ? c.setShowContours : null,
            ),
            // Its settings show only while contours are on (like the grid's)
            if (s.showContours) ...[
              _SliderRow(
                label: 'Opacity Contours',
                valueLabel: '${(s.contourOpacity * 100).round()}%',
                value: s.contourOpacity,
                min: 0,
                max: 1,
                divisions: 100,
                onChanged: terrainOn && s.showContours ? c.setContourOpacity : null,
              ),
              _SliderRow(
                key: const Key('contour-interval'),
                label: 'Contour Interval',
                valueLabel: '${_trim(s.contourInterval)}m',
                value: s.contourInterval,
                min: minContourInterval,
                max: maxContourInterval,
                divisions: ((maxContourInterval - minContourInterval) / contourIntervalStep).round(),
                onChanged: terrainOn && s.showContours ? c.setContourInterval : null,
              ),
              _ChoiceRow<double>(
                options: [for (final v in contourIntervalPresets) (v, '${_trim(v)}m')],
                selected: s.contourInterval,
                onSelected: terrainOn && s.showContours ? c.setContourInterval : null,
              ),
            ],
            _SliderRow(
              key: const Key('exaggeration'),
              label: 'Exaggeration (Height)',
              valueLabel: '${s.exaggeration.toStringAsFixed(1)}x',
              value: s.exaggeration,
              min: minExaggeration,
              max: maxExaggeration,
              divisions: ((maxExaggeration - minExaggeration) * 10).round(),
              onChanged: terrainOn ? c.setExaggeration : null,
            ),
          ],
        ),
        const SizedBox(height: 20),
        const SectionLabel('Grid Config'),
        _ControlCard(
          children: [
            _SwitchRow(key: const Key('grid-toggle'), label: 'Grid DMS', value: s.showGrid, onChanged: c.setShowGrid),
            if (s.showGrid) ...[
              _SliderRow(
                label: 'Grid Opacity',
                valueLabel: '${(s.gridOpacity * 100).round()}%',
                value: s.gridOpacity,
                min: 0,
                max: 1,
                divisions: 20,
                onChanged: c.setGridOpacity,
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(14, 10, 14, 0),
                child: Text('Grid Interval', style: Theme.of(context).textTheme.bodyMedium),
              ),
              _ChoiceRow<double?>(
                options: [for (final (step, label, _) in gridStepOptions) (step, label)],
                selected: s.gridStep,
                onSelected: c.setGridStep,
              ),
            ],
          ],
        ),
      ],
    );
  }
}

String _trim(double v) => v == v.roundToDouble() ? v.toInt().toString() : v.toString();

/// White card holding a group of controls; dimmed when the group does not apply
class _ControlCard extends StatelessWidget {
  const _ControlCard({required this.children, this.enabled = true});

  final List<Widget> children;
  final bool enabled;

  @override
  Widget build(BuildContext context) => Opacity(
    opacity: enabled ? 1 : 0.5,
    child: Card(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: children),
      ),
    ),
  );
}

class _SwitchRow extends StatelessWidget {
  const _SwitchRow({super.key, required this.label, required this.value, required this.onChanged});

  final String label;
  final bool value;
  final ValueChanged<bool>? onChanged;

  void _toggle() {
    HapticFeedback.selectionClick();
    onChanged!(!value);
  }

  // The whole row toggles, not only the switch
  @override
  Widget build(BuildContext context) => InkWell(
    onTap: onChanged == null ? null : _toggle,
    child: Padding(
      padding: const EdgeInsets.fromLTRB(14, 0, 8, 0),
      child: Row(
        children: [
          Expanded(
            child: Text(label, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
          ),
          Switch.adaptive(
            value: value,
            activeTrackColor: L360Colors.forest700,
            onChanged: onChanged == null ? null : (_) => _toggle(),
          ),
        ],
      ),
    ),
  );
}

class _SliderRow extends StatelessWidget {
  const _SliderRow({
    super.key,
    required this.label,
    required this.valueLabel,
    required this.value,
    required this.min,
    required this.max,
    required this.divisions,
    required this.onChanged,
  });

  final String label;
  final String valueLabel;
  final double value;
  final double min;
  final double max;
  final int divisions;
  final ValueChanged<double>? onChanged;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(14, 10, 14, 0),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(child: Text(label, style: Theme.of(context).textTheme.bodyMedium)),
            Text(
              valueLabel,
              style: const TextStyle(
                fontWeight: FontWeight.w700,
                color: L360Colors.forest800,
                fontFeatures: [FontFeature.tabularFigures()],
              ),
            ),
          ],
        ),
        SliderTheme(
          data: SliderTheme.of(context)
              .copyWith(overlayShape: SliderComponentShape.noOverlay, tickMarkShape: SliderTickMarkShape.noTickMark),
          child: Slider(
            value: value.clamp(min, max),
            min: min,
            max: max,
            divisions: divisions,
            onChanged: onChanged == null
                ? null
                : (v) {
                    if (v != value) HapticFeedback.selectionClick();
                    onChanged!(v);
                  },
          ),
        ),
      ],
    ),
  );
}

class _ChoiceRow<T> extends StatelessWidget {
  const _ChoiceRow({required this.options, required this.selected, required this.onSelected});

  final List<(T, String)> options;
  final T selected;
  final ValueChanged<T>? onSelected;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(14, 6, 14, 8),
    child: Wrap(
      spacing: 6,
      runSpacing: 6,
      children: [
        for (final (value, label) in options)
          GestureDetector(
            onTap: onSelected == null
                ? null
                : () {
                    HapticFeedback.selectionClick();
                    onSelected!(value);
                  },
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 150),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
              decoration: BoxDecoration(
                color: value == selected ? L360Colors.forest800 : L360Colors.sand50,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: value == selected ? L360Colors.forest600 : L360Colors.sand200),
              ),
              child: Text(
                label,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: value == selected ? FontWeight.w700 : FontWeight.w500,
                  color: value == selected ? Colors.white : L360Colors.sand600,
                ),
              ),
            ),
          ),
      ],
    ),
  );
}

// --- Footer ----------------------------------------------------------------------------------

class _Footer extends StatelessWidget {
  const _Footer();

  static const _links = [
    ('Docs', '/docs'),
    ('Reviews', '/reviews'),
    ('FAQ', '/faq'),
    ('Terms', '/terms'),
    ('Privacy', '/privacy'),
  ];

  void _open(String url) => launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);

  @override
  Widget build(BuildContext context) {
    const small = TextStyle(fontSize: 11, color: L360Colors.sand500);
    const strong = TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: L360Colors.sand700);
    // Just enough room under the credits to clear the home indicator
    final bottom = (MediaQuery.paddingOf(context).bottom - 16).clamp(10.0, 40.0);
    return Padding(
      padding: EdgeInsets.fromLTRB(12, 16, 12, bottom),
      child: Column(
        children: [
          Wrap(
            alignment: WrapAlignment.center,
            children: [
              for (final (label, path) in _links)
                TextButton(
                  style: TextButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                    foregroundColor: L360Colors.sand600,
                    textStyle: const TextStyle(fontFamily: 'Inter', fontSize: 12, fontWeight: FontWeight.w500),
                  ),
                  onPressed: () => _open('$siteUrl$path'),
                  child: Text(label),
                ),
            ],
          ),
          const SizedBox(height: 4),
          Wrap(
            alignment: WrapAlignment.center,
            children: [
              const Text('Powered by ', style: small),
              GestureDetector(
                onTap: () => _open('https://instagram.com/jendelacakradigital'),
                child: const Text('Jendela Cakra Digital', style: strong),
              ),
              const Text(' · ', style: small),
              GestureDetector(
                onTap: () => _open('https://instagram.com/makopala_ubl'),
                child: const Text('Makopala Univ. Budi Luhur', style: strong),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
