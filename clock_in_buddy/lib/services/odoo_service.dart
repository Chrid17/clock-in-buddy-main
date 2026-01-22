import 'package:flutter/foundation.dart';
import 'package:odoo_rpc/odoo_rpc.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:intl/intl.dart';

class OdooService extends ChangeNotifier {
  OdooClient? _client;
  bool _isInitialized = false;
  String? _error;

  bool get isInitialized => _isInitialized && _client != null;
  String? get error => _error;

  OdooService() {
    _init();
  }

  Future<void> _init() async {
    final url = dotenv.env['ODOO_URL'];
    if (url == null || url.isEmpty) {
      _error = 'Odoo URL not found in .env';
      debugPrint(_error);
      _isInitialized = false;
      notifyListeners();
      return;
    }
    
    try {
      _client = OdooClient(url);
      _isInitialized = true;
      notifyListeners();
    } catch (e) {
      _error = 'Failed to initialize Odoo: $e';
      debugPrint(_error);
    }
  }

  Future<bool> authenticate() async {
    _error = null;
    if (_client == null) {
      _error = 'Odoo client not initialized. Check ODOO_URL in .env';
      return false;
    }
    try {
      final db = dotenv.env['ODOO_DB'] ?? '';
      final user = dotenv.env['ODOO_USER'] ?? '';
      final password = dotenv.env['ODOO_PASSWORD'] ?? '';
      
      debugPrint('Attempting Odoo Auth - DB: $db, User: $user (password set: ${password.isNotEmpty})');
      
      if (db.isEmpty || user.isEmpty || password.isEmpty) {
        _error = 'Missing Odoo credentials in .env (DB, USER, or PASSWORD)';
        return false;
      }

      await _client!.authenticate(db, user, password);
      return true;
    } catch (e) {
      _error = 'Odoo Authentication Failed: ${e.toString()}';
      debugPrint(_error);
      return false;
    }
  }

  String _formatOdooDate(DateTime dateTime) {
    // Odoo expects UTC time in YYYY-MM-DD HH:MM:SS format
    return DateFormat('yyyy-MM-dd HH:mm:ss').format(dateTime.toUtc());
  }

  Future<int?> findEmployee({String? phone, String? name}) async {
    if (_client == null) return null;
    
    // 1. Try Phone (Literal)
    if (phone != null && phone.isNotEmpty) {
      debugPrint('Odoo Lookup: Searching by phone literal: $phone');
      try {
        final response = await _client!.callKw({
          'model': 'hr.employee',
          'method': 'search',
          'args': [
            [
              '|',
              ['work_phone', 'ilike', '%$phone%'],
              '|',
              ['mobile_phone', 'ilike', '%$phone%'],
              ['private_phone', 'ilike', '%$phone%'],
            ]
          ],
          'kwargs': {},
        });
        debugPrint('Odoo Phone Lookup Response: $response');
        if (response is List && response.isNotEmpty) return response[0] as int;
      } catch (e) {
        debugPrint('Odoo Phone Lookup Error: $e');
      }

      // 2. Try Phone (Last 9 digits - broad match)
      final digits = phone.replaceAll(RegExp(r'\D'), '');
      if (digits.length >= 7) {
        final lastPart = digits.substring(digits.length - (digits.length > 9 ? 9 : digits.length));
        debugPrint('Odoo Lookup: Searching by last ${lastPart.length} digits: $lastPart');
        try {
          final response = await _client!.callKw({
            'model': 'hr.employee',
            'method': 'search',
            'args': [
              [
                '|',
                ['work_phone', 'ilike', '%$lastPart%'],
                '|',
                ['mobile_phone', 'ilike', '%$lastPart%'],
                ['private_phone', 'ilike', '%$lastPart%'],
              ]
            ],
            'kwargs': {},
          });
          debugPrint('Odoo Broad Phone Lookup Response: $response');
          if (response is List && response.isNotEmpty) return response[0] as int;
        } catch (e) {
          debugPrint('Odoo Broad Phone Lookup Error: $e');
        }
      }
    }

    // 3. Try Name (Fallback)
    debugPrint('Odoo Lookup: Checking name fallback for: $name');
    if (name != null && name.isNotEmpty) {
      debugPrint('Odoo Lookup: Searching by name fallback: $name');
      try {
        final response = await _client!.callKw({
          'model': 'hr.employee',
          'method': 'search',
          'args': [
            [['name', 'ilike', '%$name%']]
          ],
          'kwargs': {},
        });
        debugPrint('Odoo Name Lookup Response: $response');
        if (response is List && response.isNotEmpty) return response[0] as int;
      } catch (e) {
        debugPrint('Odoo Name Lookup Error: $e');
      }
    }

    return null;
  }

  Future<bool> checkIn(int employeeId, {String? address, double? lat, double? lng}) async {
    if (_client == null) return false;
    try {
      await _client!.callKw({
        'model': 'hr.attendance',
        'method': 'create',
        'args': [
          {
            'employee_id': employeeId,
            'check_in': _formatOdooDate(DateTime.now()),
            // NOTE: Once you create the address field in Odoo (e.g., x_address), 
            // you can add it here like this:
            // 'x_address': address,
            // 'x_latitude': lat,
            // 'x_longitude': lng,
          }
        ],
        'kwargs': {},
      });
      return true;
    } catch (e) {
      debugPrint('Odoo Check-In Error: $e');
      return false;
    }
  }

  Future<bool> checkOut(int employeeId, {String? address, double? lat, double? lng}) async {
    if (_client == null) return false;
    try {
      // Find the last open attendance record
      final attendanceIds = await _client!.callKw({
        'model': 'hr.attendance',
        'method': 'search',
        'args': [
          [
            ['employee_id', '=', employeeId],
            ['check_out', '=', false],
          ]
        ],
        'kwargs': {'limit': 1},
      });

      if (attendanceIds is List && attendanceIds.isNotEmpty) {
        await _client!.callKw({
          'model': 'hr.attendance',
          'method': 'write',
          'args': [
            attendanceIds[0],
            {
              'check_out': _formatOdooDate(DateTime.now()),
              // NOTE: Once you create the address field in Odoo (e.g., x_address), 
              // you can add it here like this:
              // 'x_address': address,
            }
          ],
          'kwargs': {},
        });
        return true;
      }
      return false;
    } catch (e) {
      debugPrint('Odoo Check-Out Error: $e');
      return false;
    }
  }

  @override
  void dispose() {
    _client?.close();
    super.dispose();
  }
}
