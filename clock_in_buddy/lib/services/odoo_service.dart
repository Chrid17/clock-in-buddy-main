import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../config/supabase_config.dart';

class OdooService extends ChangeNotifier {
  String? _error;
  String? get error => _error;

  /// Syncs a clock event to Odoo via a secure Supabase Edge Function.
  /// This keeps the Odoo credentials hidden from the client app.
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
      final response = await SupabaseConfig.client.functions.invoke(
        'odoo-sync',
        body: {
          'phone': phone,
          'name': name,
          'eventType': eventType,
          'lat': lat,
          'lng': lng,
          'address': address,
        },
      );

      if (response.status != 200) {
        final data = response.data as Map<String, dynamic>;
        _error = data['error'] ?? 'Failed to sync with Odoo';
        return false;
      }

      return true;
    } catch (e) {
      _error = e.toString();
      debugPrint('Odoo Sync Error: $e');
      return false;
    }
  }
}
