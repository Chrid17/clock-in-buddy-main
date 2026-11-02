import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../api/attendance_api.dart';
import '../models.dart';
import '../services/offline_queue.dart';
import '../utils.dart';

enum SubmitOutcome { recorded, queued, failed }

class SubmitResult {
  const SubmitResult(this.outcome, {this.event, this.message});

  final SubmitOutcome outcome;
  final AttendanceEvent? event;
  final String? message;
}

/// The signed-in staff member's attendance: status, recent history,
/// clocking in and out, and the offline queue.
class AttendanceController extends ChangeNotifier {
  AttendanceController({required this.api, OfflineQueue? queue})
      : _queue = queue ?? OfflineQueue();

  final AttendanceApi api;
  final OfflineQueue _queue;

  String? _userId;
  List<AttendanceEvent> _events = [];
  List<ClockDraft> _pending = [];
  List<WorkSite> _sites = [];
  bool _loading = false;
  bool _syncing = false;
  String? _error;
  String? _syncError;
  _CachedState? _cached;

  /// Recent events (about two months), newest first.
  List<AttendanceEvent> get events => List.unmodifiable(_events);
  List<ClockDraft> get pending => List.unmodifiable(_pending);
  List<WorkSite> get sites => List.unmodifiable(_sites);
  bool get loading => _loading;
  bool get syncing => _syncing;
  String? get error => _error;
  String? get syncError => _syncError;

  /// Recorded events plus queued ones, newest first.
  List<AttendanceEvent> get timeline {
    final queued = _pending.reversed.map(_draftAsEvent);
    return [...queued, ..._events];
  }

  ClockType? get lastType {
    if (_pending.isNotEmpty) return _pending.last.type;
    if (_events.isNotEmpty) return _events.first.type;
    return _cached?.type;
  }

  bool get isClockedIn => lastType == ClockType.clockIn;
  ClockType get nextAction => isClockedIn ? ClockType.clockOut : ClockType.clockIn;

  DateTime? get clockedInSince {
    if (!isClockedIn) return null;
    if (_pending.isNotEmpty) return _pending.last.deviceTime;
    if (_events.isNotEmpty) return _events.first.effectiveTime;
    return _cached?.time;
  }

  String? get currentSiteName {
    if (!isClockedIn || _pending.isNotEmpty) return null;
    if (_events.isNotEmpty) return _events.first.siteName;
    return _cached?.siteName;
  }

  Duration workedOn(DateTime day, {DateTime? now}) {
    final start = dateOnly(day);
    return workedBetween(timeline, start, start.add(const Duration(days: 1)), now: now);
  }

  Duration workedThisWeek({DateTime? now}) {
    final current = now ?? DateTime.now();
    final monday = dateOnly(current).subtract(Duration(days: current.weekday - 1));
    return workedBetween(timeline, monday, monday.add(const Duration(days: 7)), now: current);
  }

  List<AttendanceEvent> eventsOn(DateTime day) {
    final start = dateOnly(day);
    final end = start.add(const Duration(days: 1));
    return timeline
        .where((e) => !e.effectiveTime.isBefore(start) && e.effectiveTime.isBefore(end))
        .toList();
  }

  // ---------------------------------------------------------------------------
  // Loading
  // ---------------------------------------------------------------------------

  Future<void> bindUser(String? userId) async {
    if (userId == _userId) return;
    _userId = userId;
    _events = [];
    _pending = [];
    _sites = [];
    _error = null;
    _syncError = null;
    _cached = null;
    notifyListeners();
    if (userId == null) return;
    _pending = await _queue.load(userId);
    _cached = await _CachedState.load(userId);
    notifyListeners();
    await refresh();
  }

  Future<void> refresh() async {
    final uid = _userId;
    if (uid == null || _loading) return;
    _loading = true;
    _error = null;
    notifyListeners();
    try {
      await syncPending();
      final events = await api.listEvents(
        userId: uid,
        from: DateTime.now().subtract(const Duration(days: 62)),
      );
      if (uid != _userId) return;
      _events = events;
      await _rememberState();
      try {
        _sites = await api.listSites();
      } catch (_) {
        // Sites are only used for the distance preview.
      }
    } on ApiException catch (e) {
      _error = e.isNetwork ? 'You are offline. Clock-ins will be saved and uploaded later.' : e.message;
    } catch (e) {
      debugPrint('refresh failed: $e');
      _error = 'Could not load your attendance.';
    } finally {
      _loading = false;
      notifyListeners();
    }
  }

  // ---------------------------------------------------------------------------
  // Clocking
  // ---------------------------------------------------------------------------

