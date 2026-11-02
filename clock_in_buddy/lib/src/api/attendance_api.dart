import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import '../config.dart';
import '../models.dart';

/// A failed API call, with a message that can be shown to the user.
class ApiException implements Exception {
  const ApiException(this.message, {this.statusCode, this.isNetwork = false});

  final String message;
  final int? statusCode;

  /// True when the request never reached the server (offline, timeout).
  final bool isNetwork;

  bool get isAuth => statusCode == 401;

  @override
  String toString() => message;
}

typedef TokenProvider = Future<String?> Function();

/// REST client for the attendance backend.
///
/// Endpoints (Supabase):
///   PostgREST  /rest/v1/...           tables and RPC functions
///   Storage    /storage/v1/object/... verification photos
///   Functions  /functions/v1/...      Odoo sync
class AttendanceApi {
  AttendanceApi({
    required this.baseUrl,
    required this.apiKey,
    required this.tokenProvider,
    http.Client? client,
    this.timeout = const Duration(seconds: 30),
  }) : _http = client ?? http.Client();

  final String baseUrl;
  final String apiKey;
  final TokenProvider tokenProvider;
  final Duration timeout;
  final http.Client _http;
  final Random _random = Random();

  // ---------------------------------------------------------------------------
  // Plumbing
  // ---------------------------------------------------------------------------

  Uri _uri(String path, [Map<String, dynamic>? query]) {
    final base = Uri.parse(baseUrl.endsWith('/') ? baseUrl.substring(0, baseUrl.length - 1) : baseUrl);
    return base.replace(
      path: '${base.path}$path',
      queryParameters: query == null || query.isEmpty ? null : query,
    );
  }

  Future<Map<String, String>> _headers({
    String contentType = 'application/json',
    Map<String, String> extra = const {},
  }) async {
    final token = await tokenProvider();
    if (token == null || token.isEmpty) {
      throw const ApiException('Your session has expired. Please sign in again.',
          statusCode: 401);
    }
    return {
      'apikey': apiKey,
      'Authorization': 'Bearer $token',
      'Content-Type': contentType,
      'Accept': 'application/json',
      ...extra,
    };
  }

  Future<http.Response> _send(Future<http.Response> Function() request) async {
    http.Response response;
    try {
      response = await request().timeout(timeout);
    } on TimeoutException {
      throw const ApiException(
          'The server took too long to respond. Check your internet connection.',
          isNetwork: true);
    } on http.ClientException {
      throw const ApiException('No internet connection.', isNetwork: true);
    }
    if (response.statusCode >= 200 && response.statusCode < 300) return response;
    throw _errorFrom(response);
  }

  ApiException _errorFrom(http.Response r) {
    String? message;
    try {
      final body = jsonDecode(r.body);
      if (body is Map) {
        message = (body['message'] ?? body['error_description'] ?? body['msg'] ?? body['error'])
            ?.toString();
      }
    } catch (_) {
      // Not JSON.
    }
    if (r.statusCode == 401 || (r.statusCode == 403 && (message ?? '').contains('JWT'))) {
      return const ApiException('Your session has expired. Please sign in again.',
          statusCode: 401);
    }
    if (r.statusCode >= 500) {
      return ApiException('The server had a problem (${r.statusCode}). Please try again.',
          statusCode: r.statusCode);
    }
    return ApiException(
      message == null || message.isEmpty ? 'Request failed (${r.statusCode}).' : message,
      statusCode: r.statusCode,
    );
  }

  Future<dynamic> _get(String path, [Map<String, dynamic>? query]) async {
    final headers = await _headers();
    final r = await _send(() => _http.get(_uri(path, query), headers: headers));
    return r.body.isEmpty ? null : jsonDecode(r.body);
  }

  Future<dynamic> _post(String path, Object? body,
      {Map<String, dynamic>? query, Map<String, String> extra = const {}}) async {
    final headers = await _headers(extra: extra);
    final r = await _send(
        () => _http.post(_uri(path, query), headers: headers, body: jsonEncode(body)));
    return r.body.isEmpty ? null : jsonDecode(r.body);
  }

  Future<void> _patch(String path, Map<String, dynamic> query, Object body) async {
    final headers = await _headers(extra: {'Prefer': 'return=minimal'});
    await _send(() => _http.patch(_uri(path, query), headers: headers, body: jsonEncode(body)));
  }

  Future<void> _delete(String path, Map<String, dynamic> query) async {
    final headers = await _headers(extra: {'Prefer': 'return=minimal'});
    await _send(() => _http.delete(_uri(path, query), headers: headers));
  }

  static String _iso(DateTime t) => t.toUtc().toIso8601String();

  // ---------------------------------------------------------------------------
  // Profile
  // ---------------------------------------------------------------------------

  Future<StaffProfile?> getProfile(String userId) async {
    final rows = await _get('/rest/v1/profiles', {
      'select': '*',
      'user_id': 'eq.$userId',
      'limit': '1',
    }) as List;
    if (rows.isEmpty) return null;
    return StaffProfile.fromJson(Map<String, dynamic>.from(rows.first as Map));
  }

  Future<void> updateMyProfile(String userId, {required String fullName, String? jobTitle}) =>
      _patch('/rest/v1/profiles', {'user_id': 'eq.$userId'}, {
        'full_name': fullName.trim(),
        'job_title': (jobTitle ?? '').trim().isEmpty ? null : jobTitle!.trim(),
      });

  // ---------------------------------------------------------------------------
  // Attendance
  // ---------------------------------------------------------------------------

