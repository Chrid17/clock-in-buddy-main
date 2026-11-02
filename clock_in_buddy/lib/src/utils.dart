import 'dart:math' as math;

import 'package:intl/intl.dart';

import 'models.dart';

// -----------------------------------------------------------------------------
// Formatting
// -----------------------------------------------------------------------------

String formatTime(DateTime t) => DateFormat('HH:mm').format(t);
String formatTimeSeconds(DateTime t) => DateFormat('HH:mm:ss').format(t);
String formatDate(DateTime t) => DateFormat('EEE d MMM y').format(t);
String formatDayHeading(DateTime t, {DateTime? now}) {
  final today = dateOnly(now ?? DateTime.now());
  final day = dateOnly(t);
  final diff = (today.difference(day).inHours / 24).round();
  if (diff == 0) return 'Today';
  if (diff == 1) return 'Yesterday';
  return DateFormat('EEEE d MMMM').format(t);
}

String formatDateTime(DateTime t) => DateFormat('d MMM y, HH:mm:ss').format(t);

/// "7h 45m", "45m", "0m".
String formatDuration(Duration d) {
  final minutes = d.inMinutes;
  final h = minutes ~/ 60;
  final m = minutes % 60;
  if (h == 0) return '${m}m';
  return '${h}h ${m.toString().padLeft(2, '0')}m';
}

/// "07:45:12" for live counters.
String formatClock(Duration d) {
  final s = d.inSeconds;
  String two(int v) => v.toString().padLeft(2, '0');
  return '${two(s ~/ 3600)}:${two((s % 3600) ~/ 60)}:${two(s % 60)}';
}

String formatDistance(double meters) => meters < 1000
    ? '${meters.round()} m'
    : '${(meters / 1000).toStringAsFixed(meters < 10000 ? 1 : 0)} km';

String formatCoords(double lat, double lng) =>
    '${lat.toStringAsFixed(6)}, ${lng.toStringAsFixed(6)}';

DateTime dateOnly(DateTime t) => DateTime(t.year, t.month, t.day);

// -----------------------------------------------------------------------------
// Geography
// -----------------------------------------------------------------------------

/// Great-circle distance in metres (same formula as the server).
double distanceMeters(double lat1, double lon1, double lat2, double lon2) {
  const r = 6371000.0;
  double rad(double d) => d * math.pi / 180;
  final dLat = rad(lat2 - lat1);
  final dLon = rad(lon2 - lon1);
  final a = math.pow(math.sin(dLat / 2), 2) +
      math.cos(rad(lat1)) * math.cos(rad(lat2)) * math.pow(math.sin(dLon / 2), 2);
  return 2 * r * math.asin(math.min(1.0, math.sqrt(a)));
}

Uri mapsUri(double lat, double lng) =>
    Uri.parse('https://www.google.com/maps/search/?api=1&query=$lat,$lng');

// -----------------------------------------------------------------------------
// Hours worked
// -----------------------------------------------------------------------------

/// A clock-in and its matching clock-out (null while still clocked in).
class Shift {
  const Shift(this.start, this.end);
  final AttendanceEvent start;
  final AttendanceEvent? end;

  Duration durationUntil(DateTime now) =>
      (end?.effectiveTime ?? now).difference(start.effectiveTime);
}

/// Pairs clock-ins with clock-outs. Events can be in any order.
List<Shift> buildShifts(List<AttendanceEvent> events) {
  final sorted = [...events]..sort((a, b) => a.effectiveTime.compareTo(b.effectiveTime));
  final shifts = <Shift>[];
  AttendanceEvent? open;
  for (final e in sorted) {
    if (e.type == ClockType.clockIn) {
      if (open != null) shifts.add(Shift(open, null));
      open = e;
    } else if (open != null) {
      shifts.add(Shift(open, e));
      open = null;
    }
  }
  if (open != null) shifts.add(Shift(open, null));
  return shifts;
}

/// Time worked between [from] and [to], counting only the overlap of each
/// shift with that window. An open shift counts until [now].
Duration workedBetween(
  List<AttendanceEvent> events,
  DateTime from,
  DateTime to, {
  DateTime? now,
}) {
  final current = now ?? DateTime.now();
  var total = Duration.zero;
  final shifts = buildShifts(events);
  for (var i = 0; i < shifts.length; i++) {
    final shift = shifts[i];
    final start = shift.start.effectiveTime;
    // Only the most recent open shift is still running; older unmatched
    // clock-ins are counted as zero.
    final isLatest = i == shifts.length - 1;
    final end = shift.end?.effectiveTime ?? (isLatest ? current : start);
    final s = start.isAfter(from) ? start : from;
    final e = end.isBefore(to) ? end : to;
    if (e.isAfter(s)) total += e.difference(s);
  }
  return total;
}

// -----------------------------------------------------------------------------
// CSV
// -----------------------------------------------------------------------------

String csvEscape(Object? value) {
  final text = value?.toString() ?? '';
  if (text.contains(RegExp(r'[",\n\r]'))) {
    return '"${text.replaceAll('"', '""')}"';
  }
  return text;
}

String buildCsv(List<AttendanceEvent> events) {
  final rows = <List<Object?>>[
    [
      'Staff', 'Event', 'Date', 'Time (server)', 'Time (device)', 'Captured offline',
      'Latitude', 'Longitude', 'Accuracy (m)', 'Address', 'Work site', 'Distance (m)',
      'Within site', 'Flags', 'Status', 'Review note', 'Photo SHA-256', 'Notes', 'Record ID',
    ],
  ];
  final sorted = [...events]..sort((a, b) => a.serverTime.compareTo(b.serverTime));
  for (final e in sorted) {
    rows.add([
      e.staffName ?? '',
      e.type.label,
      DateFormat('yyyy-MM-dd').format(e.serverTime),
      formatTimeSeconds(e.serverTime),
      e.deviceTime == null ? '' : formatTimeSeconds(e.deviceTime!),
      e.capturedOffline ? 'yes' : 'no',
      e.latitude?.toStringAsFixed(6) ?? '',
      e.longitude?.toStringAsFixed(6) ?? '',
      e.accuracyM?.round() ?? '',
      e.address ?? '',
      e.siteName ?? '',
      e.distanceM?.round() ?? '',
      e.withinSite == null ? '' : (e.withinSite! ? 'yes' : 'no'),
      e.flags.map((f) => flagLabels[f] ?? f).join('; '),
      e.status.label,
      e.reviewNote ?? '',
      e.photoSha256 ?? '',
      e.notes ?? '',
      e.id,
    ]);
  }
  return rows.map((r) => r.map(csvEscape).join(',')).join('\r\n');
}