  Future<SubmitResult> submit(ClockDraft draft) async {
    final uid = _userId;
    if (uid == null) {
      return const SubmitResult(SubmitOutcome.failed, message: 'You are not signed in.');
    }

    // Keep the order: anything captured earlier must reach the server first.
    if (_pending.isNotEmpty) {
      _pending.add(draft);
      await _queue.save(uid, _pending);
      notifyListeners();
      await syncPending();
      return _pending.any((d) => d.id == draft.id)
          ? const SubmitResult(SubmitOutcome.queued)
          : SubmitResult(SubmitOutcome.recorded, event: _events.isEmpty ? null : _events.first);
    }

    try {
      final event = await _upload(uid, draft, offline: false);
      _events.insert(0, event);
      await _rememberState();
      notifyListeners();
      unawaited(api.requestOdooSync(event.id));
      return SubmitResult(SubmitOutcome.recorded, event: event);
    } on ApiException catch (e) {
      if (e.isNetwork) {
        _pending.add(draft);
        await _queue.save(uid, _pending);
        notifyListeners();
        return const SubmitResult(SubmitOutcome.queued);
      }
      return SubmitResult(SubmitOutcome.failed, message: e.message);
    } catch (e) {
      debugPrint('submit failed: $e');
      return const SubmitResult(SubmitOutcome.failed,
          message: 'Could not record your attendance. Please try again.');
    }
  }

  /// Uploads queued clock actions in order. Returns how many were recorded.
  Future<int> syncPending() async {
    final uid = _userId;
    if (uid == null || _pending.isEmpty || _syncing) return 0;
    _syncing = true;
    _syncError = null;
    notifyListeners();
    var recorded = 0;
    try {
      while (_pending.isNotEmpty && uid == _userId) {
        final draft = _pending.first;
        try {
          final event = await _upload(uid, draft, offline: true);
          _events.insert(0, event);
          recorded++;
          unawaited(api.requestOdooSync(event.id));
        } on ApiException catch (e) {
          if (e.isNetwork || e.isAuth) {
            if (e.isAuth) _syncError = e.message;
            break;
          }
          // The server refused it (for example "already clocked in"); drop it
          // so it does not block the rest, and tell the user.
          _syncError = 'A saved ${draft.type.label.toLowerCase()} from '
              '${formatDate(draft.deviceTime)} ${formatTime(draft.deviceTime)} '
              'was not accepted: ${e.message}';
        }
        _pending.removeAt(0);
        await _queue.save(uid, _pending);
        notifyListeners();
      }
      _events.sort((a, b) => b.serverTime.compareTo(a.serverTime));
      await _rememberState();
    } finally {
      _syncing = false;
      notifyListeners();
    }
    return recorded;
  }

  Future<AttendanceEvent> _upload(String uid, ClockDraft draft, {required bool offline}) async {
    final path = await api.uploadPhoto(uid, draft.photo);
    return api.clock(
      type: draft.type,
      latitude: draft.latitude,
      longitude: draft.longitude,
      accuracyM: draft.accuracyM,
      isMocked: draft.isMocked,
      photoPath: path,
      photoSha256: draft.photoSha256,
      deviceTime: draft.deviceTime,
      platform: draft.platform,
      address: draft.address,
      notes: draft.notes,
      capturedOffline: offline,
    );
  }

  AttendanceEvent _draftAsEvent(ClockDraft d) => AttendanceEvent(
        id: 'pending-${d.id}',
        userId: _userId ?? '',
        type: d.type,
        serverTime: d.deviceTime,
        deviceTime: d.deviceTime,
        latitude: d.latitude,
        longitude: d.longitude,
        accuracyM: d.accuracyM,
        isMocked: d.isMocked,
        address: d.address,
        notes: d.notes,
        platform: d.platform,
        capturedOffline: true,
        flags: const ['offline'],
      );

  Future<void> _rememberState() async {
    final uid = _userId;
    if (uid == null || _events.isEmpty) return;
    final last = _events.first;
    _cached = _CachedState(last.type, last.effectiveTime, last.siteName);
    await _cached!.save(uid);
  }

  /// Called after a manager review so the change shows immediately.
  void replaceEvent(AttendanceEvent updated) {
    final i = _events.indexWhere((e) => e.id == updated.id);
    if (i != -1) {
      _events[i] = updated;
      notifyListeners();
    }
  }
}

/// The last known status, so the right button shows when the app opens
/// without internet.
class _CachedState {
  const _CachedState(this.type, this.time, this.siteName);

  final ClockType type;
  final DateTime time;
  final String? siteName;

  static String _key(String uid) => 'last_clock_state_v2.$uid';

  Future<void> save(String uid) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        _key(uid),
        jsonEncode({'type': type.apiValue, 'time': time.toUtc().toIso8601String(), 'site': siteName}),
      );
    } catch (_) {}
  }

  static Future<_CachedState?> load(String uid) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_key(uid));
      if (raw == null) return null;
      final data = jsonDecode(raw) as Map<String, dynamic>;
      return _CachedState(
        ClockType.fromApi(data['type']),
        DateTime.parse(data['time'] as String).toLocal(),
        data['site'] as String?,
      );
    } catch (_) {
      return null;
    }
  }
}
