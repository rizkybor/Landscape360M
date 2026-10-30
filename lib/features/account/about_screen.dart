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
