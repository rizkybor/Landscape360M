import 'package:flutter_test/flutter_test.dart';
import 'package:landscape360/domain/account/profile.dart';
import 'package:landscape360/features/account/plan_reminder.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

// Paid plans (web Midtrans payments, 20261031000023_subscription_payments.sql): the app reads
// the end date, shows it, and reminds the user in the last week

final _now = DateTime.utc(2026, 11, 1, 12);

AccountProfile _profile(Map<String, dynamic> row) =>
    AccountProfile.resolve(userId: 'u1', email: 'budi@example.com', displayName: 'Budi', row: row, now: _now);

void main() {
  group('paid plan end date', () {
    test('a running paid plan keeps its plan and end date', () {
      final p = _profile({'status_subscribe': 'Enterprise', 'status_user': 'monitor360', 'subscription_expires_at': '2026-11-30T12:00:00Z'});
      expect((p.plan, p.role, p.daysLeft(_now), p.endsSoon(_now)), (Plan.enterprise, UserRole.monitor360, 29, false));
      expect(planEndText(p, _now), 'Active until 30 November 2026');
    });

    test('the last week is "ends soon", the last day "ends today"', () {
      final soon = _profile({'status_subscribe': 'Pro', 'subscription_expires_at': '2026-11-04T13:00:00Z'});
      expect((soon.daysLeft(_now), soon.endsSoon(_now)), (3, true));
      expect(planEndText(soon, _now), startsWith('Ends in 3 days'));
      final today = _profile({'status_subscribe': 'Pro', 'subscription_expires_at': '2026-11-01T20:00:00Z'});
      expect(planEndText(today, _now), startsWith('Ends today'));
    });

    test('a plan that ran out is Free; admin and hand-set plans have no end', () {
      final ended = _profile({'status_subscribe': 'Enterprise', 'status_user': 'monitor360', 'subscription_expires_at': '2026-10-31T00:00:00Z'});
      expect((ended.plan, ended.role, ended.canMonitor, planEndText(ended, _now)), (Plan.free, UserRole.pengguna360, false, null));
      expect(planEndText(_profile({'status_subscribe': 'Pro'}), _now), isNull);
      final admin = _profile({'is_admin': true, 'subscription_expires_at': '2026-10-31T00:00:00Z'});
      expect((admin.plan, admin.subscriptionExpiresAt), (Plan.enterprise, null));
    });
  });

  group('plan reminder', () {
    setUp(() => SharedPreferencesAsyncPlatform.instance = InMemorySharedPreferencesAsync.empty());

    test('shows once a day in the last week only', () async {
      final prefs = SharedPreferencesAsync();
      final soon = _profile({'status_subscribe': 'Pro', 'subscription_expires_at': '2026-11-03T13:00:00Z'});
      expect(await planReminderDue(prefs, soon, _now), 'Your Pro plan ends in 2 days (3 November 2026).');
      expect(await planReminderDue(prefs, soon, _now.add(const Duration(hours: 2))), isNull);
      expect(await planReminderDue(prefs, soon, _now.add(const Duration(days: 1))), isNotNull);

      final later = _profile({'status_subscribe': 'Pro', 'subscription_expires_at': '2026-12-20T00:00:00Z'});
      expect(await planReminderDue(prefs, later, _now), isNull);
      expect(await planReminderDue(prefs, null, _now), isNull);
    });
  });
}
