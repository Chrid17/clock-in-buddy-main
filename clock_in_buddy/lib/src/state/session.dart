import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../api/attendance_api.dart';
import '../models.dart';

/// Sign-in state and the signed-in staff member's profile.
class Session extends ChangeNotifier {
  Session(this._auth, this.api) {
    _sub = _auth.onAuthStateChange.listen((state) => _setUser(state.session?.user));
    _setUser(_auth.currentUser);
  }

  final GoTrueClient _auth;
  final AttendanceApi api;
  StreamSubscription<AuthState>? _sub;

  User? _user;
  StaffProfile? _profile;
  bool _loadingProfile = false;
  String? _profileError;

  User? get user => _user;
  String? get userId => _user?.id;
  StaffProfile? get profile => _profile;
  bool get isSignedIn => _user != null;
  bool get isAdmin => _profile?.isAdmin ?? false;
  bool get loadingProfile => _loadingProfile;
  String? get profileError => _profileError;
  String get displayName =>
      _profile?.fullName ??
      (_user?.userMetadata?['full_name'] as String?) ??
      _user?.email ??
      'there';

  /// A valid access token for [auth], refreshed when it has expired.
  static Future<String?> accessTokenFor(GoTrueClient auth) async {
    var session = auth.currentSession;
    if (session == null) return null;
    if (session.isExpired) {
      try {
        session = (await auth.refreshSession()).session;
      } catch (_) {
        return null;
      }
    }
    return session?.accessToken;
  }

  void _setUser(User? user) {
    final changed = user?.id != _user?.id;
    _user = user;
    if (user == null) {
      _profile = null;
      _profileError = null;
    }
    notifyListeners();
    if (changed && user != null) loadProfile();
  }

  Future<void> loadProfile() async {
    final id = _user?.id;
    if (id == null) return;
    _loadingProfile = true;
    _profileError = null;
    notifyListeners();
    try {
      _profile = await api.getProfile(id);
      if (_profile == null) {
        _profileError = 'Your staff profile is missing. Ask your manager to run the database setup.';
      }
    } on ApiException catch (e) {
      _profileError = e.message;
    } catch (e) {
      _profileError = 'Could not load your profile.';
    }
    _loadingProfile = false;
    notifyListeners();
  }

  Future<void> updateProfile({required String fullName, String? jobTitle}) async {
    final id = _user?.id;
    if (id == null) return;
    await api.updateMyProfile(id, fullName: fullName, jobTitle: jobTitle);
    await loadProfile();
  }

  // ---------------------------------------------------------------------------
  // Sign in / sign up
  // ---------------------------------------------------------------------------

  /// Returns null on success, otherwise a message for the user.
  Future<String?> signIn(String email, String password) => _guard(() async {
        await _auth.signInWithPassword(email: email.trim(), password: password);
        return null;
      });

  /// Returns null when signed in straight away, or a message (for example
  /// "check your email") otherwise.
  Future<String?> signUp(String fullName, String email, String password) => _guard(() async {
        final response = await _auth.signUp(
          email: email.trim(),
          password: password,
          data: {'full_name': fullName.trim()},
        );
        if (response.session == null) {
          return 'Account created. Check your email to confirm it, then sign in.';
        }
        return null;
      });

  Future<String?> resetPassword(String email) => _guard(() async {
        await _auth.resetPasswordForEmail(email.trim());
        return 'If that email has an account, a reset link is on its way.';
      });

  Future<void> signOut() async {
    try {
      await _auth.signOut();
    } catch (_) {
      _setUser(null);
    }
  }

  Future<String?> _guard(Future<String?> Function() action) async {
    try {
      return await action();
    } on AuthException catch (e) {
      final m = e.message.toLowerCase();
      if (m.contains('invalid login')) return 'Wrong email or password.';
      if (m.contains('email not confirmed')) {
        return 'Please confirm your email first (check your inbox).';
      }
      return e.message;
    } catch (e) {
      final text = e.toString();
      if (text.contains('SocketException') || text.contains('ClientException')) {
        return 'No internet connection.';
      }
      return 'Something went wrong. Please try again.';
    }
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }
}
