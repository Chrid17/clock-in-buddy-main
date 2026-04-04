import 'package:flutter/foundation.dart';
import 'dart:convert';
import 'package:csv/csv.dart';
import 'package:file_picker/file_picker.dart';
import 'package:intl/intl.dart';
import 'dart:io' as io;
import 'package:url_launcher/url_launcher.dart';
import '../config/supabase_config.dart';
import '../models/clock_event.dart';

class ClockEventsService extends ChangeNotifier {
  List<ClockEvent> _events = [];
  ClockEvent? _lastEvent;
  bool _loading = true;
  String? _userId;
  String? _error;

  List<ClockEvent> get events => _events;
  ClockEvent? get lastEvent => _lastEvent;
  bool get loading => _loading;
  String? get error => _error;
  bool get isClockedIn => _lastEvent?.eventType == 'clock_in';

  Duration get todayWorkedDuration {
    final now = DateTime.now();
    final todayStart = DateTime(now.year, now.month, now.day);
    final todayEvents = _events
        .where((e) => e.createdAt.isAfter(todayStart))
        .toList()
      ..sort((a, b) => a.createdAt.compareTo(b.createdAt));

    var total = Duration.zero;
    DateTime? clockInTime;

    for (final event in todayEvents) {
      if (event.eventType == 'clock_in') {
        clockInTime = event.createdAt;
      } else if (event.eventType == 'clock_out' && clockInTime != null) {
        total += event.createdAt.difference(clockInTime);
        clockInTime = null;
      }
    }

    if (clockInTime != null) {
      total += now.difference(clockInTime);
    }

    return total;
  }

  void setUserId(String? userId) {
    if (_userId != userId) {
      _userId = userId;
      if (userId != null) {
        fetchEvents();
      } else {
        _events = [];
        _lastEvent = null;
        _loading = false;
        notifyListeners();
      }
    }
  }

  Future<void> fetchEvents() async {
    if (_userId == null) {
      _events = [];
      _lastEvent = null;
      _loading = false;
      notifyListeners();
      return;
    }

    _loading = true;
    _error = null;
    notifyListeners();

    try {
      final response = await SupabaseConfig.client
          .from('clock_events')
          .select()
          .eq('user_id', _userId!)
          .order('created_at', ascending: false)
          .limit(100);

      _events = (response as List)
          .map((json) => ClockEvent.fromJson(json as Map<String, dynamic>))
          .toList();
      _lastEvent = _events.isNotEmpty ? _events.first : null;
    } catch (e) {
      _error = 'Could not load events. Pull down to retry.';
      debugPrint('Error fetching events: $e');
    }

    _loading = false;
    notifyListeners();
  }

  Future<({bool success, String? error})> createClockEvent({
    required String eventType,
    String? photoBase64,
    double? latitude,
    double? longitude,
    String? address,
    String? notes,
  }) async {
    if (_userId == null) {
      return (success: false, error: 'Not authenticated');
    }

    try {
      await SupabaseConfig.client.from('clock_events').insert({
        'user_id': _userId,
        'event_type': eventType,
        'photo_url': photoBase64,
        'latitude': latitude,
        'longitude': longitude,
        'address': address,
        'notes': notes,
      });

      await fetchEvents();
      return (success: true, error: null);
    } catch (e) {
      debugPrint('Error creating event: $e');
      return (success: false, error: e.toString());
    }
  }

  Future<({bool success, String? error})> deleteClockEvent(String id) async {
    try {
      final response = await SupabaseConfig.client
          .from('clock_events')
          .delete()
          .eq('id', id)
          .select();

      if (response.isEmpty) {
        return (success: false, error: 'Deletion failed. Please check table RLS policies.');
      }

      await fetchEvents();
      return (success: true, error: null);
    } catch (e) {
      debugPrint('Error deleting event: $e');
      return (success: false, error: e.toString());
    }
  }

  Future<({bool success, String? error})> exportToCsv(String fullName) async {
    if (_events.isEmpty) {
      return (success: false, error: 'No events to export');
    }

    try {
      List<List<dynamic>> rows = [];
      rows.add([
        'Date',
        'Time',
        'Employee',
        'Event Type',
        'Address',
        'Latitude',
        'Longitude',
        'Notes',
      ]);

      final dateFormat = DateFormat('dd/MM/yyyy');
      final timeFormat = DateFormat('HH:mm:ss');

      for (var event in _events) {
        rows.add([
          dateFormat.format(event.createdAt.toLocal()),
          timeFormat.format(event.createdAt.toLocal()),
          fullName,
          event.eventType == 'clock_in' ? 'Clock In' : 'Clock Out',
          event.address ?? '',
          event.latitude ?? '',
          event.longitude ?? '',
          event.notes ?? '',
        ]);
      }

      String csvData = const ListToCsvConverter().convert(rows);

      if (kIsWeb) {
        await _downloadWeb(csvData);
      } else {
        await _saveFile(csvData);
      }
      return (success: true, error: null);
    } catch (e) {
      debugPrint('Export error: $e');
      return (success: false, error: 'Failed to export: $e');
    }
  }

  Future<void> _downloadWeb(String csvData) async {
    final bytes = utf8.encode(csvData);
    final base64Data = base64Encode(bytes);
    final url = 'data:text/csv;base64,$base64Data';
    
    if (await canLaunchUrl(Uri.parse(url))) {
      await launchUrl(Uri.parse(url));
    } else {
      throw Exception('Could not download CSV');
    }
  }

  Future<void> _saveFile(String csvData) async {
    String? outputFile = await FilePicker.platform.saveFile(
      dialogTitle: 'Save clock history as CSV',
      fileName: 'clock_history_${DateFormat('yyyy-MM-dd').format(DateTime.now())}.csv',
      type: FileType.custom,
      allowedExtensions: ['csv'],
    );

    if (outputFile != null) {
      final file = io.File(outputFile);
      await file.writeAsString(csvData);
    }
  }
}
