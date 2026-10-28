import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/providers.dart';
import '../../core/theme/app_theme.dart';
import '../../core/ui/widgets.dart';
import '../../domain/account/profile.dart';
import '../../domain/map/map_settings.dart';
import '../../domain/share/share_location.dart';
import '../guide/quick_guide.dart';
import 'map_settings_controller.dart';

/// Same text as APP_SHARE_TEXT in src/components/AppShareButton.tsx (web)
const appShareText =
    'Landscape 360 · Explore without Limits\n'
    'Peta 3D & kontur, offline maps, GPS tracking dan S.O.S untuk penggiat alam terbuka.\n'
    '$siteUrl/';

/// Height of the sheet's always-visible part (grabber, header, section tabs) until it has
/// been measured, without the bottom safe area
const mapSheetPeekHeight = 140.0;

enum _Section { tools, map, terrain }

/// Bottom sheet like the mobile web: header (Guide, Share, account), Tools / Map / Terrain
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
        child: SingleChildScrollView(
          controller: widget.scrollController,
          // No bounce past the end: the sheet never shows empty space below its content
          physics: const ClampingScrollPhysics(),
          child: MeasureSize(
            onChange: (size) => widget.onContentHeight?.call(size.height),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                MeasureSize(
                  onChange: (size) => widget.onHeaderHeight?.call(size.height),
                  child: GestureDetector(
                    behavior: HitTestBehavior.translucent,
                    onVerticalDragUpdate: widget.onHandleDrag == null ? null : (d) => widget.onHandleDrag!(d.delta.dy),
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
                IgnorePointer(
                  ignoring: widget.bodyVisibility < 0.5,
                  child: Opacity(
                    opacity: widget.bodyVisibility,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        const Divider(),
                        Padding(
                          padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
                          child: AnimatedSize(
                            duration: const Duration(milliseconds: 200),
                            curve: Curves.easeOut,
                            alignment: Alignment.topCenter,
                            child: KeyedSubtree(
                              key: ValueKey(_section),
                              child: switch (_section) {
                                _Section.tools => const _ToolsSection(),
                                _Section.map => const _MapSection(),
                                _Section.terrain => const _TerrainSection(),
                              },
                            ),
                          ),
                        ),
                        const _Footer(),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
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
                Text(
                  'Landscape 360',
                  style: TextStyle(
                    fontSize: 17,
                    fontWeight: FontWeight.w700,
                    letterSpacing: -0.3,
                    color: L360Colors.forest800,
                  ),
                ),
                Text('Explore without Limits', style: TextStyle(fontSize: 12, color: L360Colors.sand500)),
              ],
            ),
          ),
          IconButton(
            key: const Key('guide'),
            tooltip: 'Quick Guide',
            icon: const Icon(Icons.help_outline),
            onPressed: () => showQuickGuide(context),
          ),
          Builder(
            builder: (btnContext) => IconButton(
              key: const Key('share-app'),
              tooltip: 'Share Landscape 360',
              icon: const Icon(Icons.ios_share),
              onPressed: () {
                final box = btnContext.findRenderObject() as RenderBox?;
                SharePlus.instance.share(
                  ShareParams(
                    text: appShareText,
                    subject: 'Landscape 360',
                    sharePositionOrigin: box == null ? null : box.localToGlobal(Offset.zero) & box.size,
                  ),
                );
              },
            ),
          ),
          _AccountButton(profile: profile),
        ],
      ),
    );
  }
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

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(3),
    decoration: BoxDecoration(color: L360Colors.sand100, borderRadius: BorderRadius.circular(12)),
    child: Row(
      children: [
        for (final (section, label, icon) in _items)
          Expanded(
            child: GestureDetector(
              key: Key('section-${section.name}'),
              behavior: HitTestBehavior.opaque,
              onTap: () {
                if (section == value) return;
                HapticFeedback.selectionClick();
                onChanged(section);
              },
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 180),
                height: 36,
                decoration: BoxDecoration(
                  color: section == value ? Colors.white : Colors.transparent,
                  borderRadius: BorderRadius.circular(9),
                  boxShadow: section == value
                      ? const [BoxShadow(color: Color(0x1A000000), blurRadius: 4, offset: Offset(0, 1))]
                      : null,
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(icon, size: 16, color: section == value ? L360Colors.forest800 : L360Colors.sand500),
                    const SizedBox(width: 6),
                    Text(
                      label,
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w700,
                        color: section == value ? L360Colors.forest800 : L360Colors.sand600,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
      ],
    ),
  );
}

// --- Tools -----------------------------------------------------------------------------------

class _ToolsSection extends StatelessWidget {
  const _ToolsSection();

  // Same tools, order and short names as the web's phone layout (ControlPanel.tsx)
  static const tools = [
    (Icons.straighten, 'Navigator', 5),
    (Icons.alt_route, 'Route', 4),
    (Icons.place_outlined, 'POIs', 7),
    (Icons.directions_walk, 'Track', 6),
    (Icons.pin_drop_outlined, 'Marked', 7),
    (Icons.hexagon_outlined, 'Areas', 7),
    (Icons.layers_outlined, 'Basemaps', 7),
  ];

  static const _columns = 4;
  static const _gap = 10.0;

  // Square tiles of one exact size (a quarter of the width less the gaps); a shorter last
  // row is centered so the grid has no hole on the right
  @override
  Widget build(BuildContext context) => LayoutBuilder(
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
              child: ToolTile(icon: icon, label: label, availableInPhase: phase),
            ),
        ],
      );
    },
  );
}

