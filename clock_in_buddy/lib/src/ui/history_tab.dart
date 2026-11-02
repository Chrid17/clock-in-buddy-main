import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';
import 'package:share_plus/share_plus.dart';

import '../api/attendance_api.dart';
import '../models.dart';
import '../state/attendance_controller.dart';
import '../state/session.dart';
import '../utils.dart';
import 'widgets.dart';

enum HistoryRange {
  thisWeek('This week'),
  lastWeek('Last week'),
  thisMonth('This month'),
  lastMonth('Last month');

  const HistoryRange(this.label);
  final String label;

  (DateTime, DateTime) bounds(DateTime now) {
    final today = dateOnly(now);
    final monday = today.subtract(Duration(days: today.weekday - 1));
    return switch (this) {
      HistoryRange.thisWeek => (monday, monday.add(const Duration(days: 7))),
      HistoryRange.lastWeek => (monday.subtract(const Duration(days: 7)), monday),
      HistoryRange.thisMonth => (DateTime(now.year, now.month), DateTime(now.year, now.month + 1)),
      HistoryRange.lastMonth => (DateTime(now.year, now.month - 1), DateTime(now.year, now.month)),
    };
  }
}

/// A person's attendance over a period. Used for "my history" and, by
/// managers, for any staff member.
class HistoryView extends StatefulWidget {
  const HistoryView({super.key, required this.userId, this.title, this.showPending = false});

  final String userId;
  final String? title;

  /// Include clock actions still waiting to upload (own history only).
  final bool showPending;

  @override
  State<HistoryView> createState() => _HistoryViewState();
}

class _HistoryViewState extends State<HistoryView> {
  HistoryRange _range = HistoryRange.thisWeek;
  List<AttendanceEvent> _events = [];
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    final (from, to) = _range.bounds(DateTime.now());
    try {
      // A little extra before the start, to pair shifts that began earlier.
      final events = await context.read<AttendanceApi>().listEvents(
            userId: widget.userId,
            from: from.subtract(const Duration(days: 1)),
            to: to,
          );
      if (!mounted) return;
      setState(() {
        _events = events;
        _loading = false;
      });
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.message;
        _loading = false;
      });
    }
  }

  Future<void> _export(List<AttendanceEvent> events, DateTime from, DateTime to) async {
    if (events.isEmpty) {
      showSnack(context, 'Nothing to export for this period.');
      return;
    }
    final csv = buildCsv(events);
    final name = 'attendance_${DateFormat('yyyy-MM-dd').format(from)}'
        '_to_${DateFormat('yyyy-MM-dd').format(to.subtract(const Duration(days: 1)))}.csv';
    try {
      await SharePlus.instance.share(ShareParams(
        files: [XFile.fromData(utf8.encode(csv), mimeType: 'text/csv', name: name)],
        fileNameOverrides: [name],
        subject: 'Attendance report',
      ));
    } catch (e) {
      if (mounted) showSnack(context, 'Could not export the report.', error: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final now = DateTime.now();
    final (from, to) = _range.bounds(now);
    // For your own history, include what the Clock tab already knows
    // (new and offline entries) so it is always up to date.
    final local = widget.showPending
        ? context.watch<AttendanceController>().timeline
        : const <AttendanceEvent>[];
    final byId = <String, AttendanceEvent>{for (final e in _events) e.id: e};
    for (final e in local) {
      byId.putIfAbsent(e.id, () => e);
    }
    final all = byId.values.toList();
    final inRange = all
        .where((e) => !e.effectiveTime.isBefore(from) && e.effectiveTime.isBefore(to))
        .toList()
      ..sort((a, b) => b.effectiveTime.compareTo(a.effectiveTime));

    final total = workedBetween(all, from, to, now: now);
    final byDay = <DateTime, List<AttendanceEvent>>{};
    for (final e in inRange) {
      byDay.putIfAbsent(dateOnly(e.effectiveTime), () => []).add(e);
    }
    final days = byDay.keys.toList()..sort((a, b) => b.compareTo(a));
    final daysWorked = days.where((d) => workedBetween(all, d, d.add(const Duration(days: 1)), now: now) > Duration.zero).length;

    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 32),
        children: [
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                for (final r in HistoryRange.values)
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: ChoiceChip(
                      label: Text(r.label),
                      selected: _range == r,
                      onSelected: (_) {
                        setState(() => _range = r);
                        _load();
                      },
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          Panel(
            child: Row(
              children: [
                Expanded(child: _Stat(label: 'Hours worked', value: formatDuration(total))),
                Expanded(child: _Stat(label: 'Days worked', value: '$daysWorked')),
                Expanded(
                  child: _Stat(
                    label: 'Average / day',
                    value: daysWorked == 0
                        ? '–'
                        : formatDuration(Duration(minutes: total.inMinutes ~/ daysWorked)),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: Text(
                  '${DateFormat('d MMM').format(from)} – ${DateFormat('d MMM y').format(to.subtract(const Duration(days: 1)))}',
                  style: theme.textTheme.bodySmall,
                ),
              ),
              TextButton.icon(
                onPressed: () => _export(inRange, from, to),
                icon: const Icon(Icons.ios_share, size: 18),
                label: const Text('Export CSV'),
              ),
            ],
          ),
          if (_error != null)
            InfoBanner(
              icon: Icons.cloud_off_outlined,
              message: _error!,
              color: theme.colorScheme.error,
              action: 'Retry',
              onAction: _load,
            ),
          if (_loading && _events.isEmpty)
            const Padding(
              padding: EdgeInsets.all(40),
              child: Center(child: CircularProgressIndicator()),
            )
          else if (days.isEmpty)
            const EmptyMessage(
              icon: Icons.event_busy_outlined,
              title: 'No attendance in this period',
            )
          else
            for (final day in days) ...[
              Padding(
                padding: const EdgeInsets.only(top: 12, bottom: 6),
                child: Row(
                  children: [
                    Text(formatDayHeading(day, now: now), style: theme.textTheme.titleSmall),
                    const Spacer(),
                    Text(
                      formatDuration(workedBetween(all, day, day.add(const Duration(days: 1)), now: now)),
                      style: theme.textTheme.titleSmall?.copyWith(color: theme.colorScheme.primary),
                    ),
                  ],
                ),
              ),
              for (final e in byDay[day]!)
                EventTile(
                  event: e,
                  onChanged: (updated) => setState(() {
                    _events = [for (final x in _events) x.id == updated.id ? updated : x];
                  }),
                ),
            ],
        ],
      ),
    );
  }
}

class _Stat extends StatelessWidget {
  const _Stat({required this.label, required this.value});
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(value, style: theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700)),
        Text(label, style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
      ],
    );
  }
}

/// "History" tab: the signed-in person's own attendance.
class HistoryTab extends StatelessWidget {
  const HistoryTab({super.key});

  @override
  Widget build(BuildContext context) {
    final userId = context.select<Session, String?>((s) => s.userId);
    return Scaffold(
      appBar: AppBar(title: const Text('My attendance')),
      body: userId == null
          ? const SizedBox.shrink()
          : HistoryView(key: ValueKey(userId), userId: userId, showPending: true),
    );
  }
}
