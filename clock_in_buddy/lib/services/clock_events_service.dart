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

  List<ClockEvent> get events => _events;
  ClockEvent? get lastEvent => _lastEvent;
  bool get loading => _loading;
  bool get isClockedIn => _lastEvent?.eventType == 'clock_in';

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
    notifyListeners();

    try {
      final response = await SupabaseConfig.client
          .from('clock_events')
          .select()
          .eq('user_id', _userId!)
          .order('created_at', ascending: false)
          .limit(50);

      _events = (response as List)
          .map((json) => ClockEvent.fromJson(json as Map<String, dynamic>))
          .toList();
      _lastEvent = _events.isNotEmpty ? _events.first : null;
    } catch (e) {
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
    debugPrint('Service: Attempting to delete event with ID: $id');
    try {
      final response = await SupabaseConfig.client
          .from('clock_events')
          .delete()
          .eq('id', id)
          .select(); // Using select() to confirm if a row was actually deleted

      if (response.isEmpty) {
        debugPrint('Service: Deletion failed or RLS blocked it. No rows affected.');
        return (success: false, error: 'Deletion failed. Please check table RLS policies.');
      }

      debugPrint('Service: Successfully deleted event: ${response.first}');
      await fetchEvents();
      return (success: true, error: null);
    } catch (e) {
      debugPrint('Service: Error deleting event: $e');
      return (success: false, error: e.toString());
    }
  }

  Future<void> exportToCsv(String fullName) async {
    if (_events.isEmpty) return;

    // 1. Prepare data
    List<List<dynamic>> rows = [];
    rows.add([
      'Date',
      'Time',
      'Employee',
      'Event Type',
      'Address',
      'Latitude',
      'Longitude',
      
    ]);

    final dateFormat = DateFormat('dd/MM/yyyy');
    final timeFormat = DateFormat('HH:mm:ss');

    for (var event in _events) {
      rows.add([
        dateFormat.format(event.createdAt),
        timeFormat.format(event.createdAt),
        fullName,
        event.eventType == 'clock_in' ? 'Clock In' : 'Clock Out',
        event.address ?? '',
        event.latitude ?? '',
        event.longitude ?? '',
        event.notes ?? ''
      ]);
    }

    // 2. Convert to CSV
    String csvData = const ListToCsvConverter().convert(rows);

    // 3. Save/Download
    if (kIsWeb) {
      _downloadWeb(csvData);
    } else {
      await _saveFile(csvData);
    }
  }

  Future<void> _downloadWeb(String csvData) async {
    final bytes = utf8.encode(csvData);
    final base64 = base64Encode(bytes);
    final url = 'data:text/csv;base64,$base64';
    
    if (await canLaunchUrl(Uri.parse(url))) {
      await launchUrl(Uri.parse(url));
    } else {
      debugPrint('Could not launch CSV download URL');
    }
  }

  Future<void> _saveFile(String csvData) async {
    String? outputFile = await FilePicker.platform.saveFile(
      dialogTitle: 'Please select where to save your CSV file:',
      fileName: 'clock_history_${DateTime.now().millisecondsSinceEpoch}.csv',
      type: FileType.custom,
      allowedExtensions: ['csv'],
    );

    if (outputFile != null) {
      final file = io.File(outputFile);
      await file.writeAsString(csvData);
    }
  }
}
