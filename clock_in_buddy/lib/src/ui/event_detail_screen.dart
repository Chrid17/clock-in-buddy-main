import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../api/attendance_api.dart';
import '../models.dart';
import '../state/attendance_controller.dart';
import '../state/session.dart';
import '../utils.dart';
import 'widgets.dart';

/// Full proof of attendance for one event. Managers can verify or reject it.
/// Pops with the updated event when it was reviewed.
class EventDetailScreen extends StatefulWidget {
  const EventDetailScreen({super.key, required this.event});

  final AttendanceEvent event;

  @override
  State<EventDetailScreen> createState() => _EventDetailScreenState();
}

class _EventDetailScreenState extends State<EventDetailScreen> {
  late AttendanceEvent _event = widget.event;
  bool _reviewing = false;
  bool _changed = false;

  Future<void> _review(ReviewStatus status) async {
    String? note;
    if (status == ReviewStatus.rejected) {
      note = await _askNote();
      if (note == null) return;
    }
    if (!mounted) return;
    final api = context.read<AttendanceApi>();
    final attendance = context.read<AttendanceController>();
    setState(() => _reviewing = true);
    try {
      final updated = await api.review(_event.id, status, note: note);
      attendance.replaceEvent(updated);
      if (!mounted) return;
      setState(() {
        _event = updated;
        _changed = true;
      });
      showSnack(context, status == ReviewStatus.verified ? 'Marked as verified.' : 'Marked as rejected.');
    } on ApiException catch (e) {
      if (mounted) showSnack(context, e.message, error: true);
    } finally {
      if (mounted) setState(() => _reviewing = false);
    }
  }

  Future<String?> _askNote() {
    final controller = TextEditingController();
    return showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Reason for rejecting'),
        content: TextField(
          controller: controller,
          autofocus: true,
          maxLines: 3,
          textCapitalization: TextCapitalization.sentences,
          decoration: const InputDecoration(
            hintText: 'e.g. Face not visible, wrong location',
            border: OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Cancel')),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(controller.text.trim()),
            child: const Text('Reject'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final e = _event;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final isAdmin = context.select<Session, bool>((s) => s.isAdmin);
    final color = typeColor(e.type);

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) Navigator.of(context).pop(_changed ? _event : null);
      },
      child: Scaffold(
        appBar: AppBar(title: Text(e.staffName ?? e.type.label)),
        body: SafeArea(
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 640),
              child: ListView(
                padding: const EdgeInsets.fromLTRB(20, 4, 20, 32),
                children: [
                  Row(
                    children: [
                      CircleAvatar(
                        backgroundColor: color.withValues(alpha: 0.14),
                        child: Icon(typeIcon(e.type), color: color),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text('${e.type.label} · ${formatTime(e.effectiveTime)}',
                                style: theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700)),
                            Text(formatDate(e.effectiveTime), style: theme.textTheme.bodyMedium),
                          ],
                        ),
                      ),
                      StatusChip(e.status),
                    ],
                  ),
                  const SizedBox(height: 16),
                  EventPhoto(path: e.photoPath),
                  if (e.flags.isNotEmpty) ...[
                    const SizedBox(height: 12),
                    FlagChips(e.flags),
                  ],
                  const SizedBox(height: 16),
                  _Section(title: 'Time', rows: [
                    ('Recorded by server', formatDateTime(e.serverTime)),
                    if (e.deviceTime != null) ('Phone time at capture', formatDateTime(e.deviceTime!)),
                    if (e.capturedOffline) ('Captured offline', 'Yes, uploaded later'),
                  ]),
                  _Section(
                    title: 'Location',
                    rows: [
                      if (e.address != null) ('Address', e.address!),
                      if (e.hasLocation) ('Coordinates', formatCoords(e.latitude!, e.longitude!)),
                      if (e.accuracyM != null) ('GPS accuracy', '±${e.accuracyM!.round()} m'),
                      if (e.siteName != null)
                        ('Work site',
                            '${e.siteName} · ${formatDistance(e.distanceM ?? 0)} away${e.withinSite == true ? ' (inside)' : ' (outside)'}'),
                      ('Fake GPS check', e.isMocked ? 'Fake GPS detected' : 'Passed'),
                    ],
                    footer: e.hasLocation
                        ? TextButton.icon(
                            onPressed: () => openMap(context, e.latitude!, e.longitude!),
                            icon: const Icon(Icons.map_outlined),
                            label: const Text('Open in maps'),
                          )
                        : null,
                  ),
                  _Section(title: 'Proof', rows: [
                    ('Record ID', e.id),
                    if (e.photoSha256 != null) ('Photo SHA-256', e.photoSha256!),
                    if (e.platform != null) ('Device', e.platform!),
                    if (e.notes != null) ('Note from staff', e.notes!),
                  ]),
                  _Section(title: 'Review', rows: [
                    ('Status', e.status.label),
                    if (e.reviewedAt != null) ('Reviewed', formatDateTime(e.reviewedAt!)),
                    if (e.reviewNote != null) ('Manager note', e.reviewNote!),
                    ('Odoo', e.odooSynced ? 'Synced' : (e.odooError ?? 'Not synced')),
                  ]),
                  if (isAdmin) ...[
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        Expanded(
                          child: OutlinedButton.icon(
                            onPressed: _reviewing || e.status == ReviewStatus.rejected
                                ? null
                                : () => _review(ReviewStatus.rejected),
                            style: OutlinedButton.styleFrom(
                              foregroundColor: scheme.error,
                              minimumSize: const Size.fromHeight(48),
                            ),
                            icon: const Icon(Icons.close),
                            label: const Text('Reject'),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: FilledButton.icon(
                            onPressed: _reviewing || e.status == ReviewStatus.verified
                                ? null
                                : () => _review(ReviewStatus.verified),
                            style: FilledButton.styleFrom(
                              backgroundColor: clockInColor,
                              foregroundColor: Colors.white,
                              minimumSize: const Size.fromHeight(48),
                            ),
                            icon: const Icon(Icons.verified),
                            label: const Text('Verify'),
                          ),
                        ),
                      ],
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _Section extends StatelessWidget {
  const _Section({required this.title, required this.rows, this.footer});

  final String title;
  final List<(String, String)> rows;
  final Widget? footer;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Panel(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: theme.textTheme.titleSmall?.copyWith(color: theme.colorScheme.primary)),
            const SizedBox(height: 8),
            for (final (label, value) in rows)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SizedBox(
                      width: 140,
                      child: Text(label,
                          style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
                    ),
                    Expanded(
                      child: GestureDetector(
                        onLongPress: () {
                          Clipboard.setData(ClipboardData(text: value));
                          showSnack(context, '$label copied');
                        },
                        child: Text(value, style: theme.textTheme.bodyMedium),
                      ),
                    ),
                  ],
                ),
              ),
            if (footer != null) footer!,
          ],
        ),
      ),
    );
  }
}
