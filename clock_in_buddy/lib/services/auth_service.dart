import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../config/supabase_config.dart';

typedef AuthResult = ({bool success, String? error});

class AuthService extends ChangeNotifier {
  User? _user;
  Session? _session;
  bool _loading = true;
  static const String _lastPhoneKey = 'last_used_phone';

  User? get user => _user;
  Session? get session => _session;
  bool get loading => _loading;
  bool get isAuthenticated => _user != null;

  AuthService() {
    _initialize();
  }

  void _initialize() {
    // Listen to auth state changes
    SupabaseConfig.client.auth.onAuthStateChange.listen((data) {
      _session = data.session;
      _user = data.session?.user;
      _loading = false;
      notifyListeners();
    });

    // Check for existing session
    _checkSession();
  }

  Future<void> _checkSession() async {
    try {
      final session = SupabaseConfig.client.auth.currentSession;
      _session = session;
      _user = session?.user;
    } catch (e) {
      debugPrint('Error checking session: $e');
    }
    _loading = false;
    notifyListeners();
  }

  Future<AuthResult> signUp({
    required String phone,
    required String password,
    required String fullName,
  }) async {
    try {
      final response = await SupabaseConfig.client.auth.signUp(
        phone: phone,
        password: password,
        data: {'full_name': fullName},
      );

      if (response.user != null) {
        return (success: true, error: null);
      }
      return (success: false, error: 'Sign up failed');
    } on AuthException catch (e) {
      if (e.message.contains('Email')) {
        return (success: false, error: e.message.replaceAll('Email', 'Phone number'));
      }
      return (success: false, error: e.message);
    } catch (e) {
      return (success: false, error: e.toString());
    }
  }

  Future<AuthResult> signIn({
    required String phone,
    required String password,
  }) async {
    try {
      final response = await SupabaseConfig.client.auth.signInWithPassword(
        phone: phone,
        password: password,
      );

      if (response.user != null) {
        if (response.user!.phone != null) {
          await saveLastPhone(response.user!.phone!);
        }
        return (success: true, error: null);
      }
      return (success: false, error: 'Sign in failed');
    } on AuthException catch (e) {
      if (e.message.contains('Email')) {
        return (success: false, error: e.message.replaceAll('Email', 'Phone number'));
      }
      return (success: false, error: e.message);
    } catch (e) {
      return (success: false, error: e.toString());
    }
  }

  Future<void> saveLastPhone(String phone) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_lastPhoneKey, phone);
  }

  Future<String?> getLastPhone() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_lastPhoneKey);
  }

  Future<void> signOut() async {
    await SupabaseConfig.client.auth.signOut();
    _user = null;
    _session = null;
    notifyListeners();
  }
}
