import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart';
import 'package:http/http.dart' as http;

class LocationFix {
  const LocationFix({
    required this.latitude,
    required this.longitude,
    required this.accuracyM,
    required this.isMocked,
    required this.capturedAt,
  });

  final double latitude;
  final double longitude;
  final double accuracyM;

  /// True on Android when the position came from a fake-GPS app.
  final bool isMocked;
  final DateTime capturedAt;
}

class LocationException implements Exception {
  const LocationException(this.message, {this.fix = LocationFixAction.none});
  final String message;
  final LocationFixAction fix;

  @override
  String toString() => message;
}

enum LocationFixAction { none, enableServices, openAppSettings }

class LocationService {
  /// Gets one accurate position, asking for permission if needed.
  Future<LocationFix> currentFix() async {
    try {
      if (!await Geolocator.isLocationServiceEnabled()) {
        throw const LocationException(
          'Location is turned off. Turn it on to clock in or out.',
          fix: LocationFixAction.enableServices,
        );
      }
    } on LocationException {
      rethrow;
    } catch (_) {
      // Some browsers can't report this; asking for a position still works.
    }

    var permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
    }
    if (permission == LocationPermission.denied) {
      throw const LocationException(
        'Location permission is needed to prove where you clocked in.',
      );
    }
    if (permission == LocationPermission.deniedForever) {
      throw const LocationException(
        'Location permission is blocked. Allow it in Settings to clock in or out.',
        fix: LocationFixAction.openAppSettings,
      );
    }

    try {
      final position = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.best,
          timeLimit: Duration(seconds: 30),
        ),
      );
      return LocationFix(
        latitude: position.latitude,
        longitude: position.longitude,
        accuracyM: position.accuracy,
        isMocked: position.isMocked,
        capturedAt: DateTime.now(),
      );
    } on TimeoutException {
      throw const LocationException(
          'Could not get a GPS fix. Move near a window or outside and try again.');
    } catch (e) {
      debugPrint('Location error: $e');
      throw const LocationException('Could not get your location. Please try again.');
    }
  }

  Future<void> openSettings(LocationFixAction action) async {
    try {
      if (action == LocationFixAction.enableServices) {
        await Geolocator.openLocationSettings();
      } else if (action == LocationFixAction.openAppSettings) {
        await Geolocator.openAppSettings();
      }
    } catch (_) {
      // Not available on the web.
    }
  }

  /// Street address for a position (OpenStreetMap Nominatim). Returns null
  /// when offline or when the lookup fails.
  Future<String?> addressFor(double latitude, double longitude) async {
    try {
      final uri = Uri.https('nominatim.openstreetmap.org', '/reverse', {
        'format': 'jsonv2',
        'lat': '$latitude',
        'lon': '$longitude',
        'zoom': '18',
        'addressdetails': '0',
      });
      final response = await http.get(uri, headers: {
        if (!kIsWeb) 'User-Agent': 'ClockInBuddy/2.0 (attendance app)',
        'Accept-Language': 'en',
      }).timeout(const Duration(seconds: 8));
      if (response.statusCode != 200) return null;
      final data = jsonDecode(response.body);
      return data is Map ? data['display_name'] as String? : null;
    } catch (_) {
      return null;
    }
  }
}
