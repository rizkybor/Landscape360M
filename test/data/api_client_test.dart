import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:landscape360/data/api/api_client.dart';

// Same cases as src/lib/authFetch.test.ts (web)

class FakeSession implements SessionSource {
  FakeSession(this.accessToken, {this.refreshed});

  @override
  String? accessToken;
  final String? refreshed;
  int refreshCalls = 0;

  @override
  Future<String?> refresh() async {
    refreshCalls++;
    return refreshed;
  }
}

void main() {
  late List<http.Request> requests;
  late List<int> statuses;

  ApiClient client(FakeSession session) => ApiClient(
    baseUrl: 'https://landscape360.jcdigital.co.id',
    session: session,
    client: MockClient((req) async {
      requests.add(req);
      final status = statuses.length > 1 ? statuses.removeAt(0) : statuses.first;
      return http.Response('{"ok":true}', status);
    }),
  );

  setUp(() {
    requests = [];
    statuses = [200];
  });

  test('sends the access token', () async {
    final session = FakeSession('old');
    final res = await client(session).authed('GET', '/api/x');
    expect(res.statusCode, 200);
    expect(requests.single.headers['Authorization'], 'Bearer old');
    expect(requests.single.url.toString(), 'https://landscape360.jcdigital.co.id/api/x');
    expect(session.refreshCalls, 0);
  });

  test('refreshes an ended session once and retries', () async {
    statuses = [401, 200];
    final session = FakeSession('old', refreshed: 'new');
    expect((await client(session).authed('POST', '/api/x', body: {'a': 1})).statusCode, 200);
    expect(requests[1].headers['Authorization'], 'Bearer new');
    expect(requests[1].body, '{"a":1}');
    expect(session.refreshCalls, 1);
  });

  test('asks to sign in again when the session cannot be refreshed', () async {
    statuses = [401];
    await expectLater(client(FakeSession('old')).authed('GET', '/api/x'), throwsA(isA<SessionEndedException>()));
  });

  test('asks to sign in again when the refreshed token is refused too', () async {
    statuses = [401];
    final session = FakeSession('old', refreshed: 'new');
    await expectLater(client(session).authed('GET', '/api/x'), throwsA(isA<SessionEndedException>()));
    expect(session.refreshCalls, 1); // never loops
  });

  test('does not refresh for other errors', () async {
    statuses = [403];
    final session = FakeSession('old');
    expect((await client(session).authed('GET', '/api/x')).statusCode, 403);
    expect(session.refreshCalls, 0);
  });

  test('refuses to call without a session and sends no token on public calls', () async {
    await expectLater(client(FakeSession(null)).authed('GET', '/api/x'), throwsA(isA<ApiException>()));
    expect(requests, isEmpty);
    await client(FakeSession('secret')).public('POST', '/api/account-requests', body: {});
    expect(requests.single.headers.containsKey('Authorization'), isFalse);
  });

  test('decode returns JSON, and the server error text on failure', () {
    expect(ApiClient.decode(http.Response('{"ok":true}', 201)), {'ok': true});
    expect(
      () => ApiClient.decode(http.Response('{"error":"A valid email is required"}', 400)),
      throwsA(isA<ApiException>().having((e) => e.message, 'message', 'A valid email is required')),
    );
    expect(
      () => ApiClient.decode(http.Response('<html>', 500)),
      throwsA(isA<ApiException>().having((e) => e.message, 'message', 'Request failed (500)')),
    );
    expect(() => ApiClient.decode(http.Response('<html>', 200)), throwsA(isA<ApiException>()));
  });
}
