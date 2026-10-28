// The signed-in account as the app sees it: plan, role and permissions from `profiles`
// (status_subscribe, status_user, is_admin, can_use_sos, organization, phone), resolved the
// same way as loadUserProfile() in src/store/useSurveyStore.ts (web).
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
  });

  /// Builds the profile from the `profiles` row (null when it could not be read). Admins
  /// get the highest plan, the monitor role and S.O.S, whatever is stored.
  factory AccountProfile.resolve({
    required String userId,
    required String email,
    required String displayName,
    required Map<String, dynamic>? row,
    bool? cachedCanUseSos,
  }) {
    final isAdmin = row?['is_admin'] == true;
    return AccountProfile(
      userId: userId,
      email: email,
      displayName: displayName,
      plan: isAdmin ? Plan.enterprise : Plan.parse(row?['status_subscribe'] as String?),
      role: isAdmin ? UserRole.monitor360 : UserRole.parse(row?['status_user'] as String?),
      isAdmin: isAdmin,
      // Offline (no row) the last known value stays, so the S.O.S button does not
      // disappear where there is no signal
      canUseSos: isAdmin || (row == null ? cachedCanUseSos ?? false : row['can_use_sos'] == true),
      organization: row?['organization'] as String?,
      phone: row?['phone'] as String?,
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

  /// Track Recorder records only for Enterprise or admin (canRecordTracks on the web)
  bool get canRecordTracks => isAdmin || plan == Plan.enterprise;

  /// Renaming a track that reached the cloud: Pro, Enterprise or admin (canRenameCloudTracks)
  bool get canRenameCloudTracks => isAdmin || plan != Plan.free;

  /// Live tracking monitor: Enterprise monitor360 or admin (is_monitor() on the server)
  bool get canMonitor => isAdmin || (plan == Plan.enterprise && role == UserRole.monitor360);

  /// GPS Tracking broadcast: Pro and Enterprise
  bool get canBroadcast => isAdmin || plan == Plan.pro || plan == Plan.enterprise;

  /// Cloud storage limit in bytes (null = unlimited): Free 10 MB, Pro 100 MB, Enterprise 1 GB
  int? get storageLimitBytes => isAdmin
      ? null
      : switch (plan) {
          Plan.free => 10 * 1024 * 1024,
          Plan.pro => 100 * 1024 * 1024,
          Plan.enterprise => 1024 * 1024 * 1024,
        };
}
