import 'dart:async';
import 'dart:convert';

import '../util/js_compat.dart';
import 'sos.dart';

// Port of the outbox in src/lib/sosAlerts.ts: the phone keeps the latest report of each
// S.O.S until the server has it, so alerts raised without signal are sent as soon as the
// connection is back. Storage and sending are injected, so the app can back them with a
// persistent store and Supabase, and tests with fakes.

enum SosStatus { active, resolved }

class SosReport {
  const SosReport({
    required this.clientId,
    required this.startedAt,
    required this.status,
    required this.message,
    required this.fix,
    required this.battery,
  });

  factory SosReport.fromJson(Map<String, dynamic> j) => SosReport(
    clientId: j['clientId'] as String,
    startedAt: j['startedAt'] as String,
    status: j['status'] == 'resolved' ? SosStatus.resolved : SosStatus.active,
    message: j['message'] as String? ?? '',
    fix: j['fix'] == null ? null : SosFix.fromJson(j['fix'] as Map<String, dynamic>),
    battery: (j['battery'] as num?)?.toInt(),
  );

  final String clientId; // one per S.O.S, made on the phone (UUID)
  final String startedAt; // ISO
  final SosStatus status;
  final String message;
  final SosFix? fix;
  final int? battery;

  Map<String, dynamic> toJson() => {
    'clientId': clientId,
    'startedAt': startedAt,
    'status': status.name,
    'message': message,
    'fix': fix?.toJson(),
    'battery': battery,
  };

  /// Arguments of the sos_report RPC (20261024000015_sos_alerts.sql)
  Map<String, dynamic> toRpcParams() {
    final trimmed = message.trim();
    return {
      'p_client_id': clientId,
      'p_started_at': startedAt,
      'p_status': status.name,
      'p_message': trimmed.isEmpty ? null : trimmed,
      'p_lat': fix?.lat,
      'p_lng': fix?.lng,
      'p_accuracy': fix?.accuracy,
      'p_elevation': fix?.elevation,
      'p_battery': battery,
      'p_located_at': fix == null ? null : isoString(fix!.time),
    };
  }
}

/// Key-value storage that survives the app being closed (e.g. shared_preferences)
abstract interface class OutboxStorage {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
}

/// Sends one report; throws when the server did not take it
typedef SosSender = Future<void> Function(SosReport report);

const sosOutboxKey = 'l360-sos-outbox';

class SosOutbox {
  SosOutbox({required this.storage, required this.send});

  final OutboxStorage storage;
  final SosSender send;
  Future<bool>? _flushing;

  Future<Map<String, Map<String, dynamic>>> _read() async {
    try {
      final raw = jsonDecode(await storage.read(sosOutboxKey) ?? '{}');
      if (raw is! Map<String, dynamic>) return {};
      return {
        for (final e in raw.entries)
          if (e.value is Map<String, dynamic>) e.key: e.value as Map<String, dynamic>,
      };
    } on FormatException {
      return {};
    }
  }

  Future<void> _write(Map<String, Map<String, dynamic>> box) async {
    try {
      await storage.write(sosOutboxKey, jsonEncode(box));
    } on Object {
      // Storage failed: the report is still sent while the screen is open
    }
  }

  Future<List<SosReport>> pending() async => (await _read()).values.map(SosReport.fromJson).toList();

  /// Sends every report still in the outbox. Resolves true when nothing is left.
  Future<bool> flush() {
    final running = _flushing;
    if (running != null) return running;
    final future = _flush();
    _flushing = future;
    // Clear the flag however it ends, without leaving an unhandled error behind
    future.then((_) {}, onError: (_) {}).whenComplete(() => _flushing = null);
    return future;
  }

  Future<bool> _flush() async {
    for (final entry in (await _read()).values) {
      final report = SosReport.fromJson(entry);
      await send(report);
      final box = await _read();
      // Only drop it if no newer report for the same S.O.S arrived while sending
      if (jsonEncode(box[report.clientId]) == jsonEncode(entry)) {
        box.remove(report.clientId);
        await _write(box);
      }
    }
    return (await _read()).isEmpty;
  }

  /// Keeps the latest report of an S.O.S and tries to send it now
  Future<bool> queue(SosReport report) async {
    final box = await _read();
    box[report.clientId] = report.toJson();
    await _write(box);
    return flush();
  }
}

/// User-facing text for a failed sos_report call
String sosReportErrorMessage(String message, String? code) =>
    RegExp('could not find the function|PGRST202', caseSensitive: false).hasMatch('$message ${code ?? ''}')
    ? 'S.O.S alerts are not set up yet (run the 20261024000015 migration)'
    : message;
