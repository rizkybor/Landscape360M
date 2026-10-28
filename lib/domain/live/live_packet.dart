// The live position a member shares with the monitors (TrackerPacket in
// src/types/tracker.ts, built in TrackerService.ts on the web), so the web's Team Monitor
// shows it unchanged: the name is the email before the @ in capitals, a position at most
// every 3 s.

/// Time between two positions sent (the web sends when more than 3 s have passed)
const liveSendEvery = Duration(seconds: 3);

/// How the monitor names a member: the email before the @, else the first 8 characters of
/// the account id, in capitals
String liveTrackerId({required String email, required String userId}) {
  final local = email.split('@').first;
  return (local.isNotEmpty ? local : userId.substring(0, userId.length < 8 ? userId.length : 8)).toUpperCase();
}

class LivePacket {
  const LivePacket({
    required this.trackerId,
    required this.lat,
    required this.lng,
    this.alt,
    this.speed,
    this.battery,
    required this.time,
  });

  final String trackerId;
  final double lat;
  final double lng;
  final double? alt; // meters
  final double? speed; // m/s
  final int? battery; // percent
  final int time; // epoch ms of the fix

  Map<String, dynamic> toJson() => {
    'user_id': trackerId,
    'lat': lat,
    'lng': lng,
    // The web sends 0 for no altitude or speed and 100 for an unknown battery
    'alt': alt ?? 0,
    'speed': speed ?? 0,
    'battery': battery ?? 100,
    // Date.toISOString(): UTC with milliseconds
    'timestamp': DateTime.fromMillisecondsSinceEpoch(time, isUtc: true).toIso8601String(),
    'status': 'active',
  };
}
