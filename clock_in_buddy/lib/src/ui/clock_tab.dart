import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models.dart';
import '../state/attendance_controller.dart';
import '../state/session.dart';
import '../utils.dart';
import 'capture_screen.dart';
import 'widgets.dart';

class ClockTab extends StatefulWidget {
  const ClockTab({super.key});

  @override
  State<ClockTab> createState() => _ClockTabState();
}

class _ClockTabState extends State<ClockTab> {
  late Timer _ticker;
  DateTime _now = DateTime.now();

  @override
  void initState() {
    super.initState();
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() => _now = DateTime.now());
    });
  }

  @override
  void dispose() {
    _ticker.cancel();
    super.dispose();
  }

  String _greeting() {
    final h = _now.hour;
    if (h < 12) return 'Good morning';
    if (h < 17) return 'Good afternoon';
    return 'Good evening';
  }

  Future<void> _startClock(ClockType type) async {
    final result = await Navigator.of(context).push<SubmitResult>(
      MaterialPageRoute(builder: (_) => CaptureScreen(type: type), fullscreenDialog: true),
    );
    if (!mounted || result == null) return;
    switch (result.outcome) {
      case SubmitOutcome.recorded:
        final event = result.event;
        if (event != null) await showReceipt(context, event);
      case SubmitOutcome.queued:
        showSnack(context,
            'No internet. Your ${type.label.toLowerCase()} is saved on this phone and will upload automatically.');
      case SubmitOutcome.failed:
        break;
    }
  }

  @override
  Widget build(BuildContext context) {
    final session = context.watch<Session>();
    final attendance = context.watch<AttendanceController>();
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final clockedIn = attendance.isClockedIn;
    final since = attendance.clockedInSince;
    final today = attendance.eventsOn(_now);
    final firstName = session.displayName.split(' ').first;

    return Scaffold(
      body: SafeArea(
        child: RefreshIndicator(
          onRefresh: attendance.refresh,
          child: ListView(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 32),
            children: [
              Text('${_greeting()}, $firstName',
                  style: theme.textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w700)),
              const SizedBox(height: 2),
              Text(formatDate(_now),
                  style: theme.textTheme.bodyLarge?.copyWith(color: scheme.onSurfaceVariant)),
              const SizedBox(height: 20),
              if (session.profileError != null)
                InfoBanner(icon: Icons.error_outline, message: session.profileError!, color: scheme.error),
              if (attendance.error != null)
                InfoBanner(
                  icon: Icons.cloud_off_outlined,
                  message: attendance.error!,
                  color: const Color(0xFFD97706),
                  action: 'Retry',
                  onAction: attendance.refresh,
                ),
              if (attendance.pending.isNotEmpty)
                InfoBanner(
                  icon: Icons.cloud_upload_outlined,
                  message:
                      '${attendance.pending.length} clock ${attendance.pending.length == 1 ? 'action is' : 'actions are'} saved on this phone and will upload when you are online.',
                  action: attendance.syncing ? null : 'Upload now',
                  onAction: () async {
                    final n = await attendance.syncPending();
                    if (context.mounted && n > 0) showSnack(context, 'Uploaded $n saved clock actions.');
                  },
                ),
              if (attendance.syncError != null)
                InfoBanner(icon: Icons.warning_amber_rounded, message: attendance.syncError!, color: scheme.error),
              _StatusCard(
                clockedIn: clockedIn,
                since: since,
                siteName: attendance.currentSiteName,
                now: _now,
                workedToday: attendance.workedOn(_now, now: _now),
                workedWeek: attendance.workedThisWeek(now: _now),
              ),
              const SizedBox(height: 28),
              Center(
                child: _ClockButton(
                  type: attendance.nextAction,
                  busy: attendance.loading && attendance.events.isEmpty && attendance.pending.isEmpty,
                  onPressed: () => _startClock(attendance.nextAction),
                ),
              ),
              const SizedBox(height: 12),
              Center(
                child: Text(
                  'A selfie and your GPS location are recorded as proof.',
                  style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
                ),
              ),
              const SizedBox(height: 28),
              Row(
                children: [
                  Text('Today', style: theme.textTheme.titleMedium),
                  const Spacer(),
                  if (today.isNotEmpty)
                    Text('${today.length} ${today.length == 1 ? 'entry' : 'entries'}',
                        style: theme.textTheme.bodySmall),
                ],
              ),
              const SizedBox(height: 8),
              if (today.isEmpty)
                const EmptyMessage(
                  icon: Icons.wb_sunny_outlined,
                  title: 'No activity yet today',
                  subtitle: 'Tap the button above when you start work.',
                )
              else
                for (final e in today) EventTile(event: e),
            ],
          ),
        ),
      ),
    );
  }
}

