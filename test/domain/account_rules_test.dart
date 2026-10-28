import 'package:flutter_test/flutter_test.dart';
import 'package:landscape360/domain/account/account_rules.dart';

// Same cases as src/lib/storageUsage.test.ts, profileContact.test.ts and
// accountPassword.test.ts (web)

void main() {
  group('storage usage helpers', () {
    test('formats bytes', () {
      expect(formatBytes(512), '512 B');
      expect(formatBytes(1536), '1.5 KB');
      expect(formatBytes(5 * 1024 * 1024), '5.00 MB');
      expect(formatBytes(150 * 1024 * 1024), '150.0 MB');
      expect(formatBytes(2 * 1024 * 1024 * 1024), '2.00 GB');
    });

    test('formats MB limits', () {
      expect(formatMb(10), '10 MB');
      expect(formatMb(0.05), '0.05 MB');
      expect(formatMb(1024), '1 GB');
      expect(formatMb(1536), '1.5 GB');
    });

    test('computes usage percent, capped, and null when unlimited', () {
      expect(usagePercent(5, 10), 50);
      expect(usagePercent(20, 10), 100);
      expect(usagePercent(0, 0), 100);
      expect(usagePercent(123, null), isNull);
    });

    test('colors the bar by how full it is', () {
      expect(usageLevel(null), UsageLevel.normal);
      expect(usageLevel(50), UsageLevel.normal);
      expect(usageLevel(75), UsageLevel.warning);
      expect(usageLevel(95), UsageLevel.critical);
    });
  });

  test('accountDisplayName reads the name wherever the account stored it', () {
    expect(accountDisplayName({'display_name': 'Budi Santoso'}), 'Budi Santoso');
    expect(accountDisplayName({'full_name': 'Old', 'display_name': 'Current'}), 'Current');
    expect(accountDisplayName({'full_name': 'Older account'}), 'Older account');
    expect(accountDisplayName({'name': 'Google Name'}), 'Google Name');
    expect(accountDisplayName({}), '');
    expect(accountDisplayName(null), '');
  });

  test('isValidPhone accepts 8 to 15 digits, or nothing', () {
    expect(isValidPhone('+62 812-3456-7890'), isTrue);
    expect(isValidPhone(''), isTrue);
    expect(isValidPhone('12345'), isFalse);
    expect(isValidPhone('1234567890123456'), isFalse);
  });

  test('whatsappUrl turns a local Indonesian number into an international one', () {
    expect(whatsappUrl('0812-3456-7890'), 'https://wa.me/6281234567890');
    expect(whatsappUrl('+62 812 3456 7890'), 'https://wa.me/6281234567890');
    expect(whatsappUrl('123'), isNull);
  });

  group('passwordChangeError', () {
    final cases = [
      (('', 'newpass123', 'newpass123'), 'current password'),
      (('oldpass123', 'short', 'short'), 'at least 8'),
      (('samepass123', 'samepass123', 'samepass123'), 'different'),
      (('oldpass123', 'newpass123', 'newpass124'), 'do not match'),
    ];
    for (final ((current, next, confirm), message) in cases) {
      test('rejects "$current" -> "$next"', () {
        expect(passwordChangeError(current: current, next: next, confirm: confirm), contains(message));
      });
    }

    test('accepts a valid change', () {
      expect(passwordChangeError(current: 'oldpass123', next: 'newpass123', confirm: 'newpass123'), isNull);
    });
  });
}
