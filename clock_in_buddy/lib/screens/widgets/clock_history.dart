import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:intl/intl.dart';
import 'package:url_launcher/url_launcher.dart';
import '../../services/clock_events_service.dart';
import '../../services/auth_service.dart';
import '../../models/clock_event.dart';

class ClockHistory extends StatelessWidget {
  const ClockHistory({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final service = context.watch<ClockEventsService>();
    final authService = context.watch<AuthService>();
    final fullName = authService.user?.userMetadata?['full_name'] ?? 'Employee';

    if (service.loading) {
      return const Center(child: CircularProgressIndicator());
    }

    if (service.events.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.access_time,
              size: 64,
              color: theme.colorScheme.onSurface.withOpacity(0.3),
            ),
            const SizedBox(height: 16),
            Text(
              'No clock events yet',
              style: theme.textTheme.titleMedium?.copyWith(
                color: theme.colorScheme.onSurface.withOpacity(0.6),
              ),
            ),
          ],
        ),
      );
    }

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(16.0),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                'Recent History',
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.bold,
                ),
              ),
              TextButton.icon(
                onPressed: () => service.exportToCsv(fullName),
                icon: const Icon(Icons.download),
                label: const Text('Export CSV'),
                style: TextButton.styleFrom(
                  foregroundColor: theme.colorScheme.primary,
                ),
              ),
            ],
          ),
        ),
        Expanded(
          child: RefreshIndicator(
            onRefresh: () => service.fetchEvents(),
            child: ListView.builder(
              padding: const EdgeInsets.all(16),
              itemCount: service.events.length,
              itemBuilder: (context, index) {
                final event = service.events[index];
                return _ClockEventCard(event: event);
              },
            ),
          ),
        ),
      ],
    );
  }
}

class _ClockEventCard extends StatelessWidget {
  final ClockEvent event;

  const _ClockEventCard({required this.event});

