import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../models.dart';

/// Clock actions captured without internet, kept on the device until they
/// can be uploaded. Stored per user.
class OfflineQueue {
  static String _key(String userId) => 'pending_clocks_v2.$userId';

  Future<List<ClockDraft>> load(String userId) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_key(userId));
      if (raw == null || raw.isEmpty) return [];
      return (jsonDecode(raw) as List)
          .whereType<Map>()
          .map((m) => ClockDraft.fromJson(Map<String, dynamic>.from(m)))
          .toList();
    } catch (_) {
      return [];
    }
  }

  Future<void> save(String userId, List<ClockDraft> drafts) async {
    final prefs = await SharedPreferences.getInstance();
    if (drafts.isEmpty) {
      await prefs.remove(_key(userId));
    } else {
      await prefs.setString(_key(userId), jsonEncode(drafts.map((d) => d.toJson()).toList()));
    }
  }
}
