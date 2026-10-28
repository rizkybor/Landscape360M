import 'account_rules.dart';

// The public "Request account" form, same fields and rules as the web form and
// api/account-requests.ts (POST): email, fullName, organization?, phone?, message.

class AccountRequestInput {
  const AccountRequestInput({
    required this.email,
    required this.fullName,
    required this.organization,
    required this.phone,
    required this.message,
  });

  final String email;
  final String fullName;
  final String organization;
  final String phone;
  final String message;

  /// Body of POST /api/account-requests. `website` is the honeypot the server checks:
  /// always empty from the app. Visitors can only request the Free plan.
  Map<String, dynamic> toJson() => {
    'email': email.trim().toLowerCase(),
    'fullName': fullName.trim(),
    'organization': organization.trim(),
    'phone': phone.trim(),
    'message': message.trim(),
    'requestedPlan': 'Free',
    'website': '',
  };
}

final _email = RegExp(r'^[^\s@]+@[^\s@]+\.[^\s@]+$');
final _phone = RegExp(r'^\+?(?:[\s-]*\d){8,15}$');

/// First problem with the form, or null (mirrors the server's checks, which still apply)
String? accountRequestError(AccountRequestInput i) {
  if (i.fullName.trim().isEmpty) return 'Enter your full name';
  if (i.fullName.trim().length > 120) return 'Full name is too long';
  final email = i.email.trim();
  if (email.isEmpty || email.length > 254 || !_email.hasMatch(email)) return 'Enter a valid email';
  if (i.organization.trim().length > 120) return 'Organization is too long';
  final phone = i.phone.trim();
  if (phone.isNotEmpty && (!_phone.hasMatch(phone) || !isValidPhone(phone))) {
    return 'A valid phone / WhatsApp number (8 to 15 digits) is required';
  }
  if (i.message.trim().isEmpty) return 'Tell us how you will use Landscape 360 app';
  if (i.message.trim().length > 1000) return 'Message is too long (max 1000 characters)';
  return null;
}
