import 'dart:io' show Platform;

import 'package:geolocator/geolocator.dart' as geo;

// GPS fixes for the Track Recorder, GPS Tracking and S.O.S, kept coming while the screen is off or another app is in
// front: on Android a foreground service with a "Recording track" notification, on iOS the
// background location mode (blue indicator in the status bar). Both start from the app in
// front, so "While using the app" permission is enough.

class GpsFix {
  const GpsFix({
    required this.lat,
    required this.lng,
    required this.alt,
    required this.accuracy,
    required this.speed,
    required this.timestamp,
  });

  final double lat;
  final double lng;
  final double? alt; // meters, null without a vertical fix
  final double accuracy; // meters
  final double? speed; // m/s
  final int timestamp; // epoch ms
}

enum GpsAccess { allowed, denied, deniedForever, servicesOff }

class GpsDeniedException implements Exception {
  const GpsDeniedException();
}

class GpsUnavailableException implements Exception {
  const GpsUnavailableException();
}

abstract interface class GpsSource {
  Future<GpsAccess> access();

  /// Asks for location permission (the app explains why first)
  Future<GpsAccess> request();

  /// Fixes until cancelled; errors are [GpsDeniedException], [GpsUnavailableException] or
  /// anything else for "still searching"
  Stream<GpsFix> watch();

  Future<void> openSettings();
}

class GeolocatorGpsSource implements GpsSource {
  static GpsAccess _of(geo.LocationPermission p) => switch (p) {
    geo.LocationPermission.always || geo.LocationPermission.whileInUse => GpsAccess.allowed,
    geo.LocationPermission.deniedForever => GpsAccess.deniedForever,
    _ => GpsAccess.denied,
  };

  @override
  Future<GpsAccess> access() async {
    if (!await geo.Geolocator.isLocationServiceEnabled()) return GpsAccess.servicesOff;
    return _of(await geo.Geolocator.checkPermission());
  }

  @override
  Future<GpsAccess> request() async {
    if (!await geo.Geolocator.isLocationServiceEnabled()) return GpsAccess.servicesOff;
    var p = await geo.Geolocator.checkPermission();
    if (p == geo.LocationPermission.denied) p = await geo.Geolocator.requestPermission();
    return _of(p);
  }

  @override
  Future<void> openSettings() async {
    await geo.Geolocator.openAppSettings();
  }

  // A fix every 3 m of movement at most (the recorder keeps moves of 5 m or more), which
  // saves battery while standing still
  static const _distanceFilter = 3;

  geo.LocationSettings get _settings {
    if (Platform.isAndroid) {
      return geo.AndroidSettings(
        accuracy: geo.LocationAccuracy.best,
        distanceFilter: _distanceFilter,
        intervalDuration: const Duration(seconds: 2),
        foregroundNotificationConfig: const geo.ForegroundNotificationConfig(
          // Shared by the Track Recorder, GPS Tracking and S.O.S (one GPS stream for all)
          notificationTitle: 'Landscape 360 is using GPS',
          notificationText: 'Recording your track, sharing your position or sending S.O.S. Open the app to stop.',
          notificationChannelName: 'GPS in the background',
          enableWakeLock: true,
          setOngoing: true,
        ),
      );
    }
    if (Platform.isIOS) {
      return geo.AppleSettings(
        accuracy: geo.LocationAccuracy.best,
        activityType: geo.ActivityType.fitness,
        distanceFilter: _distanceFilter,
        pauseLocationUpdatesAutomatically: false,
        allowBackgroundLocationUpdates: true,
        showBackgroundLocationIndicator: true,
      );
    }
    return const geo.LocationSettings(accuracy: geo.LocationAccuracy.best, distanceFilter: _distanceFilter);
  }

  @override
  Stream<GpsFix> watch() => geo.Geolocator.getPositionStream(locationSettings: _settings)
      .map(
        (p) => GpsFix(
          lat: p.latitude,
          lng: p.longitude,
          // Without a vertical fix the platforms report 0 with no accuracy
          alt: p.altitude == 0 && p.altitudeAccuracy <= 0 ? null : p.altitude,
          accuracy: p.accuracy,
          speed: p.speed < 0 ? null : p.speed,
          timestamp: p.timestamp.millisecondsSinceEpoch,
        ),
      )
      .handleError((Object e) {
        if (e is geo.PermissionDeniedException) throw const GpsDeniedException();
        if (e is geo.LocationServiceDisabledException) throw const GpsUnavailableException();
        throw e;
      });
}