  void _showDetails(BuildContext context) {
    final theme = Theme.of(context);
    showDialog(
      context: context,
      builder: (context) => Dialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
        clipBehavior: Clip.antiAlias,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Photo Header
              if (event.photoUrl != null)
                _buildPhoto(event.photoUrl!, height: 300, width: double.infinity)
              else
                Container(
                  height: 120,
                  width: double.infinity,
                  color: theme.colorScheme.surfaceVariant,
                  child: Icon(Icons.image_not_supported, size: 48, color: theme.colorScheme.onSurfaceVariant),
                ),
              
              Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(
                          event.eventType == 'clock_in' ? Icons.login : Icons.logout,
                          color: event.eventType == 'clock_in' ? Colors.green : Colors.orange,
                        ),
                        const SizedBox(width: 12),
                        Text(
                          event.eventType == 'clock_in' ? 'Clocked In' : 'Clocked Out',
                          style: theme.textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.bold),
                        ),
                      ],
                    ),
                    const SizedBox(height: 24),
                    _DetailItem(
                      icon: Icons.access_time,
                      label: 'Time',
                      value: DateFormat('hh:mm:ss a').format(event.createdAt.toLocal()),
                    ),
                    _DetailItem(
                      icon: Icons.calendar_today,
                      label: 'Date',
                      value: DateFormat('EEEE, MMMM dd, yyyy').format(event.createdAt.toLocal()),
                    ),
                    if (event.address != null)
                      _DetailItem(
                        icon: Icons.location_on,
                        label: 'Location',
                        value: event.address!,
                      ),
                    
                    if (event.latitude != null && event.longitude != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 8),
                        child: OutlinedButton.icon(
                          onPressed: () => _openMap(event.latitude!, event.longitude!),
                          icon: const Icon(Icons.map),
                          label: const Text('View on Google Maps'),
                          style: OutlinedButton.styleFrom(
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                          ),
                        ),
                      ),
                    
                    const SizedBox(height: 32),
                    Row(
                      children: [
                        Expanded(
                          child: TextButton(
                            onPressed: () => Navigator.pop(context),
                            child: const Text('Close'),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: FilledButton.icon(
                            onPressed: () => _confirmDelete(context),
                            style: FilledButton.styleFrom(
                              backgroundColor: theme.colorScheme.error,
                              foregroundColor: theme.colorScheme.onError,
                              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                            ),
                            icon: const Icon(Icons.delete_outline),
                            label: const Text('Delete'),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _openMap(double lat, double lon) async {
    final url = Uri.parse('https://www.google.com/maps/search/?api=1&query=$lat,$lon');
    if (await canLaunchUrl(url)) {
      await launchUrl(url);
    }
  }

  void _confirmDelete(BuildContext context) {
    bool isDeleting = false;
    showDialog(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Delete Record?'),
        content: const Text('This will permanently delete this clock-in record.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('Cancel'),
          ),
          StatefulBuilder(
            builder: (context, setDialogState) {
              return TextButton(
                onPressed: isDeleting ? null : () async {
                  setDialogState(() => isDeleting = true);
                  
                  try {
                    // Use a local reference to the service before jumping async
                    final service = Provider.of<ClockEventsService>(context, listen: false);
                    final result = await service.deleteClockEvent(event.id);
                    
                    if (dialogContext.mounted) {
                      Navigator.pop(dialogContext); // Close confirm
                      if (context.mounted) {
                        Navigator.pop(context); // Close details
                        
                        if (result.success) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(
                              content: Text('Record deleted successfully'),
                              backgroundColor: Colors.green,
                              duration: Duration(seconds: 2),
                            ),
                          );
                        } else {
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(
                              content: Text('Delete failed: ${result.error}'),
                              backgroundColor: Colors.red,
                            ),
                          );
                        }
                      }
                    }
                  } catch (e) {
                    if (dialogContext.mounted) {
                      Navigator.pop(dialogContext);
                      if (context.mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(content: Text('Error: $e'), backgroundColor: Colors.red),
                        );
                      }
                    }
                  }
                },
                style: TextButton.styleFrom(foregroundColor: Theme.of(context).colorScheme.error),
                child: isDeleting 
                  ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Text('Delete'),
              );
            }
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isClockIn = event.eventType == 'clock_in';
    final color = isClockIn ? Colors.green : Colors.orange;

    return Card(
      elevation: 0,
      margin: const EdgeInsets.only(bottom: 12),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(color: theme.colorScheme.outline.withOpacity(0.1)),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => _showDetails(context),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              Container(
                width: 48,
                height: 48,
                decoration: BoxDecoration(
                  color: color.withOpacity(0.1),
                  shape: BoxShape.circle,
                ),
                child: Icon(
                  isClockIn ? Icons.login : Icons.logout,
                  color: color,
                ),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      isClockIn ? 'Clocked In' : 'Clocked Out',
                      style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.bold),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      DateFormat('h:mm a, MMM d').format(event.createdAt.toLocal()),
                      style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurface.withOpacity(0.6)),
                    ),
                    if (event.address != null) ...[
                      const SizedBox(height: 2),
                      Text(
                        event.address!,
                        style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurface.withOpacity(0.4)),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ],
                ),
              ),
              if (event.photoUrl != null) ...[
                const SizedBox(width: 12),
                ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: _buildPhoto(event.photoUrl!, width: 48, height: 48),
                ),
              ],
              const SizedBox(width: 8),
              Icon(Icons.chevron_right, size: 20, color: theme.colorScheme.onSurface.withOpacity(0.3)),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildPhoto(String photoUrl, {double? width, double? height}) {
    if (photoUrl.startsWith('data:image')) {
      try {
        final base64Data = photoUrl.split(',').last;
        return Image.memory(
          base64Decode(base64Data),
          width: width,
          height: height,
          fit: BoxFit.cover,
          errorBuilder: (_, _, _) => const Icon(Icons.broken_image),
        );
      } catch (_) {
        return const Icon(Icons.broken_image);
      }
    }
    return Image.network(
      photoUrl,
      width: width,
      height: height,
      fit: BoxFit.cover,
      errorBuilder: (_, _, _) => const Icon(Icons.broken_image),
    );
  }
}

class _DetailItem extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;

  const _DetailItem({required this.icon, required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 20, color: theme.colorScheme.primary.withOpacity(0.7)),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label, style: theme.textTheme.labelSmall?.copyWith(color: theme.colorScheme.onSurface.withOpacity(0.5))),
                const SizedBox(height: 2),
                Text(value, style: theme.textTheme.bodyMedium),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
