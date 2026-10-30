import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../core/theme/app_theme.dart';

// Quick Start Guide, same entries as GetStartedModal in src/components/ControlPanel.tsx (web)

const _entries = <(IconData, String, String)>[
  (
    Icons.touch_app_outlined,
    'Interaction Modes',
    'One finger pans, pinch zooms, twist rotates, two-finger drag tilts in 3D.',
  ),
  (Icons.show_chart, 'Terrain Analysis', 'Toggle contours and adjust exaggeration to visualize elevation details.'),
  (
    Icons.download_outlined,
    'Export & Capture',
    'Export the current map as an A4 report: your survey lines and points, marked locations in view, the point '
        'table with distances, and the elevation profile. Long reports get more pages (PNG/JPG as a ZIP).\n'
        '• PNG: sharpest, largest file.\n• JPG: small file, best for sharing on chat.\n'
        '• PDF: small, ready to print or attach',
  ),
  (
    Icons.straighten,
    'Survey Tools',
    'Enter Navigator Mode to plot points with straight lines, curves or sharp corners, and read distance, '
        'azimuth / back azimuth and slope for every segment.',
  ),
  (
    Icons.wifi_off_outlined,
    'Offline Maps [All Accounts]',
    'Download map areas to use without signal on the trail: Free 1 map (1 MB), Pro 3 maps (10 MB each), '
        'Enterprise 10 maps (25 MB each).',
  ),
  (
    Icons.navigation_outlined,
    'GPS Tracking & Monitoring [Pro & Enterprise]',
    'Broadcast your location; Pro accounts can also record activities as GPX. Enterprise Monitor accounts follow '
        'every active member live. Reconnects by itself after signal loss.',
  ),
  (
    Icons.layers_outlined,
    'Custom Basemaps [Enterprise Account]',
    'Upload your own GeoTIFF or PDF maps as overlays with adjustable opacity. A GeoTIFF is placed from its own '
        'coordinates; a PDF is placed by typing its edges or with Pick on Map. Every Enterprise account (5 MB of maps).',
  ),
  (
    Icons.pin_drop_outlined,
    'Marked Locations [All Accounts]',
    'Save camps, water sources, summits and more with full details, pick them on the map, and export as GPX. Share '
        'one or several locations with other users: pick someone you shared with before, or type part of their name '
        'or email and tap them. Or create a link for WhatsApp that anyone can open without signing in.',
  ),
  (
    Icons.hexagon_outlined,
    'Marked Areas [All Accounts]',
    'Draw an area on the map by tapping its corners (a camp ground, a route zone, a search sector) and see its size '
        'and perimeter. Focus on an area to darken the rest of the map, and share it as a WhatsApp link that opens in '
        'focus view without signing in. Free 5 areas, Pro 10, Enterprise 20; links on Pro and Enterprise.',
  ),
  (
    Icons.share_outlined,
    'Share Location',
    'Tap the share button on the right of the map to send where you are now to WhatsApp or another app, with '
        'coordinates, elevation and a link that opens the spot on the map.',
  ),
  (
    Icons.directions_walk,
    'Track Recorder [Enterprise Account]',
    'Record personal GPS tracks online or offline with distance, duration and elevation. Share tracks by email and '
        'export GPX. Every signed-in account can view its own and shared tracks; Pro and Enterprise accounts can '
        'rename their cloud tracks.',
  ),
  (
    Icons.cloud_outlined,
    'Cloud Storage',
    "Tracks, marked locations, surveys and custom basemaps share your account's storage: Free 10 MB, Pro 100 MB, "
        'Enterprise 1 GB. Check your usage in the User Account menu; contact us if you need more space.',
  ),
  (
    Icons.sos_outlined,
    'S.O.S [Allowed by the Admin]',
    'Accounts the admin allows get a red S.O.S button on the map (hold 3 seconds). It shows your GPS position, '
        'calls 112 / Basarnas 115, sends an SMS with your location to your emergency contacts, and reports your '
        'message, location and battery to the admin.',
  ),
  (
    Icons.architecture,
    'Classic: Resection & Intersection',
    'Tools > Classic: practise map-and-compass navigation. Type positions in degrees, minutes and seconds and '
        'bearings in compass degrees; each line is drawn on the map, and in an intersection X marks where the object '
        'most likely is. Keep several Field Works and share one as a link.',
  ),
  (
    Icons.navigation_outlined,
    'GPS Tracking [Pro & Enterprise]',
    'Tools > GPS shares your live position with your team\'s monitors, also with the screen off. Monitor accounts '
        'follow every active member on the website.',
  ),
  (
    Icons.person_add_alt,
    'Request an Account',
    'No account yet? Open Sign In, choose Request Account and fill in the form. We will email your login details '
        'after approval.',
  ),
];

Future<void> showQuickGuide(BuildContext context) => showModalBottomSheet<void>(
  context: context,
  isScrollControlled: true,
  useSafeArea: true,
  builder: (_) => DraggableScrollableSheet(
    expand: false,
    initialChildSize: 0.85,
    maxChildSize: 0.95,
    builder: (context, controller) => ListView(
      controller: controller,
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 32),
      children: [
        const Text(
          'INITIALIZATION',
          style: TextStyle(fontSize: 11, letterSpacing: 2, fontWeight: FontWeight.w700, color: L360Colors.forest600),
        ),
        const SizedBox(height: 4),
        Text('Quick Start Guide', style: Theme.of(context).textTheme.headlineSmall),
        const SizedBox(height: 16),
        for (final (icon, title, desc) in _entries)
          Padding(
            padding: const EdgeInsets.only(bottom: 18),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  width: 36,
                  height: 36,
                  decoration: BoxDecoration(color: L360Colors.forest50, borderRadius: BorderRadius.circular(10)),
                  child: Icon(icon, size: 19, color: L360Colors.forest700),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(title, style: Theme.of(context).textTheme.titleSmall),
                      const SizedBox(height: 3),
                      Text(desc, style: const TextStyle(fontSize: 13, height: 1.45, color: L360Colors.sand700)),
                    ],
                  ),
                ),
              ],
            ),
          ),
        Center(
          child: TextButton.icon(
            key: const Key('guide-about'),
            onPressed: () {
              // Taken before the sheet closes and its context goes away
              final router = GoRouter.of(context);
              Navigator.pop(context);
              router.push('/about');
            },
            icon: const Icon(Icons.info_outline, size: 18),
            label: const Text('About, privacy and support'),
          ),
        ),
      ],
    ),
  ),
);
