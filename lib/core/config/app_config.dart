import 'dart:convert';

// Build-time configuration, passed with --dart-define-from-file=config/<flavor>.json
// (see config/*.json.example). Only public values belong here: the Supabase anon /
// publishable key and the Mapbox public token. A secret that slips in makes the app refuse
// to start instead of shipping it to every phone.

class AppConfig {
  const AppConfig({
    required this.flavor,
    required this.supabaseUrl,
    required this.supabaseAnonKey,
    required this.mapboxPublicToken,
    required this.apiBaseUrl,
  });

  factory AppConfig.fromEnvironment() => AppConfig(
    flavor: const String.fromEnvironment('FLAVOR', defaultValue: 'dev'),
    supabaseUrl: const String.fromEnvironment('SUPABASE_URL'),
    supabaseAnonKey: const String.fromEnvironment('SUPABASE_ANON_KEY'),
    mapboxPublicToken: const String.fromEnvironment('MAPBOX_PUBLIC_TOKEN'),
    apiBaseUrl: const String.fromEnvironment('API_BASE_URL', defaultValue: 'https://landscape360.jcdigital.co.id'),
  );

  final String flavor; // dev | prod
  final String supabaseUrl;
  final String supabaseAnonKey;
  final String mapboxPublicToken;
  final String apiBaseUrl; // site with the Vercel Functions (/api/*)

  bool get isProd => flavor == 'prod';

  /// Every problem with the configuration; empty when it can be used
  List<String> problems() {
    final p = <String>[];
    if (flavor != 'dev' && flavor != 'prod') p.add('FLAVOR must be dev or prod');
    if (!_isHttpsUrl(supabaseUrl)) p.add('SUPABASE_URL must be an https URL');
    if (supabaseAnonKey.isEmpty) {
      p.add('SUPABASE_ANON_KEY is missing');
    } else if (!isPublicSupabaseKey(supabaseAnonKey)) {
      p.add('SUPABASE_ANON_KEY is not an anon / publishable key. Never put the service role key in the app.');
    }
    if (mapboxPublicToken.startsWith('sk.')) {
      p.add('MAPBOX_PUBLIC_TOKEN is a secret token (sk.). Use a public token (pk.).');
    } else if (mapboxPublicToken.isNotEmpty && !mapboxPublicToken.startsWith('pk.')) {
      p.add('MAPBOX_PUBLIC_TOKEN must be a public token (pk.)');
    }
    if (!_isHttpsUrl(apiBaseUrl)) p.add('API_BASE_URL must be an https URL');
    return p;
  }

  static bool _isHttpsUrl(String value) {
    final uri = Uri.tryParse(value);
    return uri != null && uri.scheme == 'https' && uri.host.isNotEmpty;
  }
}

/// True for a key that is safe to ship: a legacy JWT whose role is "anon", or a new-style
/// "sb_publishable_" key. False for the service role JWT and "sb_secret_" keys.
bool isPublicSupabaseKey(String key) {
  if (key.startsWith('sb_publishable_')) return true;
  if (key.startsWith('sb_secret_')) return false;
  final parts = key.split('.');
  if (parts.length != 3) return false;
  try {
    final payload = jsonDecode(utf8.decode(base64Url.decode(base64Url.normalize(parts[1]))));
    return payload is Map && payload['role'] == 'anon';
  } on FormatException {
    return false;
  }
}
