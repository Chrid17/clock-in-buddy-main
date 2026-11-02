import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../api/attendance_api.dart';
import '../models.dart';
import '../utils.dart';
import 'event_detail_screen.dart';

const Color clockInColor = Color(0xFF16A34A);
const Color clockOutColor = Color(0xFFE11D48);

Color typeColor(ClockType type) => type == ClockType.clockIn ? clockInColor : clockOutColor;
IconData typeIcon(ClockType type) =>
    type == ClockType.clockIn ? Icons.login_rounded : Icons.logout_rounded;

void showSnack(BuildContext context, String message, {bool error = false}) {
  final messenger = ScaffoldMessenger.maybeOf(context);
  if (messenger == null) return;
  final scheme = Theme.of(context).colorScheme;
  messenger
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(
      content: Text(message),
      behavior: SnackBarBehavior.floating,
      backgroundColor: error ? scheme.error : null,
    ));
}

Future<bool> confirm(
  BuildContext context, {
  required String title,
  required String message,
  String action = 'OK',
  bool destructive = false,
}) async {
  final scheme = Theme.of(context).colorScheme;
  final result = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(title),
      content: Text(message),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('Cancel')),
        FilledButton(
          style: destructive
              ? FilledButton.styleFrom(backgroundColor: scheme.error, foregroundColor: scheme.onError)
              : null,
          onPressed: () => Navigator.of(context).pop(true),
          child: Text(action),
        ),
      ],
    ),
  );
  return result ?? false;
}

Future<void> openMap(BuildContext context, double lat, double lng) async {
  final ok = await launchUrl(mapsUri(lat, lng), mode: LaunchMode.externalApplication);
  if (!ok && context.mounted) showSnack(context, 'Could not open maps.', error: true);
}

/// Rounded card used across the app.
class Panel extends StatelessWidget {
  const Panel({super.key, required this.child, this.padding = const EdgeInsets.all(16), this.color});

  final Widget child;
  final EdgeInsetsGeometry padding;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      padding: padding,
      decoration: BoxDecoration(
        color: color ?? scheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: scheme.outlineVariant.withValues(alpha: 0.6)),
      ),
      child: child,
    );
  }
}

class StatusChip extends StatelessWidget {
  const StatusChip(this.status, {super.key, this.compact = false});

  final ReviewStatus status;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final (Color color, IconData icon) = switch (status) {
      ReviewStatus.verified => (clockInColor, Icons.verified_rounded),
      ReviewStatus.rejected => (clockOutColor, Icons.cancel_rounded),
      ReviewStatus.pending => (const Color(0xFFD97706), Icons.hourglass_top_rounded),
    };
    return Container(
      padding: EdgeInsets.symmetric(horizontal: compact ? 6 : 10, vertical: compact ? 2 : 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: compact ? 13 : 16, color: color),
          const SizedBox(width: 4),
          Text(
            compact && status == ReviewStatus.pending ? 'Pending' : status.label,
            style: TextStyle(
                color: color, fontSize: compact ? 11 : 13, fontWeight: FontWeight.w600),
          ),
        ],
      ),
    );
  }
}

class FlagChips extends StatelessWidget {
  const FlagChips(this.flags, {super.key});
  final List<String> flags;

  @override
  Widget build(BuildContext context) {
    if (flags.isEmpty) return const SizedBox.shrink();
    return Wrap(
      spacing: 6,
      runSpacing: 6,
      children: [
        for (final f in flags)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
            decoration: BoxDecoration(
              color: (f == 'imported' || f == 'offline'
                      ? Colors.blueGrey
                      : const Color(0xFFD97706))
                  .withValues(alpha: 0.14),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Text(
              flagLabels[f] ?? f,
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: f == 'imported' || f == 'offline'
                    ? Colors.blueGrey
                    : const Color(0xFFB45309),
              ),
            ),
          ),
      ],
    );
  }
}

/// One clock-in or clock-out in a list.
class EventTile extends StatelessWidget {
  const EventTile({super.key, required this.event, this.showName = false, this.onChanged});

  final AttendanceEvent event;
  final bool showName;

  /// Called when a manager reviews the event from the detail screen.
  final ValueChanged<AttendanceEvent>? onChanged;

