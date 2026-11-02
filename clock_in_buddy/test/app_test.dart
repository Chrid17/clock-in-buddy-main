import 'dart:convert';
import 'dart:typed_data';

import 'package:clock_in_buddy/src/api/attendance_api.dart';
import 'package:clock_in_buddy/src/models.dart';
import 'package:clock_in_buddy/src/state/attendance_controller.dart';
import 'package:clock_in_buddy/src/utils.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _base = 'https://example.supabase.co';
const _uid = '22222222-2222-2222-2222-222222222222';

Map<String, dynamic> _row({
  String id = 'aaaaaaaa-0000-0000-0000-000000000001',
  String type = 'clock_in',
  String time = '2026-11-02T06:00:00+00:00',
  List<String> flags = const [],
}) =>
    {
      'id': id,
      'user_id': _uid,
      'staff_name': 'Sam Staff',
      'event_type': type,
      'server_time': time,
      'device_time': time,
      'latitude': -22.5705,
      'longitude': 17.0802,
      'accuracy_m': 8.5,
      'is_mocked': false,
      'address': 'Independence Ave, Windhoek',
      'site_name': 'Head Office',
      'distance_m': 59.2,
      'within_site': true,
      'photo_path': '$_uid/1.jpg',
      'photo_sha256': 'abc123',
      'notes': null,
      'platform': 'android',
      'captured_offline': false,
      'flags': flags,
      'status': 'pending',
      'review_note': null,
      'reviewed_at': null,
      'odoo_synced': false,
      'odoo_error': null,
    };

AttendanceEvent _event(String type, DateTime t, {String? id}) => AttendanceEvent(
      id: id ?? '$type-${t.millisecondsSinceEpoch}',
      userId: _uid,
      type: ClockType.fromApi(type),
      serverTime: t,
    );

AttendanceApi _api(MockClient client) => AttendanceApi(
      baseUrl: _base,
      apiKey: 'publishable-key',
      tokenProvider: () async => 'user-token',
      client: client,
    );

