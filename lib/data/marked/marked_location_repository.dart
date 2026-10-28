import 'package:supabase_flutter/supabase_flutter.dart';

import '../../domain/marked/marked_locations.dart';

// Marked locations in the cloud (src/services/markedLocationSync.ts): tables
// marked_locations / marked_location_shares and their server functions
// (20261024000003, share links 20261026000018). The plan limit, who may share and who sees
// what are enforced by the database; these calls only surface its errors.

class MarkedLocation {
  const MarkedLocation({
    required this.id,
    required this.userId,
    required this.name,
    required this.category,
    required this.lat,
    required this.lng,
    this.elevationM,
    this.description,
    this.address,
    this.contact,
    this.tags = const [],
    required this.createdAt,
    required this.updatedAt,
  });

  factory MarkedLocation.fromRow(Map<String, dynamic> r) => MarkedLocation(
    id: '${r['id']}',
    userId: '${r['user_id']}',
    name: '${r['name'] ?? ''}',
    category: MarkedLocationCategory.fromName('${r['category']}') ?? MarkedLocationCategory.poi,
    lat: (r['lat'] as num).toDouble(),
    lng: (r['lng'] as num).toDouble(),
    elevationM: (r['elevation_m'] as num?)?.toDouble(),
    description: r['description'] as String?,
    address: r['address'] as String?,
    contact: r['contact'] as String?,
    tags: [for (final t in (r['tags'] as List? ?? const [])) '$t'],
    createdAt: DateTime.tryParse('${r['created_at']}') ?? DateTime(0),
    updatedAt: DateTime.tryParse('${r['updated_at']}') ?? DateTime(0),
  );

  final String id;
  final String userId;
  final String name;
  final MarkedLocationCategory category;
  final double lat;
  final double lng;
  final double? elevationM;
  final String? description;
  final String? address;
  final String? contact;
  final List<String> tags;
  final DateTime createdAt;
  final DateTime updatedAt;

  MarkedLocationGpx get gpx => MarkedLocationGpx(
    name: name,
    category: category.name,
    lat: lat,
    lng: lng,
    elevationM: elevationM,
    description: description,
    address: address,
    contact: contact,
    tags: tags,
  );

  /// Matches the list search (name, address, description, contact, tags, category)
  bool matches(String query) {
    final q = query.trim().toLowerCase();
    if (q.isEmpty) return true;
    return [
      name,
      address,
      description,
      contact,
      ...tags,
      category.label,
    ].whereType<String>().any((v) => v.toLowerCase().contains(q));
  }
}

/// What the form saves
class MarkedLocationInput {
  const MarkedLocationInput({
    required this.name,
    required this.category,
    required this.lat,
    required this.lng,
    this.elevationM,
    this.description = '',
    this.address = '',
    this.contact = '',
    this.tags = const [],
  });

  final String name;
  final MarkedLocationCategory category;
  final double lat;
  final double lng;
  final double? elevationM;
  final String description;
  final String address;
  final String contact;
  final List<String> tags;

  Map<String, dynamic> toRow() {
    String? opt(String s) => s.trim().isEmpty ? null : s.trim();
    return {
      'name': name.trim(),
      'category': category.name,
      'lng': lng,
      'lat': lat,
      'elevation_m': elevationM,
      'description': opt(description),
      'address': opt(address),
      'contact': opt(contact),
      'tags': tags,
    };
  }
}

/// A location someone shared with me, or (admin) any account's
class OwnedLocation {
  const OwnedLocation(this.location, {this.owner});
  final MarkedLocation location;
  final String? owner; // name, else masked / full email
}

class ShareSuggestion {
  const ShareSuggestion({required this.userId, this.name, this.emailMasked, this.recent = false});
  final String userId;
  final String? name;
  final String? emailMasked;
  final bool recent;

  String get label => recipientLabel(name, emailMasked);
}

class LocationShare {
  const LocationShare({required this.userId, this.name, this.emailMasked});
  final String userId;
  final String? name;
  final String? emailMasked;

  String get label => recipientLabel(name, emailMasked);
}

class ShareResult {
  const ShareResult({required this.userId, this.name, this.emailMasked, required this.sharedCount});
  final String userId;
  final String? name;
  final String? emailMasked;
  final int sharedCount;

  String get label => recipientLabel(name, emailMasked);
}

/// "Rina (r***@x.id)"
String recipientLabel(String? name, String? emailMasked) {
  final parts = [?name, if (emailMasked != null) '($emailMasked)'];
  return parts.isEmpty ? 'Unknown account' : parts.join(' ');
}

class MarkedLocationException implements Exception {
  const MarkedLocationException(this.message);
  final String message;

  @override
  String toString() => message;
}

