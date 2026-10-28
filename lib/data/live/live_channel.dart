import 'dart:async';

import 'package:supabase_flutter/supabase_flutter.dart';

// The private Realtime channels of live tracking (docs/backend/live-tracking): positions go
// to 'tracking-room' through the REST broadcast endpoint, so the member never joins it and
// never hears the others; monitors ask for positions on 'tracking-heartbeat'. The server
// checks the account on every message (realtime.messages policies).

/// The server refused the account (not allowed to share, or the channels are not set up)
class LiveNotAllowedException implements Exception {
  const LiveNotAllowedException(this.message);
  final String message;

  @override
  String toString() => message;
}

abstract interface class LiveChannel {
  /// Calls [onAsk] whenever a monitor asks for positions, until [close]
  void listen(void Function() onAsk);

  Future<void> send(Map<String, dynamic> packet);

  Future<void> close();
}

class SupabaseLiveChannel implements LiveChannel {
  SupabaseLiveChannel(this.client);

  final SupabaseClient client;
  RealtimeChannel? _room;
  RealtimeChannel? _ask;

  static const _private = RealtimeChannelConfig(private: true);

  @override
  void listen(void Function() onAsk) {
    if (_ask != null) return;
    _ask = client.channel('tracking-heartbeat', opts: _private)
      ..onBroadcast(event: 'heartbeat-request', callback: (_) => onAsk())
      ..subscribe();
  }

  @override
  Future<void> send(Map<String, dynamic> packet) async {
    await _freshToken();
    final room = _room ??= client.channel('tracking-room', opts: _private);
    try {
      await room.httpSend(event: 'location-update', payload: packet, timeout: const Duration(seconds: 10));
    } on TimeoutException {
      rethrow;
    } on Exception catch (e) {
      final m = '$e';
      if (RegExp('unauthori|forbidden|not allowed|permission|denied|rls', caseSensitive: false).hasMatch(m)) {
        throw LiveNotAllowedException(m);
      }
      rethrow;
    }
  }

  // The session is not refreshed while the app is in the background; positions keep going
  // with the screen off, so renew it here before it runs out
  Future<void> _freshToken() async {
    final s = client.auth.currentSession;
    if (s == null) throw const LiveNotAllowedException('Signed out');
    final expires = s.expiresAt;
    if (expires == null || expires * 1000 - DateTime.now().millisecondsSinceEpoch > 60000) return;
    final renewed = (await client.auth.refreshSession()).session;
    if (renewed != null) await client.realtime.setAuth(renewed.accessToken);
  }

  @override
  Future<void> close() async {
    for (final c in [_room, _ask]) {
      if (c != null) await client.removeChannel(c);
    }
    _room = null;
    _ask = null;
  }
}