ClockDraft _draft(ClockType type) => ClockDraft(
      type: type,
      photo: Uint8List.fromList([1, 2, 3]),
      photoSha256: 'hash',
      latitude: -22.57,
      longitude: 17.08,
      accuracyM: 10,
      isMocked: false,
      deviceTime: DateTime(2026, 11, 2, 8),
      platform: 'android',
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('models', () {
    test('parses an attendance row from the REST API', () {
      final e = AttendanceEvent.fromJson(_row(flags: ['outside_site']));
      expect(e.type, ClockType.clockIn);
      expect(e.siteName, 'Head Office');
      expect(e.withinSite, isTrue);
      expect(e.accuracyM, 8.5);
      expect(e.status, ReviewStatus.pending);
      expect(e.isFlagged, isTrue);
      expect(e.serverTime.toUtc(), DateTime.utc(2026, 11, 2, 6));
    });

    test('a queued clock action survives being saved and loaded', () {
      final d = _draft(ClockType.clockOut);
      final copy = ClockDraft.fromJson(jsonDecode(jsonEncode(d.toJson())) as Map<String, dynamic>);
      expect(copy.type, ClockType.clockOut);
      expect(copy.photo, [1, 2, 3]);
      expect(copy.deviceTime, d.deviceTime);
      expect(copy.id, d.id);
    });
  });

  group('utils', () {
    test('distance matches the server formula', () {
      // About 59 m, same as the SQL distance_m() test.
      final d = distanceMeters(-22.5700, 17.0800, -22.5705, 17.0802);
      expect(d, closeTo(59, 1));
      expect(distanceMeters(-22.57, 17.08, -22.60, 17.10), closeTo(3917, 5));
    });

    test('hours worked pairs clock-ins with clock-outs', () {
      final day = DateTime(2026, 11, 2);
      final events = [
        _event('clock_in', day.add(const Duration(hours: 8))),
        _event('clock_out', day.add(const Duration(hours: 12))),
        _event('clock_in', day.add(const Duration(hours: 13))),
        _event('clock_out', day.add(const Duration(hours: 17, minutes: 30))),
      ];
      final worked = workedBetween(events, day, day.add(const Duration(days: 1)));
      expect(worked, const Duration(hours: 8, minutes: 30));
      expect(formatDuration(worked), '8h 30m');
    });

    test('an open shift counts until now', () {
      final day = DateTime(2026, 11, 2);
      final events = [_event('clock_in', day.add(const Duration(hours: 9)))];
      final now = day.add(const Duration(hours: 11, minutes: 15));
      expect(workedBetween(events, day, day.add(const Duration(days: 1)), now: now),
          const Duration(hours: 2, minutes: 15));
    });

    test('CSV escapes commas and quotes', () {
      expect(csvEscape('plain'), 'plain');
      expect(csvEscape('a, b'), '"a, b"');
      expect(csvEscape('say "hi"'), '"say ""hi"""');
      final csv = buildCsv([AttendanceEvent.fromJson(_row())]);
      expect(csv.split('\r\n'), hasLength(2));
      expect(csv, contains('"Independence Ave, Windhoek"'));
    });
  });

  group('REST client', () {
    test('clock_event is called with the photo, location and token', () async {
      late http.Request sent;
      final api = _api(MockClient((request) async {
        sent = request;
        return http.Response(jsonEncode(_row()), 200);
      }));
      final event = await api.clock(
        type: ClockType.clockIn,
        latitude: -22.5705,
        longitude: 17.0802,
        accuracyM: 8.5,
        isMocked: false,
        photoPath: '$_uid/1.jpg',
        photoSha256: 'abc123',
        deviceTime: DateTime.utc(2026, 11, 2, 6),
        platform: 'android',
      );
      expect(sent.method, 'POST');
      expect(sent.url.toString(), '$_base/rest/v1/rpc/clock_event');
      expect(sent.headers['Authorization'], 'Bearer user-token');
      expect(sent.headers['apikey'], 'publishable-key');
      final body = jsonDecode(sent.body) as Map<String, dynamic>;
      expect(body['p_event_type'], 'clock_in');
      expect(body['p_photo_path'], '$_uid/1.jpg');
      expect(body['p_device_time'], '2026-11-02T06:00:00.000Z');
      expect(event.siteName, 'Head Office');
    });

    test('server rules come back as readable errors', () async {
      final api = _api(MockClient((_) async => http.Response(
          jsonEncode({'code': 'P0001', 'message': 'You are already clocked in.'}), 400)));
      expect(
        () => api.listEvents(),
        throwsA(isA<ApiException>()
            .having((e) => e.message, 'message', 'You are already clocked in.')
            .having((e) => e.isNetwork, 'isNetwork', isFalse)),
      );
    });

    test('no internet is reported as a network error', () async {
      final api = _api(MockClient((_) async => throw http.ClientException('Failed host lookup')));
      expect(() => api.listEvents(),
          throwsA(isA<ApiException>().having((e) => e.isNetwork, 'isNetwork', isTrue)));
    });

    test('date filters use PostgREST syntax', () async {
      late Uri url;
      final api = _api(MockClient((request) async {
        url = request.url;
        return http.Response('[]', 200);
      }));
      await api.listEvents(
        userId: _uid,
        from: DateTime.utc(2026, 11, 1),
        to: DateTime.utc(2026, 11, 8),
      );
      expect(url.path, '/rest/v1/attendance_events');
      expect(url.queryParameters['user_id'], 'eq.$_uid');
      expect(url.queryParameters['order'], 'server_time.desc');
      expect(url.queryParameters['and'],
          '(server_time.gte.2026-11-01T00:00:00.000Z,server_time.lt.2026-11-08T00:00:00.000Z)');
    });

    test('photos upload into the user\'s own folder', () async {
      late http.Request sent;
      final api = _api(MockClient((request) async {
        sent = request;
        return http.Response('{"Key":"attendance-photos/x"}', 200);
      }));
      final path = await api.uploadPhoto(_uid, Uint8List.fromList([9, 9]));
      expect(path, startsWith('$_uid/'));
      expect(sent.url.path, '/storage/v1/object/attendance-photos/$path');
      expect(sent.headers['Content-Type'], 'image/jpeg');
      expect(sent.bodyBytes, [9, 9]);
    });
  });

  group('attendance controller', () {
    setUp(() => SharedPreferences.setMockInitialValues({}));

    test('records a clock-in and shows the new status', () async {
      final api = _api(MockClient((request) async {
        final path = request.url.path;
        if (path.startsWith('/storage/')) return http.Response('{}', 200);
        if (path.endsWith('/rpc/clock_event')) return http.Response(jsonEncode(_row()), 200);
        if (path.startsWith('/functions/')) return http.Response('{"ok":true}', 200);
        return http.Response('[]', 200);
      }));
      final controller = AttendanceController(api: api);
      await controller.bindUser(_uid);
      expect(controller.isClockedIn, isFalse);

      final result = await controller.submit(_draft(ClockType.clockIn));
      expect(result.outcome, SubmitOutcome.recorded);
      expect(controller.isClockedIn, isTrue);
      expect(controller.currentSiteName, 'Head Office');
    });

    test('saves the clock-in on the phone when offline, then uploads it', () async {
      var online = false;
      final calls = <String>[];
      final api = _api(MockClient((request) async {
        final path = request.url.path;
        if (!online) throw http.ClientException('offline');
        calls.add(path);
        if (path.startsWith('/storage/')) return http.Response('{}', 200);
        if (path.endsWith('/rpc/clock_event')) {
          final body = jsonDecode(request.body) as Map<String, dynamic>;
          expect(body['p_captured_offline'], isTrue);
          return http.Response(jsonEncode(_row()), 200);
        }
        return http.Response('[]', 200);
      }));
      final controller = AttendanceController(api: api);
      await controller.bindUser(_uid);

      final result = await controller.submit(_draft(ClockType.clockIn));
      expect(result.outcome, SubmitOutcome.queued);
      expect(controller.pending, hasLength(1));
      expect(controller.isClockedIn, isTrue, reason: 'queued clock-in counts straight away');

      online = true;
      final uploaded = await controller.syncPending();
      expect(uploaded, 1);
      expect(controller.pending, isEmpty);
      expect(calls.where((c) => c.endsWith('/rpc/clock_event')), hasLength(1));
    });

    test('a refused clock action is reported, not retried', () async {
      final api = _api(MockClient((request) async {
        final path = request.url.path;
        if (path.startsWith('/storage/')) return http.Response('{}', 200);
        if (path.endsWith('/rpc/clock_event')) {
          return http.Response(jsonEncode({'message': 'You are already clocked in.'}), 400);
        }
        return http.Response('[]', 200);
      }));
      final controller = AttendanceController(api: api);
      await controller.bindUser(_uid);
      final result = await controller.submit(_draft(ClockType.clockIn));
      expect(result.outcome, SubmitOutcome.failed);
      expect(result.message, 'You are already clocked in.');
      expect(controller.pending, isEmpty);
    });
  });
}
