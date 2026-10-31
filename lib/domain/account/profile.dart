// The signed-in account as the app sees it: plan, role and permissions from `profiles`
// (status_subscribe, status_user, is_admin, can_use_sos, organization, phone,
// subscription_expires_at), resolved the same way as loadUserProfile() in
// src/store/useSurveyStore.ts (web).
//
// A paid plan (bought on the web through Midtrans, 20261031000023_subscription_payments.sql)
// has an end date; a plan set by the admin has none. The server turns a plan that ran out back
// to Free once a day; the app already shows it as Free from the moment it ends.
//
// These only decide what the UI shows. The server enforces every rule again (RLS and the
// SECURITY DEFINER functions), so a tampered client gains nothing.

enum Plan {
  free('Free'),
  pro('Pro'),
  enterprise('Enterprise');

  const Plan(this.value);

  final String value; // as stored in profiles.status_subscribe

  static Plan parse(String? v) => values.firstWhere((p) => p.value == v, orElse: () => Plan.free);
}

enum UserRole {
  pengguna360,
  monitor360;

  static UserRole parse(String? v) => v == 'monitor360' ? monitor360 : pengguna360;
}

class AccountProfile {
  const AccountProfile({
    required this.userId,
    required this.email,
    required this.displayName,
    required this.plan,
    required this.role,
    required this.isAdmin,
    required this.canUseSos,
    this.organization,
    this.phone,
    this.subscriptionExpiresAt,
  });

  /// Builds the profile from the `profiles` row (null when it could not be read). Admins
  /// get the highest plan, the monitor role and S.O.S, whatever is stored.
  factory AccountProfile.resolve({
    required String userId,
    required String email,
    required String displayName,
    required Map<String, dynamic>? row,
    bool? cachedCanUseSos,
    DateTime? now,
  }) {
    final isAdmin = row?['is_admin'] == true;
    final expiresAt = isAdmin ? null : DateTime.tryParse('${row?['subscription_expires_at'] ?? ''}');
    // A paid plan that ran out is Free, even before the server's daily clean-up
    final ended = expiresAt != null && !expiresAt.isAfter(now ?? DateTime.now());
    return AccountProfile(
      userId: userId,
      email: email,
      displayName: displayName,
      plan: isAdmin ? Plan.enterprise : (ended ? Plan.free : Plan.parse(row?['status_subscribe'] as String?)),
      role: isAdmin ? UserRole.monitor360 : (ended ? UserRole.pengguna360 : UserRole.parse(row?['status_user'] as String?)),
      isAdmin: isAdmin,
      // Offline (no row) the last known value stays, so the S.O.S button does not
      // disappear where there is no signal
      canUseSos: isAdmin || (row == null ? cachedCanUseSos ?? false : row['can_use_sos'] == true),
      organization: row?['organization'] as String?,
      phone: row?['phone'] as String?,
      subscriptionExpiresAt: ended ? null : expiresAt,
    );
  }

  final String userId;
  final String email;
  final String displayName;
  final Plan plan;
  final UserRole role;
  final bool isAdmin;
  final bool canUseSos;
  final String? organization;
  final String? phone;

  /// End of a paid plan (null: Free, set by the admin, or the admin account)
  final DateTime? subscriptionExpiresAt;

  /// Whole days left of a paid plan (0 on its last day), or null without an end date
  int? daysLeft(DateTime now) {
    final end = subscriptionExpiresAt;
    if (end == null) return null;
    return end.difference(now).inHours ~/ 24;
  }

  /// A paid plan ending within 7 days: time for a reminder
  bool endsSoon(DateTime now) {
    final days = daysLeft(now);
    return days != null && days < 7;
  }

  /// Track Recorder records only for Enterprise or admin (canRecordTracks on the web)
  bool get canRecordTracks => isAdmin || plan == Plan.enterprise;

  /// Renaming a track that reached the cloud: Pro, Enterprise or admin (canRenameCloudTracks)
  bool get canRenameCloudTracks => isAdmin || plan != Plan.free;

  /// Live tracking monitor: Enterprise monitor360 or admin (is_monitor() on the server)
  bool get canMonitor => isAdmin || (plan == Plan.enterprise && role == UserRole.monitor360);

  /// A member account (pengguna360, not admin): GPS Tracking is theirs; monitors watch on the web
  bool get isMember => !isAdmin && role == UserRole.pengguna360;

  /// GPS Tracking (sharing your live position with the monitors): members on Pro or
  /// Enterprise (can_broadcast_location() on the server)
  bool get canBroadcast => isMember && plan != Plan.free;

  /// Cloud storage limit in bytes (null = unlimited): Free 10 MB, Pro 100 MB, Enterprise 1 GB
  int? get storageLimitBytes => isAdmin
      ? null
      : switch (plan) {
          Plan.free => 10 * 1024 * 1024,
          Plan.pro => 100 * 1024 * 1024,
          Plan.enterprise => 1024 * 1024 * 1024,
        };
}

const _months = ['January', 'February', 'March', 'April', 'May', 'June', 'July', 'August', 'September', 'October', 'November', 'December'];

/// "30 November 2026" in the phone's local time
String formatPlanDate(DateTime when) {
  final d = when.toLocal();
  return '${d.day} ${_months[d.month - 1]} ${d.year}';
}

/// What User Account says about a paid plan's end: "Active until 30 November 2026",
/// "Ends in 3 days (30 November 2026)", "Ends today"; null without an end date
String? planEndText(AccountProfile p, DateTime now) {
  final end = p.subscriptionExpiresAt;
  final days = p.daysLeft(now);
  if (end == null || days == null) return null;
  if (days == 0) return 'Ends today (${formatPlanDate(end)})';
  if (p.endsSoon(now)) return 'Ends in $days day${days == 1 ? '' : 's'} (${formatPlanDate(end)})';
  return 'Active until ${formatPlanDate(end)}';
}
