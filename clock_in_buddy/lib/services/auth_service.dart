import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../config/supabase_config.dart';

typedef AuthResult = ({bool success, String? error});

class AuthService extends ChangeNotifier {
  User? _user;
  Session? _session;
  bool _loading = true;
  static const String _lastEmailKey = 'last_used_email';

  User? get user => _user;
  Session? get session => _session;
  bool get loading => _loading;
  bool get isAuthenticated => _user != null;

  AuthService() {
    _initialize();
  }

  void _initialize() {
    SupabaseConfig.client.auth.onAuthStateChange.listen((data) {
      _session = data.session;
      _user = data.session?.user;
      _loading = false;
      notifyListeners();
    });

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
    required String email,
    required String password,
    required String fullName,
  }) async {
    try {
      final response = await SupabaseConfig.client.auth.signUp(
        email: email,
        password: password,
        data: {'full_name': fullName},
      );

      if (response.user != null) {
        return (success: true, error: null);
      }
      return (success: false, error: 'Sign up failed');
    } on AuthException catch (e) {
      return (success: false, error: e.message);
    } catch (e) {
      return (success: false, error: e.toString());
    }
  }

  Future<AuthResult> signIn({
    required String email,
    required String password,
  }) async {
    try {
      final response = await SupabaseConfig.client.auth.signInWithPassword(
        email: email,
        password: password,
      );

      if (response.user != null) {
        if (response.user!.email != null) {
          await saveLastEmail(response.user!.email!);
        }
        return (success: true, error: null);
      }
      return (success: false, error: 'Sign in failed');
    } on AuthException catch (e) {
      return (success: false, error: e.message);
    } catch (e) {
      return (success: false, error: e.toString());
    }
  }

  Future<void> saveLastEmail(String email) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_lastEmailKey, email);
  }

  Future<String?> getLastEmail() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_lastEmailKey);
  }

  Future<void> signOut() async {
    await SupabaseConfig.client.auth.signOut();
    _user = null;
    _session = null;
    notifyListeners();
  }
}