abstract interface class MarkedLocationBackend {
  Future<List<MarkedLocation>> mine(String userId);
  Future<List<OwnedLocation>> sharedWithMe();
  Future<List<OwnedLocation>> all();
  Future<MarkedLocation> create(MarkedLocationInput input);
  Future<MarkedLocation> update(String id, MarkedLocationInput input);
  Future<void> delete(String id);
  Future<ShareResult> share(List<String> ids, String recipient);
  Future<List<ShareSuggestion>> suggestions(String query);
  Future<List<LocationShare>> shares(String id);
  Future<void> removeShare(String id, String recipientId);
  Future<String?> link(String id);
  Future<String> createLink(String id);
  Future<void> revokeLink(String id);
}

const _columns =
    'id, user_id, name, category, lng, lat, elevation_m, description, address, contact, tags, created_at, updated_at';

class SupabaseMarkedLocationBackend implements MarkedLocationBackend {
  SupabaseMarkedLocationBackend(this.client);

  final SupabaseClient client;

  Future<T> _call<T>(Future<T> Function() run, {bool link = false}) async {
    try {
      return await run();
    } on PostgrestException catch (e) {
      final missing = RegExp(
        'could not find the function|PGRST202',
        caseSensitive: false,
      ).hasMatch('${e.message} ${e.code ?? ''}');
      throw MarkedLocationException(
        link && missing ? 'Share links are not set up yet (run the 20261026000018 migration)' : e.message,
      );
    }
  }

  Map<String, dynamic> _map(Object? r) => Map<String, dynamic>.from(r! as Map);

  @override
  Future<List<MarkedLocation>> mine(String userId) => _call(() async {
    final rows = await client
        .from('marked_locations')
        .select(_columns)
        .eq('user_id', userId)
        .order('created_at', ascending: false);
    return rows.map(MarkedLocation.fromRow).toList();
  });

  @override
  Future<List<OwnedLocation>> sharedWithMe() => _call(() async {
    final rows = await client.rpc<List<dynamic>>('list_marked_locations_shared_with_me');
    return [
      for (final r in rows.map(_map))
        OwnedLocation(MarkedLocation.fromRow(r), owner: (r['owner_name'] ?? r['owner_email_masked']) as String?),
    ];
  });

  @override
  Future<List<OwnedLocation>> all() => _call(() async {
    final rows = await client.rpc<List<dynamic>>('admin_list_marked_locations');
    return [
      for (final r in rows.map(_map))
        OwnedLocation(MarkedLocation.fromRow(r), owner: (r['owner_email'] ?? r['owner_name']) as String?),
    ];
  });

  @override
  Future<MarkedLocation> create(MarkedLocationInput input) => _call(() async {
    final row = await client.from('marked_locations').insert(input.toRow()).select(_columns).single();
    return MarkedLocation.fromRow(row);
  });

  @override
  Future<MarkedLocation> update(String id, MarkedLocationInput input) => _call(() async {
    final row = await client.from('marked_locations').update(input.toRow()).eq('id', id).select(_columns).single();
    return MarkedLocation.fromRow(row);
  });

  @override
  Future<void> delete(String id) => _call(() => client.from('marked_locations').delete().eq('id', id));

  @override
  Future<ShareResult> share(List<String> ids, String recipient) => _call(() async {
    final rows = await client.rpc<List<dynamic>>(
      'share_marked_locations',
      params: {'p_location_ids': ids, 'p_recipient': recipient},
    );
    if (rows.isEmpty) throw const MarkedLocationException('Share failed');
    final r = _map(rows.first);
    return ShareResult(
      userId: '${r['shared_with']}',
      name: r['name'] as String?,
      emailMasked: r['email_masked'] as String?,
      sharedCount: (r['shared_count'] as num? ?? 0).toInt(),
    );
  });

  @override
  Future<List<ShareSuggestion>> suggestions(String query) => _call(() async {
    final rows = await client.rpc<List<dynamic>>('marked_location_share_suggestions', params: {'p_query': query});
    return [
      for (final r in rows.map(_map))
        ShareSuggestion(
          userId: '${r['user_id']}',
          name: r['name'] as String?,
          emailMasked: r['email_masked'] as String?,
          recent: r['recent'] == true,
        ),
    ];
  });

  @override
  Future<List<LocationShare>> shares(String id) => _call(() async {
    final rows = await client.rpc<List<dynamic>>('list_marked_location_shares', params: {'p_location_id': id});
    return [
      for (final r in rows.map(_map))
        LocationShare(
          userId: '${r['shared_with']}',
          name: r['name'] as String?,
          emailMasked: r['email_masked'] as String?,
        ),
    ];
  });

  @override
  Future<void> removeShare(String id, String recipientId) =>
      _call(() => client.from('marked_location_shares').delete().eq('location_id', id).eq('shared_with', recipientId));

  @override
  Future<String?> link(String id) =>
      _call(() => client.rpc<String?>('get_marked_location_link', params: {'p_location_id': id}), link: true);

  @override
  Future<String> createLink(String id) =>
      _call(() => client.rpc<String>('create_marked_location_link', params: {'p_location_id': id}), link: true);

  @override
  Future<void> revokeLink(String id) =>
      _call(() => client.rpc<void>('revoke_marked_location_link', params: {'p_location_id': id}), link: true);
}