  /// Events, newest first. Staff only ever receive their own (enforced by RLS).
  Future<List<AttendanceEvent>> listEvents({
    String? userId,
    DateTime? from,
    DateTime? to,
    ReviewStatus? status,
    bool flaggedOnly = false,
    int limit = 500,
  }) async {
    final filters = <String>[
      if (from != null) 'server_time.gte.${_iso(from)}',
      if (to != null) 'server_time.lt.${_iso(to)}',
    ];
    final rows = await _get('/rest/v1/attendance_events', {
      'select': '*',
      'order': 'server_time.desc',
      'limit': '$limit',
      if (userId != null) 'user_id': 'eq.$userId',
      if (status != null) 'status': 'eq.${status.name}',
      if (flaggedOnly) 'flags': 'neq.{}',
      if (filters.isNotEmpty) 'and': '(${filters.join(',')})',
    }) as List;
    return rows
        .map((r) => AttendanceEvent.fromJson(Map<String, dynamic>.from(r as Map)))
        .toList();
  }

  /// Uploads a verification photo into the user's private folder and returns
  /// its storage path.
  Future<String> uploadPhoto(String userId, Uint8List jpeg) async {
    final stamp = DateTime.now().toUtc().millisecondsSinceEpoch;
    final suffix = _random.nextInt(1 << 30).toRadixString(36);
    final path = '$userId/${stamp}_$suffix.jpg';
    final headers = await _headers(contentType: 'image/jpeg', extra: {
      'x-upsert': 'false',
      'cache-control': '3600',
    });
    await _send(() => _http.post(
          _uri('/storage/v1/object/${AppConfig.photoBucket}/$path'),
          headers: headers,
          body: jpeg,
        ));
    return path;
  }

  /// POST /rest/v1/rpc/clock_event. The server checks the photo, location,
  /// work site and clock-in sequence, and stamps the official time.
  Future<AttendanceEvent> clock({
    required ClockType type,
    required double latitude,
    required double longitude,
    required double accuracyM,
    required bool isMocked,
    required String photoPath,
    required String photoSha256,
    required DateTime deviceTime,
    required String platform,
    String? address,
    String? notes,
    bool capturedOffline = false,
  }) async {
    final body = await _post('/rest/v1/rpc/clock_event', {
      'p_event_type': type.apiValue,
      'p_latitude': latitude,
      'p_longitude': longitude,
      'p_accuracy_m': accuracyM,
      'p_is_mocked': isMocked,
      'p_address': address,
      'p_photo_path': photoPath,
      'p_photo_sha256': photoSha256,
      'p_notes': (notes ?? '').trim().isEmpty ? null : notes!.trim(),
      'p_platform': platform,
      'p_device_time': _iso(deviceTime),
      'p_captured_offline': capturedOffline,
    });
    final row = body is List ? body.first : body;
    return AttendanceEvent.fromJson(Map<String, dynamic>.from(row as Map));
  }

  /// A temporary link to view a verification photo.
  Future<String> photoUrl(String path, {int expiresInSeconds = 3600}) async {
    final body = await _post('/storage/v1/object/sign/${AppConfig.photoBucket}/$path',
        {'expiresIn': expiresInSeconds}) as Map;
    final signed = (body['signedURL'] ?? body['signedUrl']) as String;
    if (signed.startsWith('http')) return signed;
    return '${_uri('/storage/v1')}${signed.startsWith('/') ? '' : '/'}$signed';
  }

  /// Asks the server to copy the event into Odoo. Never throws.
  Future<void> requestOdooSync(String eventId) async {
    try {
      await _post('/functions/v1/odoo-sync', {'event_id': eventId});
    } catch (_) {
      // Odoo sync is optional; the attendance record is already saved.
    }
  }

  // ---------------------------------------------------------------------------
  // Manager endpoints
  // ---------------------------------------------------------------------------

  Future<List<TeamMember>> teamStatus() async {
    final rows = await _post('/rest/v1/rpc/team_status', const <String, dynamic>{}) as List;
    return rows.map((r) => TeamMember.fromJson(Map<String, dynamic>.from(r as Map))).toList();
  }

  Future<AttendanceEvent> review(String eventId, ReviewStatus status, {String? note}) async {
    final body = await _post('/rest/v1/rpc/review_event', {
      'p_event_id': eventId,
      'p_status': status.name,
      'p_note': note,
    });
    final row = body is List ? body.first : body;
    return AttendanceEvent.fromJson(Map<String, dynamic>.from(row as Map));
  }

  Future<List<WorkSite>> listSites() async {
    final rows = await _get('/rest/v1/work_sites', {'select': '*', 'order': 'name.asc'}) as List;
    return rows.map((r) => WorkSite.fromJson(Map<String, dynamic>.from(r as Map))).toList();
  }

  Future<void> saveSite(WorkSite site) async {
    if (site.id == null) {
      await _post('/rest/v1/work_sites', site.toJson(), extra: {'Prefer': 'return=representation'});
    } else {
      await _patch('/rest/v1/work_sites', {'id': 'eq.${site.id}'}, site.toJson());
    }
  }

  Future<void> deleteSite(String id) => _delete('/rest/v1/work_sites', {'id': 'eq.$id'});

  Future<List<StaffProfile>> listStaff() async {
    final rows = await _get('/rest/v1/profiles', {'select': '*', 'order': 'full_name.asc'}) as List;
    return rows.map((r) => StaffProfile.fromJson(Map<String, dynamic>.from(r as Map))).toList();
  }

  Future<void> updateStaff(String userId,
      {String? role, bool? requireSite, bool? active, String? jobTitle}) {
    return _patch('/rest/v1/profiles', {'user_id': 'eq.$userId'}, {
      if (role != null) 'role': role,
      if (requireSite != null) 'require_site': requireSite,
      if (active != null) 'active': active,
      if (jobTitle != null) 'job_title': jobTitle.trim().isEmpty ? null : jobTitle.trim(),
    });
  }

  void close() => _http.close();
}