class _StatusCard extends StatelessWidget {
  const _StatusCard({
    required this.clockedIn,
    required this.since,
    required this.siteName,
    required this.now,
    required this.workedToday,
    required this.workedWeek,
  });

  final bool clockedIn;
  final DateTime? since;
  final String? siteName;
  final DateTime now;
  final Duration workedToday;
  final Duration workedWeek;

  @override
  Widget build(BuildContext context) {
    final color = clockedIn ? clockInColor : const Color(0xFF64748B);
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(24),
        gradient: LinearGradient(
          colors: [color.withValues(alpha: 0.18), color.withValues(alpha: 0.06)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        border: Border.all(color: color.withValues(alpha: 0.35)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 12,
                height: 12,
                decoration: BoxDecoration(color: color, shape: BoxShape.circle),
              ),
              const SizedBox(width: 8),
              Text(
                clockedIn ? 'Clocked in' : 'Clocked out',
                style: theme.textTheme.titleMedium?.copyWith(color: color, fontWeight: FontWeight.w700),
              ),
              const Spacer(),
              Text(formatTimeSeconds(now),
                  style: theme.textTheme.titleMedium?.copyWith(
                      fontFeatures: const [FontFeature.tabularFigures()])),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            clockedIn && since != null
                ? 'Since ${formatTime(since!)}${siteName != null ? ' at $siteName' : ''}'
                : 'Tap Clock in when you start work',
            style: theme.textTheme.bodyMedium,
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                child: _Metric(label: 'Worked today', value: formatClock(workedToday)),
              ),
              Expanded(
                child: _Metric(label: 'This week', value: formatDuration(workedWeek)),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _Metric extends StatelessWidget {
  const _Metric({required this.label, required this.value});
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: theme.textTheme.labelMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
        const SizedBox(height: 2),
        Text(value,
            style: theme.textTheme.headlineSmall?.copyWith(
              fontWeight: FontWeight.w700,
              fontFeatures: const [FontFeature.tabularFigures()],
            )),
      ],
    );
  }
}

class _ClockButton extends StatelessWidget {
  const _ClockButton({required this.type, required this.busy, required this.onPressed});

  final ClockType type;
  final bool busy;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final color = typeColor(type);
    return Semantics(
      button: true,
      label: type.label,
      child: SizedBox(
        width: 190,
        height: 190,
        child: Material(
          shape: const CircleBorder(),
          clipBehavior: Clip.antiAlias,
          elevation: 6,
          shadowColor: color.withValues(alpha: 0.5),
          child: Ink(
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: LinearGradient(
                colors: [color, Color.lerp(color, Colors.black, 0.25)!],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
            ),
            child: InkWell(
              onTap: busy ? null : onPressed,
              child: Center(
                child: busy
                    ? const CircularProgressIndicator(color: Colors.white)
                    : Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(typeIcon(type), size: 54, color: Colors.white),
                          const SizedBox(height: 8),
                          Text(
                            type.label.toUpperCase(),
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 18,
                              fontWeight: FontWeight.w800,
                              letterSpacing: 1.2,
                            ),
                          ),
                        ],
                      ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Confirmation shown after a successful clock action.
Future<void> showReceipt(BuildContext context, AttendanceEvent event) {
  return showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    builder: (context) {
      final theme = Theme.of(context);
      final color = typeColor(event.type);
      return SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              CircleAvatar(
                radius: 32,
                backgroundColor: color.withValues(alpha: 0.15),
                child: Icon(Icons.check_rounded, size: 40, color: color),
              ),
              const SizedBox(height: 12),
              Text('${event.type == ClockType.clockIn ? 'Clocked in' : 'Clocked out'} at ${formatTime(event.serverTime)}',
                  style: theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700)),
              const SizedBox(height: 4),
              Text(
                event.siteName != null
                    ? '${event.siteName} · ${event.withinSite == true ? 'on site' : '${formatDistance(event.distanceM ?? 0)} away'}'
                    : (event.address ?? 'Location recorded'),
                textAlign: TextAlign.center,
                style: theme.textTheme.bodyMedium,
              ),
              const SizedBox(height: 12),
              FlagChips(event.flags),
              const SizedBox(height: 12),
              Text(
                'Reference ${event.id.substring(0, 8).toUpperCase()} · time set by server',
                style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
              ),
              const SizedBox(height: 16),
              FilledButton(
                onPressed: () => Navigator.of(context).pop(),
                style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(48)),
                child: const Text('Done'),
              ),
            ],
          ),
        ),
      );
    },
  );
}
