import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../api/attendance_api.dart';
import '../state/session.dart';
import 'widgets.dart';

class ProfileTab extends StatelessWidget {
  const ProfileTab({super.key});

  Future<void> _edit(BuildContext context) async {
    final session = context.read<Session>();
    final profile = session.profile;
    final name = TextEditingController(text: profile?.fullName ?? '');
    final title = TextEditingController(text: profile?.jobTitle ?? '');
    final saved = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Edit profile'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: name,
              textCapitalization: TextCapitalization.words,
              decoration: const InputDecoration(labelText: 'Full name'),
            ),
            TextField(
              controller: title,
              textCapitalization: TextCapitalization.words,
              decoration: const InputDecoration(labelText: 'Job title'),
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.of(context).pop(true), child: const Text('Save')),
        ],
      ),
    );
    if (saved != true || name.text.trim().length < 2) return;
    try {
      await session.updateProfile(fullName: name.text, jobTitle: title.text);
      if (context.mounted) showSnack(context, 'Profile updated.');
    } on ApiException catch (e) {
      if (context.mounted) showSnack(context, e.message, error: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final session = context.watch<Session>();
    final profile = session.profile;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final name = session.displayName;
    final jobTitle = profile?.jobTitle;

    return Scaffold(
      appBar: AppBar(title: const Text('Profile')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 32),
        children: [
          Center(
            child: CircleAvatar(
              radius: 40,
              backgroundColor: scheme.primaryContainer,
              child: Text(
                name.isEmpty ? '?' : name.characters.first.toUpperCase(),
                style: theme.textTheme.headlineMedium?.copyWith(color: scheme.onPrimaryContainer),
              ),
            ),
          ),
          const SizedBox(height: 12),
          Center(child: Text(name, style: theme.textTheme.titleLarge)),
          if (jobTitle != null)
            Center(child: Text(jobTitle, style: theme.textTheme.bodyMedium)),
          const SizedBox(height: 4),
          Center(
            child: Text(session.user?.email ?? '',
                style: theme.textTheme.bodyMedium?.copyWith(color: scheme.onSurfaceVariant)),
          ),
          const SizedBox(height: 8),
          Center(
            child: Chip(
              avatar: Icon(session.isAdmin ? Icons.admin_panel_settings_outlined : Icons.badge_outlined,
                  size: 18),
              label: Text(session.isAdmin ? 'Manager' : 'Staff'),
            ),
          ),
          const SizedBox(height: 20),
          Panel(
            padding: EdgeInsets.zero,
            child: Column(
              children: [
                ListTile(
                  leading: const Icon(Icons.edit_outlined),
                  title: const Text('Edit name and job title'),
                  onTap: () => _edit(context),
                ),
                if (profile?.requireSite ?? false)
                  const ListTile(
                    leading: Icon(Icons.location_city_outlined),
                    title: Text('You must be at a work site to clock in or out'),
                  ),
                ListTile(
                  leading: Icon(Icons.logout, color: scheme.error),
                  title: Text('Sign out', style: TextStyle(color: scheme.error)),
                  onTap: () async {
                    final ok = await confirm(context,
                        title: 'Sign out?',
                        message: 'Clock actions saved offline stay on this phone and upload when you sign back in.',
                        action: 'Sign out');
                    if (ok) await session.signOut();
                  },
                ),
              ],
            ),
          ),
          const SizedBox(height: 20),
          Panel(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('How your attendance is verified', style: theme.textTheme.titleSmall),
                const SizedBox(height: 8),
                const _Point(Icons.photo_camera_front_outlined,
                    'A selfie is taken with the front camera each time you clock in or out.'),
                const _Point(Icons.my_location,
                    'Your GPS position and its accuracy are recorded at that moment only. The app does not track you otherwise.'),
                const _Point(Icons.schedule,
                    'The official time comes from the server, not your phone.'),
                const _Point(Icons.lock_outline,
                    'Photos are private. Only you and your managers can see them.'),
              ],
            ),
          ),
          const SizedBox(height: 16),
          Center(
            child: Text('Clock In Buddy 2.0.0',
                style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant)),
          ),
        ],
      ),
    );
  }
}

class _Point extends StatelessWidget {
  const _Point(this.icon, this.text);
  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 20, color: Theme.of(context).colorScheme.primary),
          const SizedBox(width: 10),
          Expanded(child: Text(text)),
        ],
      ),
    );
  }
}
