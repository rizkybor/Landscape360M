// Ports of src/lib/storageUsage.ts, src/lib/profileContact.ts and src/lib/accountPassword.ts
// (the parts without network calls).

// --- Storage usage (my_storage_usage() in 20261024000004_storage_quotas.sql) -------------

String formatBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
  if (bytes < 1024 * 1024 * 1024) {
    return '${(bytes / 1024 / 1024).toStringAsFixed(bytes < 10 * 1024 * 1024 ? 2 : 1)} MB';
  }
  return '${(bytes / 1024 / 1024 / 1024).toStringAsFixed(2)} GB';
}

/// `+n.toFixed(2)` in JavaScript: rounded to 2 decimals without trailing zeros
String _trimFixed2(double n) {
  final s = double.parse(n.toStringAsFixed(2));
  return s == s.truncateToDouble() ? s.toInt().toString() : s.toString();
}

String formatMb(double mb) => mb >= 1024 ? '${_trimFixed2(mb / 1024)} GB' : '${_trimFixed2(mb)} MB';

/// 0..100, or null when unlimited
double? usagePercent(int usedBytes, int? limitBytes) {
  if (limitBytes == null) return null;
  if (limitBytes <= 0) return 100;
  final p = (usedBytes / limitBytes) * 100;
  return p > 100 ? 100 : p;
}

/// Cloud storage of the signed-in account (my_storage_usage() RPC)
class MyStorageUsage {
  const MyStorageUsage({
    required this.usedBytes,
    required this.limitBytes,
    required this.tracks,
    required this.locations,
    required this.surveys,
    required this.basemaps,
  });

  /// From the first row the RPC returns; null without a row
  static MyStorageUsage? fromRows(List<dynamic>? rows) {
    if (rows == null || rows.isEmpty || rows.first is! Map) return null;
    final r = rows.first as Map;
    int n(Object? v) => v is num ? v.toInt() : int.tryParse('$v') ?? 0;
    return MyStorageUsage(
      usedBytes: n(r['used_bytes']),
      limitBytes: r['limit_bytes'] == null ? null : n(r['limit_bytes']),
      tracks: n(r['tracks_bytes']),
      locations: n(r['locations_bytes']),
      surveys: n(r['surveys_bytes']),
      basemaps: n(r['basemaps_bytes']),
    );
  }

  final int usedBytes;
  final int? limitBytes; // null = unlimited
  final int tracks;
  final int locations;
  final int surveys;
  final int basemaps;

  /// Same labels as STORAGE_CATEGORY_LABELS on the web
  List<(String, int)> get breakdown => [
    ('Tracks', tracks),
    ('Marked Locations', locations),
    ('Surveys', surveys),
    ('Custom Basemaps', basemaps),
  ];

  double? get percent => usagePercent(usedBytes, limitBytes);
}

enum UsageLevel { normal, warning, critical }

/// Bar colour level (web: forest / gold-400 at 70% / brick-500 at 90%)
UsageLevel usageLevel(double? percent) => percent == null
    ? UsageLevel.normal
    : percent >= 90
    ? UsageLevel.critical
    : percent >= 70
    ? UsageLevel.warning
    : UsageLevel.normal;

// --- Profile contact ---------------------------------------------------------------------

/// Name of an account. `display_name` is the one name field; older accounts may only have
/// `full_name` or `name`.
String accountDisplayName(Map<String, dynamic>? userMetadata) {
  final meta = userMetadata ?? const {};
  for (final key in ['display_name', 'full_name', 'name']) {
    final v = meta[key];
    if (v is String && v.isNotEmpty) return v;
  }
  return '';
}

final _nonDigit = RegExp(r'\D');

/// Same rule as the account request form: empty, or 8 to 15 digits
bool isValidPhone(String phone) {
  final digits = phone.replaceAll(_nonDigit, '').length;
  return phone.trim().isEmpty || (digits >= 8 && digits <= 15);
}

/// wa.me link for an Indonesian or international number ("0812..." becomes "62812...")
String? whatsappUrl(String phone) {
  var digits = phone.replaceAll(_nonDigit, '');
  if (digits.length < 8) return null;
  if (digits.startsWith('0')) digits = '62${digits.substring(1)}';
  return 'https://wa.me/$digits';
}

// --- Password ------------------------------------------------------------------------------

/// Same as MIN_PASSWORD_LENGTH in src/lib/adminUsers.ts
const minPasswordLength = 8;

/// First problem with the change-password form, or null when it can be submitted
String? passwordChangeError({required String current, required String next, required String confirm}) {
  if (current.isEmpty) return 'Enter your current password';
  if (next.length < minPasswordLength) return 'New password must be at least $minPasswordLength characters';
  if (next == current) return 'The new password must be different from the current one';
  if (next != confirm) return 'The new passwords do not match';
  return null;
}