/// A tool of the Tools section. Tools that are not in the app yet show "Soon".
class ToolTile extends StatelessWidget {
  const ToolTile({super.key, required this.icon, required this.label, this.availableInPhase, this.onTap});

  final IconData icon;
  final String label;
  final int? availableInPhase; // set while the tool is not built yet
  final VoidCallback? onTap;

  bool get enabled => availableInPhase == null && onTap != null;

  @override
  Widget build(BuildContext context) => Material(
    color: L360Colors.sand50,
    shape: RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(14),
      side: const BorderSide(color: L360Colors.sand200),
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
                decoration: BoxDecoration(color: L360Colors.sand100, borderRadius: BorderRadius.circular(10)),
                child: Icon(icon, size: 19, color: L360Colors.sand700),
              ),
              const SizedBox(height: 6),
              Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: 11,
                  height: 1.2,
                  fontWeight: FontWeight.w700,
                  color: L360Colors.sand700,
                ),
              ),
              if (!enabled)
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
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (!s.is3D) ...[
          // Like the web's terrain hint: terrain controls work in the 3D view
          Container(
            padding: const EdgeInsets.all(12),
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
                    'Terrain works in 3D. Switch Map View to 3D Terrain.',
                    style: TextStyle(fontSize: 13, color: L360Colors.gold700),
                  ),
                ),
                TextButton(onPressed: () => c.setView(MapView.threeD), child: const Text('Switch')),
              ],
            ),
          ),
          const SizedBox(height: 16),
        ],
        SectionLabel(
          'Exaggeration (Height)',
          trailing: Text(
            '${s.exaggeration.toStringAsFixed(1)}×',
            style: const TextStyle(fontWeight: FontWeight.w700, color: L360Colors.forest800),
          ),
        ),
        Card(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(8, 4, 8, 4),
            child: Row(
              children: [
                const Text('1×', style: TextStyle(fontSize: 12, color: L360Colors.sand500)),
                Expanded(
                  child: Slider(
                    key: const Key('exaggeration'),
                    value: s.exaggeration,
                    min: minExaggeration,
                    max: maxExaggeration,
                    divisions: 20,
                    onChanged: (v) {
                      if (v != s.exaggeration) HapticFeedback.selectionClick();
                      c.setExaggeration(v);
                    },
                  ),
                ),
                const Text('3×', style: TextStyle(fontSize: 12, color: L360Colors.sand500)),
              ],
            ),
          ),
        ),
      ],
    );
  }
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
