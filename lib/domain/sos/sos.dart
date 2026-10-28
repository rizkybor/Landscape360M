import 'dart:convert';

import '../account/account_rules.dart';
import '../survey/survey_utils.dart';
import '../util/js_compat.dart';

// Port of src/lib/sos.ts. Calls and SMS open in the phone's own apps; the user still
// presses Call / Send there.

/// Indonesia: 112 national emergency line, 115 Basarnas (search and rescue)
const emergencyNumbers = [(label: 'Emergency 112', number: '112'), (label: 'Basarnas 115', number: '115')];

const maxEmergencyContacts = 5;

class EmergencyContact {
  const EmergencyContact({required this.name, required this.phone});

  final String name;
  final String phone;

  Map<String, String> toJson() => {'name': name, 'phone': phone};

  @override
  bool operator ==(Object other) => other is EmergencyContact && other.name == name && other.phone == phone;

  @override
  int get hashCode => Object.hash(name, phone);
}

class SosFix {
  const SosFix({required this.lat, required this.lng, this.accuracy, this.elevation, required this.time});

  factory SosFix.fromJson(Map<String, dynamic> j) => SosFix(
    lat: (j['lat'] as num).toDouble(),
    lng: (j['lng'] as num).toDouble(),
    accuracy: (j['accuracy'] as num?)?.toDouble(),
    elevation: (j['elevation'] as num?)?.toDouble(),
    time: (j['time'] as num).toInt(),
  );

  final double lat;
  final double lng;
  final double? accuracy; // meters
  final double? elevation; // meters
  final int time; // ms since epoch

  Map<String, dynamic> toJson() => {'lat': lat, 'lng': lng, 'accuracy': accuracy, 'elevation': elevation, 'time': time};
}

String emergencyContactsKey(String userId) => 'l360-sos-contacts-$userId';

/// Contacts read back from storage; anything malformed is dropped
List<EmergencyContact> decodeEmergencyContacts(String? raw) {
  try {
    final list = jsonDecode(raw ?? '[]');
    if (list is! List) return const [];
    return list
        .whereType<Map<String, dynamic>>()
        .where((c) => c['name'] is String && c['phone'] is String)
        .map((c) => EmergencyContact(name: c['name'] as String, phone: c['phone'] as String))
        .take(maxEmergencyContacts)
        .toList();
  } on FormatException {
    return const [];
  }
}

String encodeEmergencyContacts(List<EmergencyContact> contacts) =>
    jsonEncode(contacts.take(maxEmergencyContacts).map((c) => c.toJson()).toList());

final _nonDigit = RegExp(r'\D');

/// First problem with a new contact, or null
String? emergencyContactError(EmergencyContact c, List<EmergencyContact> existing) {
  if (c.name.trim().isEmpty) return 'Enter a name';
  if (c.phone.trim().isEmpty || !isValidPhone(c.phone)) return 'Phone number must have 8 to 15 digits';
  if (existing.length >= maxEmergencyContacts) return 'At most $maxEmergencyContacts contacts';
  final digits = c.phone.replaceAll(_nonDigit, '');
  if (existing.any((e) => e.phone.replaceAll(_nonDigit, '') == digits)) return 'This number is already in the list';
  return null;
}

/// SMS text: short enough for one or two SMS, readable by a person and a rescuer
String buildSosMessage(String name, SosFix? fix) {
  final who = name.trim().isEmpty ? 'A Landscape 360 user' : name.trim();
  if (fix == null) return 'SOS Landscape 360: $who butuh bantuan / needs help. Lokasi belum didapat (no GPS fix yet).';
  final lat5 = fix.lat.toStringAsFixed(5), lng5 = fix.lng.toStringAsFixed(5);
  final details = [
    if (fix.elevation != null) 'elev ${jsRoundStr(fix.elevation!)} m',
    if (fix.accuracy != null) '±${jsRoundStr(fix.accuracy!)} m',
    formatDayTime(fix.time),
  ];
  return [
    'SOS Landscape 360: $who butuh bantuan / needs help.',
    'Lokasi: ${toDMS(fix.lat, isLat: true)} ${toDMS(fix.lng, isLat: false)} ($lat5, $lng5)',
    '${details.join(', ')}.',
    'Peta: https://maps.google.com/?q=$lat5,$lng5',
  ].join(' ');
}

/// sms: link with the message filled in (iOS separates the body with "&", others "?")
String smsUrl(List<String> numbers, String body, {required bool ios}) {
  final to = numbers.map((n) => n.replaceAll(RegExp(r'[^\d+]'), '')).join(',');
  return 'sms:$to${ios ? '&' : '?'}body=${Uri.encodeComponent(body)}';
}

/// International Morse for SOS (··· ——— ···) as (on, off) durations in ms, repeated
const _dot = 220;
const sosLightPattern = <(int, int)>[
  (_dot, _dot), (_dot, _dot), (_dot, _dot * 3), //
  (_dot * 3, _dot), (_dot * 3, _dot), (_dot * 3, _dot * 3),
  (_dot, _dot), (_dot, _dot), (_dot, _dot * 7),
];
