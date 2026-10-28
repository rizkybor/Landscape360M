import 'package:supabase_flutter/supabase_flutter.dart';

import '../../domain/sos/sos_outbox.dart';

// S.O.S on the server (src/lib/sosAlerts.ts): the user's reports through sos_report, which
// checks can_use_sos() itself, and the admin's list, resolve and delete, which check
// is_admin() (20261024000015 / 16). Push notifications to admins come later.

class SosAlert {
  const SosAlert({
    required this.id,
    required this.userId,
    required this.email,
    this.name,
    this.phone,
    this.organization,
    required this.active,
    this.message,
    this.lat,
    this.lng,
    this.accuracy,
    this.elevation,
    this.battery,
    this.locatedAt,
    required this.startedAt,
    required this.receivedAt,
    required this.updatedAt,
    this.resolvedAt,
    this.resolvedNote,
    this.pointCount = 0,
  });

  factory SosAlert.fromRow(Map<String, dynamic> r) {
    double? n(String k) => (r[k] as num?)?.toDouble();
    DateTime? t(String k) => r[k] == null ? null : DateTime.parse('${r[k]}').toLocal();
    return SosAlert(
      id: '${r['id']}',
      userId: '${r['user_id']}',
      email: '${r['email'] ?? ''}',
      name: r['name'] as String?,
      phone: r['phone'] as String?,
      organization: r['organization'] as String?,
      active: r['status'] != 'resolved',
      message: r['message'] as String?,
      lat: n('lat'),
      lng: n('lng'),
      accuracy: n('accuracy'),
      elevation: n('elevation'),
      battery: (r['battery'] as num?)?.toInt(),
      locatedAt: t('located_at'),
      startedAt: t('started_at')!,
      receivedAt: t('received_at')!,
      updatedAt: t('updated_at')!,
      resolvedAt: t('resolved_at'),
      resolvedNote: r['resolved_note'] as String?,
      pointCount: (r['point_count'] as num? ?? 0).toInt(),
    );
  }

  final String id;
  final String userId;
  final String email;
  final String? name;
  final String? phone;
  final String? organization;
  final bool active;
  final String? message;
  final double? lat;
  final double? lng;
  final double? accuracy;
  final double? elevation;
  final int? battery;
  final DateTime? locatedAt;
  final DateTime startedAt;
  final DateTime receivedAt;
  final DateTime updatedAt;
  final DateTime? resolvedAt;
  final String? resolvedNote;
  final int pointCount;

  bool get hasLocation => lat != null && lng != null;

  /// Name for the map label: the display name, else the start of the email
  String get shortName => (name?.trim().isNotEmpty ?? false) ? name!.trim() : email.split('@').first;
}

class SosException implements Exception {
  const SosException(this.message);
  final String message;

  @override
  String toString() => message;
}

abstract interface class SosBackend {
  Future<void> report(SosReport report);
  Future<List<SosAlert>> alerts({required bool onlyActive});
  Future<void> resolve(String id, String note);
  Future<void> delete(String id);
}

bool _missing(PostgrestException e) =>
    RegExp('could not find the function|PGRST202', caseSensitive: false).hasMatch('${e.message} ${e.code ?? ''}');

class SupabaseSosBackend implements SosBackend {
  SupabaseSosBackend(this.client);

  final SupabaseClient client;

  @override
  Future<void> report(SosReport report) async {
    try {
      await client.rpc<dynamic>('sos_report', params: report.toRpcParams());
    } on PostgrestException catch (e) {
      throw SosException(sosReportErrorMessage(e.message, e.code));
    }
  }

  @override
  Future<List<SosAlert>> alerts({required bool onlyActive}) async {
    try {
      final rows = await client.rpc<List<dynamic>>(
        'admin_sos_alerts',
        params: {'p_only_active': onlyActive, 'p_limit': 100},
      );
      return [for (final r in rows) SosAlert.fromRow(Map<String, dynamic>.from(r as Map))];
    } on PostgrestException catch (e) {
      throw SosException(
        _missing(e) ? 'Run the 20261024000015_sos_alerts migration to receive S.O.S alerts.' : e.message,
      );
    }
  }

  @override
  Future<void> resolve(String id, String note) async {
    try {
      await client.rpc<void>(
        'admin_resolve_sos',
        params: {'p_id': id, 'p_note': note.trim().isEmpty ? null : note.trim()},
      );
    } on PostgrestException catch (e) {
      throw SosException(e.message);
    }
  }

  @override
  Future<void> delete(String id) async {
    try {
      await client.rpc<void>('admin_delete_sos', params: {'p_id': id});
    } on PostgrestException catch (e) {
      throw SosException(_missing(e) ? 'Deleting is not set up yet (run the 20261024000016 migration)' : e.message);
    }
  }
}