  bool get _isPending => event.id.startsWith('pending-');

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = typeColor(event.type);
    final where = event.siteName != null
        ? '${event.siteName}${event.withinSite == false ? ' (outside)' : ''}'
        : event.address ?? (event.hasLocation ? formatCoords(event.latitude!, event.longitude!) : 'No location');
    return Card(
      elevation: 0,
      margin: const EdgeInsets.only(bottom: 8),
      color: theme.colorScheme.surfaceContainerLow,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(color: theme.colorScheme.outlineVariant.withValues(alpha: 0.6)),
      ),
      child: ListTile(
        onTap: _isPending
            ? null
            : () async {
                final updated = await Navigator.of(context).push<AttendanceEvent>(
                  MaterialPageRoute(builder: (_) => EventDetailScreen(event: event)),
                );
                if (updated != null) onChanged?.call(updated);
              },
        leading: CircleAvatar(
          backgroundColor: color.withValues(alpha: 0.14),
          child: Icon(typeIcon(event.type), color: color),
        ),
        title: Text(
          showName
              ? '${event.staffName ?? 'Staff'} · ${event.type.label}'
              : '${event.type.label} · ${formatTime(event.effectiveTime)}',
          style: const TextStyle(fontWeight: FontWeight.w600),
        ),
        subtitle: Text(
          showName ? '${formatDate(event.effectiveTime)} ${formatTime(event.effectiveTime)} · $where' : where,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        ),
        trailing: _isPending
            ? const Tooltip(
                message: 'Saved offline. Will upload when you are back online.',
                child: Icon(Icons.cloud_upload_outlined),
              )
            : Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  StatusChip(event.status, compact: true),
                  if (event.isFlagged)
                    const Padding(
                      padding: EdgeInsets.only(top: 4),
                      child: Icon(Icons.flag_rounded, size: 16, color: Color(0xFFD97706)),
                    ),
                ],
              ),
      ),
    );
  }
}

/// Loads a verification photo through a short-lived signed link.
class EventPhoto extends StatefulWidget {
  const EventPhoto({super.key, required this.path, this.height = 280});

  final String? path;
  final double height;

  @override
  State<EventPhoto> createState() => _EventPhotoState();
}

class _EventPhotoState extends State<EventPhoto> {
  Future<String>? _url;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final path = widget.path;
    if (_url == null && path != null) {
      _url = context.read<AttendanceApi>().photoUrl(path);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    Widget placeholder(IconData icon, String text) => Container(
          height: widget.height,
          color: scheme.surfaceContainerHighest,
          alignment: Alignment.center,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 40, color: scheme.onSurfaceVariant),
              const SizedBox(height: 8),
              Text(text, style: TextStyle(color: scheme.onSurfaceVariant)),
            ],
          ),
        );

    final future = _url;
    final content = future == null
        ? placeholder(Icons.no_photography_outlined, 'No photo on this record')
        : FutureBuilder<String>(
            future: future,
            builder: (context, snap) {
              if (snap.hasError) return placeholder(Icons.broken_image_outlined, 'Photo unavailable');
              if (!snap.hasData) {
                return SizedBox(
                    height: widget.height, child: const Center(child: CircularProgressIndicator()));
              }
              return Image.network(
                snap.data!,
                height: widget.height,
                width: double.infinity,
                fit: BoxFit.cover,
                loadingBuilder: (context, child, progress) => progress == null
                    ? child
                    : SizedBox(
                        height: widget.height,
                        child: const Center(child: CircularProgressIndicator())),
                errorBuilder: (context, error, stack) =>
                    placeholder(Icons.broken_image_outlined, 'Photo unavailable'),
              );
            },
          );
    return ClipRRect(borderRadius: BorderRadius.circular(18), child: content);
  }
}

class EmptyMessage extends StatelessWidget {
  const EmptyMessage({super.key, required this.icon, required this.title, this.subtitle});

  final IconData icon;
  final String title;
  final String? subtitle;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 40, horizontal: 24),
      child: Column(
        children: [
          Icon(icon, size: 48, color: scheme.primary.withValues(alpha: 0.6)),
          const SizedBox(height: 12),
          Text(title, style: Theme.of(context).textTheme.titleMedium, textAlign: TextAlign.center),
          if (subtitle != null) ...[
            const SizedBox(height: 4),
            Text(subtitle!,
                textAlign: TextAlign.center, style: TextStyle(color: scheme.onSurfaceVariant)),
          ],
        ],
      ),
    );
  }
}

class InfoBanner extends StatelessWidget {
  const InfoBanner({
    super.key,
    required this.icon,
    required this.message,
    this.color,
    this.action,
    this.onAction,
  });

  final IconData icon;
  final String message;
  final Color? color;
  final String? action;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    final c = color ?? Theme.of(context).colorScheme.primary;
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.fromLTRB(14, 10, 8, 10),
      decoration: BoxDecoration(
        color: c.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: c.withValues(alpha: 0.3)),
      ),
      child: Row(
        children: [
          Icon(icon, color: c),
          const SizedBox(width: 10),
          Expanded(child: Text(message)),
          if (action != null) TextButton(onPressed: onAction, child: Text(action!)),
        ],
      ),
    );
  }
}
