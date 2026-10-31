import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../domain/account/profile.dart';

// Reminder that a paid plan ends soon (7 days or less): shown on the map at most once a day.
// Renewal happens outside the app for now (the web's Midtrans payments), so it only says when.

final planReminderPrefsProvider = Provider<SharedPreferencesAsync>((ref) => SharedPreferencesAsync());

/// The reminder text when it is due today (and records that it was shown), otherwise null
Future<String?> planReminderDue(SharedPreferencesAsync prefs, AccountProfile? p, DateTime now) async {
  final end = p?.subscriptionExpiresAt;
  final days = p?.daysLeft(now);
  if (p == null || end == null || days == null || !p.endsSoon(now)) return null;
  final key = 'l360-plan-reminder-${p.userId}';
  final today = '${now.year}-${now.month}-${now.day}';
  if (await prefs.getString(key) == today) return null;
  await prefs.setString(key, today);
  final when = days == 0 ? 'ends today' : 'ends in $days day${days == 1 ? '' : 's'}';
  return 'Your ${p.plan.value} plan $when (${formatPlanDate(end)}).';
}
