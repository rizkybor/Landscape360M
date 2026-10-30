import 'package:supabase_flutter/supabase_flutter.dart';

import '../../domain/classic/field_work.dart';

// Shared Classic Field Works (classicShareSync.ts; table classic_field_work_links and its
// functions in 20261030000022). Every signed-in account can share; anyone with the link can
// look, without signing in. The link always shows the latest version.

class ClassicLinkException implements Exception {
  const ClassicLinkException(this.message);
  final String message;

  @override
  String toString() => message;
}

abstract interface class ClassicLinks {
  /// Creates the link (token null) or saves the latest version to it; returns the token
  Future<String> save({
    required String? token,
    required ClassicMode mode,
    required String name,
    required FieldWorkData data,
    required String declination,
  });

  Future<void> revoke(String token);

  /// The shared Field Work, or null when the link is off or unknown
  Future<ViewedFieldWork?> open(String token);
}

final _missing = RegExp(
  r'PGRST202|PGRST205|42P01|could not find the (function|table)|relation .* does not exist',
  caseSensitive: false,
);

class SupabaseClassicLinks implements ClassicLinks {
  SupabaseClassicLinks(this.client);

  final SupabaseClient client;

  Future<T> _call<T>(Future<T> Function() run) async {
    try {
      return await run();
    } on PostgrestException catch (e) {
      throw ClassicLinkException(
        _missing.hasMatch('${e.code ?? ''} ${e.message}')
            ? 'Sharing Field Works is not set up yet (run the 20261030000022 migration)'
            : e.message,
      );
    }
  }

  @override
  Future<String> save({
    required String? token,
    required ClassicMode mode,
    required String name,
    required FieldWorkData data,
    required String declination,
  }) => _call(
    () => client.rpc<String>(
      'save_classic_field_work_link',
      params: {
        'p_token': token,
        'p_mode': mode.name,
        'p_name': name,
        'p_data': {...data.toJson(), 'declination': declination},
      },
    ),
  );

  @override
  Future<void> revoke(String token) =>
      _call(() => client.rpc<void>('revoke_classic_field_work_link', params: {'p_token': token}));

  @override
  Future<ViewedFieldWork?> open(String token) => _call(() async {
    final rows = await client.rpc<List<dynamic>>('open_classic_field_work_link', params: {'p_token': token});
    if (rows.isEmpty) return null;
    final r = Map<String, dynamic>.from(rows.first as Map);
    final data = Map<String, dynamic>.from(r['data'] as Map? ?? const {});
    return ViewedFieldWork(
      token: token,
      mode: ClassicMode.parse(r['mode']),
      name: '${r['name'] ?? 'Field Work'}',
      data: FieldWorkData.fromJson(data),
      declination: '${data['declination'] ?? '0'}',
      ownerName: r['owner_name'] as String?,
      updatedAt: DateTime.tryParse('${r['updated_at']}')?.toLocal() ?? DateTime.now(),
    );
  });
}
