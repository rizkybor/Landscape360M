import 'dart:convert';

import 'package:http/http.dart' as http;

// Calls to the web app's Vercel Functions (/api/*), port of src/lib/authFetch.ts and the
// request() helper of src/lib/accountRequests.ts.

const sessionEndedMessage = 'Your session has ended. Please sign out and sign in again.';

class ApiException implements Exception {
  const ApiException(this.message, {this.status});

  final String message;
  final int? status;

  @override
  String toString() => message;
}

class SessionEndedException extends ApiException {
  const SessionEndedException() : super(sessionEndedMessage, status: 401);
}

/// Where the signed-in user's access token comes from (Supabase auth in the app)
abstract interface class SessionSource {
  /// Current access token, or null when signed out
  String? get accessToken;

  /// Refreshes the session; returns the new access token, or null when it cannot be refreshed
  Future<String?> refresh();
}

class ApiClient {
  ApiClient({required this.baseUrl, required this.session, http.Client? client}) : _client = client ?? http.Client();

  final String baseUrl;
  final SessionSource session;
  final http.Client _client;

  static const _timeout = Duration(seconds: 20);

  Uri _uri(String path) => Uri.parse('$baseUrl$path');

  Future<http.Response> _send(String method, String path, Object? body, Map<String, String> headers) {
    final request = http.Request(method, _uri(path))..headers.addAll(headers);
    if (body != null) {
      request.headers['Content-Type'] = 'application/json';
      request.body = jsonEncode(body);
    }
    return _client.send(request).then(http.Response.fromStream).timeout(_timeout);
  }

  /// Request with the user's access token. On a 401 the session is refreshed once and the
  /// request retried (the token can be refused although it looks valid: ended elsewhere,
  /// password changed, the phone slept past its expiry, a wrong clock).
  Future<http.Response> authed(String method, String path, {Object? body}) async {
    final token = session.accessToken;
    if (token == null) throw const ApiException('Not signed in');

    final res = await _send(method, path, body, {'Authorization': 'Bearer $token'});
    if (res.statusCode != 401) return res;

    final fresh = await session.refresh();
    if (fresh == null) throw const SessionEndedException();
    final retry = await _send(method, path, body, {'Authorization': 'Bearer $fresh'});
    if (retry.statusCode == 401) throw const SessionEndedException();
    return retry;
  }

  /// Request without a token (public endpoints such as the account request form)
  Future<http.Response> public(String method, String path, {Object? body}) => _send(method, path, body, const {});

  /// JSON body of a response, or an [ApiException] with the server's `error` text
  static Map<String, dynamic> decode(http.Response res) {
    Object? payload;
    try {
      payload = jsonDecode(res.body);
    } on FormatException {
      payload = null;
    }
    if (res.statusCode < 200 || res.statusCode >= 300) {
      final error = payload is Map ? payload['error'] : null;
      throw ApiException(
        error is String && error.isNotEmpty ? error : 'Request failed (${res.statusCode})',
        status: res.statusCode,
      );
    }
    if (payload is! Map<String, dynamic>) {
      throw const ApiException('The Landscape 360 server answered unexpectedly. Try again later.');
    }
    return payload;
  }
}
