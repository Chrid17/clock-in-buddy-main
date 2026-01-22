import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:flutter_dotenv/flutter_dotenv.dart';

class OdooService extends ChangeNotifier {
  String? _error;
  String? get error => _error;

  String get _url => dotenv.env['ODOO_URL'] ?? '';
  String get _db => dotenv.env['ODOO_DB'] ?? '';
  String get _user => dotenv.env['ODOO_USER'] ?? '';
  String get _password => dotenv.env['ODOO_PASSWORD'] ?? '';

  /// Syncs a clock event directly to Odoo.
  Future<bool> syncClockEvent({
    required String eventType,
    String? phone,
    String? name,
    double? lat,
    double? lng,
    String? address,
  }) async {
    _error = null;
    try {
      if (_url.isEmpty || _db.isEmpty || _user.isEmpty || _password.isEmpty) {
        throw Exception('Odoo configuration missing in .env');
      }

      // 1. Authenticate
      final authResponse = await http.post(
        Uri.parse('$_url/web/session/authenticate'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'jsonrpc': '2.0',
          'params': {
            'db': _db,
            'login': _user,
            'password': _password,
          }
        }),
      );

      final authData = jsonDecode(authResponse.body);
      if (authData['error'] != null) {
        throw Exception('Odoo Auth Failed: ${authData['error']['data']?['message'] ?? authData['error']['message']}');
      }

      final sessionId = authResponse.headers['set-cookie']?.split(';')[0];
      if (sessionId == null) {
        throw Exception('Did not receive session ID from Odoo');
      }

      // Helper for Odoo calls
      Future<dynamic> odooCall(String model, String method, List args, {Map kwargs = const {}}) async {
        final res = await http.post(
          Uri.parse('$_url/web/dataset/call_kw'),
          headers: {
            'Content-Type': 'application/json',
            'Cookie': sessionId,
          },
          body: jsonEncode({
            'jsonrpc': '2.0',
            'params': {
              'model': model,
              'method': method,
              'args': args,
              'kwargs': kwargs,
            }
          }),
        );
        final data = jsonDecode(res.body);
        if (data['error'] != null) {
          throw Exception('Odoo Call Failed ($model.$method): ${data['error']['data']?['message'] ?? data['error']['message']}');
        }
        return data['result'];
      }

      // 2. Find Employee
      int? employeeId;

      if (phone != null && phone.isNotEmpty) {
        final last9 = phone.replaceAll(RegExp(r'\D'), '');
        final phoneSegment = last9.length >= 9 ? last9.substring(last9.length - 9) : last9;
        final phoneDomain = [
          '|', ['work_phone', 'ilike', '%$phoneSegment%'],
          '|', ['mobile_phone', 'ilike', '%$phoneSegment%'],
          ['private_phone', 'ilike', '%$phoneSegment%']
        ];
        final results = await odooCall('hr.employee', 'search', [phoneDomain]);
        if (results is List && results.isNotEmpty) employeeId = results[0];
      }

      if (employeeId == null && name != null && name.isNotEmpty) {
        final results = await odooCall('hr.employee', 'search', [[['name', 'ilike', '%$name%']]]);
        if (results is List && results.isNotEmpty) employeeId = results[0];
      }

      if (employeeId == null) {
        throw Exception('Employee not found in Odoo');
      }

      // 3. Sync Clock Event
      final odooTime = DateTime.now().toUtc().toIso8601String().split('.')[0].replaceAll('T', ' ');

      if (eventType == 'clock_in') {
        await odooCall('hr.attendance', 'create', [{
          'employee_id': employeeId,
          'check_in': odooTime,
        }]);
      } else {
        // Find open attendance
        final attendanceIds = await odooCall('hr.attendance', 'search', [[
          ['employee_id', '=', employeeId],
          ['check_out', '=', false]
        ]], kwargs: {'limit': 1});

        if (attendanceIds is List && attendanceIds.isNotEmpty) {
          await odooCall('hr.attendance', 'write', [
            attendanceIds[0],
            {'check_out': odooTime}
          ]);
        } else {
          throw Exception('No open clock-in record found in Odoo');
        }
      }

      return true;
    } catch (e) {
      _error = e.toString().replaceFirst('Exception: ', '');
      debugPrint('Odoo Sync Error: $e');
      return false;
    }
  }
}
