import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:landscape360/core/config/app_config.dart';

String _jwt(Map<String, dynamic> payload) {
  String part(Object o) => base64Url.encode(utf8.encode(jsonEncode(o))).replaceAll('=', '');
  return '${part({'alg': 'HS256', 'typ': 'JWT'})}.${part(payload)}.signature';
}

AppConfig _config({
  String flavor = 'dev',
  String url = 'https://abc.supabase.co',
  String? key,
  String mapbox = 'pk.abc',
  String api = 'https://landscape360.jcdigital.co.id',
}) => AppConfig(
  flavor: flavor,
  supabaseUrl: url,
  supabaseAnonKey: key ?? _jwt({'role': 'anon', 'iss': 'supabase'}),
  mapboxPublicToken: mapbox,
  apiBaseUrl: api,
);

void main() {
  test('accepts a public configuration', () {
    expect(_config().problems(), isEmpty);
    expect(_config(key: 'sb_publishable_abc123').problems(), isEmpty);
  });

  test('refuses the Supabase service role key and secret keys', () {
    expect(_config(key: _jwt({'role': 'service_role'})).problems(), [contains('service role')]);
    expect(_config(key: 'sb_secret_abc').problems(), [contains('service role')]);
    expect(_config(key: 'not-a-key').problems(), [contains('service role')]);
    expect(_config(key: '').problems(), [contains('missing')]);
  });

  test('refuses a Mapbox secret token', () {
    expect(_config(mapbox: 'sk.secret').problems(), [contains('secret token')]);
    expect(_config(mapbox: 'xyz').problems(), [contains('public token')]);
  });

  test('requires https endpoints and a known flavor', () {
    expect(_config(url: 'http://abc.supabase.co').problems(), [contains('SUPABASE_URL')]);
    expect(_config(api: 'http://localhost:3000').problems(), [contains('API_BASE_URL')]);
    expect(_config(flavor: 'staging').problems(), [contains('FLAVOR')]);
  });
}
