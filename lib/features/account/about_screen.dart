import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/providers.dart';
import '../../core/theme/app_theme.dart';
import '../../core/ui/widgets.dart';

// About the app: version, the legal pages on the website (privacy, terms, account
// deletion), reviews, FAQ and support. Open to everyone, signed in or not.

const supportEmail = 'contact@jcdigital.co.id';

final appVersionProvider = FutureProvider<String>((ref) async {
  final info = await PackageInfo.fromPlatform();
  // The same number as the website (package.json there); the build number is for the stores
  // (without the dev build's "-dev")
  return info.version.split('-').first;
});

class AboutScreen extends ConsumerWidget {
  const AboutScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final site = ref.watch(appConfigProvider).apiBaseUrl;
    final version = ref.watch(appVersionProvider).value;
    final isAdmin = ref.watch(profileProvider.select((p) => p.value?.isAdmin ?? false));
    Widget link(Key key, IconData icon, String title, String path) => ListTile(
      key: key,
      leading: TileIcon(icon),
      title: Text(title),
      trailing: const Icon(Icons.open_in_new, size: 18, color: L360Colors.sand400),
      onTap: () => launchUrl(Uri.parse('$site$path'), mode: LaunchMode.externalApplication),
    );
    return Scaffold(
      appBar: AppBar(title: const Text('About')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(L360.gutter, 8, L360.gutter, 32),
        children: [
          Center(child: Image.asset('assets/images/logo.png', width: 72, height: 72)),
          const SizedBox(height: 10),
          const BrandName(textAlign: TextAlign.center),
          const SizedBox(height: 4),
          Text(
            version == null ? 'Explore without Limits' : 'Version $version',
            key: const Key('about-version'),
            textAlign: TextAlign.center,
            style: const TextStyle(color: L360Colors.sand500),
          ),
          const SizedBox(height: 16),
          const _AvailableOn(),
          const SizedBox(height: 24),
          GroupedSection(
            title: 'Help',
            children: [
              link(const Key('about-docs'), Icons.menu_book_outlined, 'User guide', '/docs'),
              link(const Key('about-faq'), Icons.help_outline, 'FAQ', '/faq'),
              link(const Key('about-reviews'), Icons.star_outline, 'Reviews', '/reviews'),
              ListTile(
                key: const Key('about-support'),
                leading: const TileIcon(Icons.mail_outline),
                title: const Text('Contact support'),
                subtitle: const Text(supportEmail),
                onTap: () => launchUrl(Uri(scheme: 'mailto', path: supportEmail, query: 'subject=Landscape 360 app')),
              ),
            ],
          ),
          GroupedSection(
            title: 'Legal',
            children: [
              link(const Key('about-privacy'), Icons.shield_outlined, 'Privacy Policy', '/privacy'),
              link(const Key('about-terms'), Icons.description_outlined, 'Terms of Service', '/terms'),
              // The admin account cannot be deleted (one admin runs the service)
              if (!isAdmin)
                link(
                  const Key('about-delete'),
                  Icons.person_remove_outlined,
                  'Deleting your account',
                  '/delete-account',
                ),
            ],
          ),
          const Padding(
            padding: EdgeInsets.only(top: 8),
            child: Text(
              '© Jendela Cakra Digital. Map data © Mapbox © OpenStreetMap contributors. Weather by BMKG.',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 12, color: L360Colors.sand500),
            ),
          ),
        ],
      ),
    );
  }
}

/// "Available on" with the two store badges (black, like the stores' own)
class _AvailableOn extends StatelessWidget {
  const _AvailableOn();

  @override
  Widget build(BuildContext context) => const Column(
    key: Key('about-stores'),
    children: [
      Text(
        'AVAILABLE ON',
        style: TextStyle(fontSize: 10, letterSpacing: 1.2, fontWeight: FontWeight.w600, color: L360Colors.sand500),
      ),
      SizedBox(height: 8),
      Wrap(
        alignment: WrapAlignment.center,
        spacing: 10,
        runSpacing: 8,
        children: [
          _StoreBadge(icon: _PlayLogo(), small: 'GET IT ON', name: 'Google Play'),
          _StoreBadge(
            icon: Icon(Icons.apple, color: Colors.white, size: 22),
            small: 'Download on the',
            name: 'App Store',
          ),
        ],
      ),
    ],
  );
}

class _StoreBadge extends StatelessWidget {
  const _StoreBadge({required this.icon, required this.small, required this.name});

  final Widget icon;
  final String small;
  final String name;

  @override
  // A logo, like the stores' own badges: its text does not grow with the system text size
  Widget build(BuildContext context) => MediaQuery.withNoTextScaling(child: _badge());

  Widget _badge() => Container(
    height: 40,
    padding: const EdgeInsets.fromLTRB(10, 4, 14, 4),
    decoration: BoxDecoration(
      color: Colors.black,
      borderRadius: BorderRadius.circular(8),
      border: Border.all(color: const Color(0xFFA6A6A6), width: 0.8),
    ),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox.square(dimension: 22, child: Center(child: icon)),
        const SizedBox(width: 8),
        Column(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(small, style: const TextStyle(fontSize: 8.5, height: 1.1, color: Colors.white)),
            Text(
              name,
              style: const TextStyle(fontSize: 15, height: 1.1, fontWeight: FontWeight.w600, color: Colors.white),
            ),
          ],
        ),
      ],
    ),
  );
}

/// The Google Play triangle in its four colours
class _PlayLogo extends StatelessWidget {
  const _PlayLogo();

  @override
  Widget build(BuildContext context) => const CustomPaint(size: Size(18, 20), painter: _PlayPainter());
}

class _PlayPainter extends CustomPainter {
  const _PlayPainter();

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width, h = size.height;
    final mid = Offset(w * 0.62, h / 2);
    void tri(List<Offset> p, Color c) => canvas.drawPath(
      Path()
        ..moveTo(p[0].dx, p[0].dy)
        ..lineTo(p[1].dx, p[1].dy)
        ..lineTo(p[2].dx, p[2].dy)
        ..close(),
      Paint()..color = c,
    );
    tri([Offset.zero, mid, Offset(0, h)], const Color(0xFF00D7FE)); // left
    tri([Offset.zero, Offset(w * 0.78, h * 0.31), mid], const Color(0xFF32DD6B)); // top
    tri([Offset(0, h), mid, Offset(w * 0.78, h * 0.69)], const Color(0xFFF83B49)); // bottom
    tri([Offset(w * 0.78, h * 0.31), Offset(w, h / 2), Offset(w * 0.78, h * 0.69)], const Color(0xFFFFC92B));
    tri([Offset(w * 0.78, h * 0.31), Offset(w * 0.78, h * 0.69), mid], const Color(0xFFFFC92B)); // right
  }

  @override
  bool shouldRepaint(_PlayPainter old) => false;
}
