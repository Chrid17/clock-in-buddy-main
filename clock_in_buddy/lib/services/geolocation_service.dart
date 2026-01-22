import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart';
import 'package:http/http.dart' as http;

class GeolocationService {
  double? _latitude;
  double? _longitude;
  String? _address;
  bool _loading = false;
  String? _error;

  double? get latitude => _latitude;
  double? get longitude => _longitude;
  String? get address => _address;
  bool get loading => _loading;
  String? get error => _error;

  Future<void> getLocation() async {
    _loading = true;
    _error = null;

    try {
      // Check if location services are enabled
      bool serviceEnabled = await Geolocator.isLocationServiceEnabled();
      if (!serviceEnabled) {
        _error = 'Location services are disabled';
        _loading = false;
        return;
      }

      // Check and request permissions
      LocationPermission permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
        if (permission == LocationPermission.denied) {
          _error = 'Location permission denied. Please enable location access.';
          _loading = false;
          return;
        }
      }

      if (permission == LocationPermission.deniedForever) {
        _error = 'Location permission permanently denied. Please enable in settings.';
        _loading = false;
        return;
      }

      // Get current position
      final position = await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.high,
        timeLimit: const Duration(seconds: 10),
      );

      _latitude = position.latitude;
      _longitude = position.longitude;

      // Reverse geocode to get address using OpenStreetMap Nominatim
      await _reverseGeocode();
    } catch (e) {
      _error = 'Unable to get location';
      debugPrint('Geolocation error: $e');
    }

    _loading = false;
  }

  Future<void> _reverseGeocode() async {
    if (_latitude == null || _longitude == null) return;

    try {
      final url = Uri.parse(
        'https://nominatim.openstreetmap.org/reverse?format=json&lat=$_latitude&lon=$_longitude',
      );
      
      final response = await http.get(
        url,
        headers: {'User-Agent': 'ClockInBuddy/1.0'},
      );

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        _address = data['display_name'] as String?;
      }
    } catch (e) {
      debugPrint('Could not fetch address: $e');
    }
  }

  void reset() {
    _latitude = null;
    _longitude = null;
    _address = null;
    _error = null;
    _loading = false;
  }
}
