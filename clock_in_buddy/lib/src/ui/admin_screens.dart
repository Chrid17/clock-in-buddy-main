import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../api/attendance_api.dart';
import '../models.dart';
import '../services/location_service.dart';
import '../state/attendance_controller.dart';
import '../state/session.dart';
import '../utils.dart';
import 'history_tab.dart';
import 'widgets.dart';

/// Manager area: live team status, reviews, work sites and staff.
class AdminTab extends StatelessWidget {
  const AdminTab({super.key});

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 4,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Team'),
          bottom: const TabBar(
            isScrollable: true,
            tabAlignment: TabAlignment.start,
            tabs: [
              Tab(text: 'Who\'s in'),
              Tab(text: 'Review'),
              Tab(text: 'Work sites'),
              Tab(text: 'Staff'),
            ],
          ),
        ),
        body: const TabBarView(
          children: [_TeamView(), _ReviewView(), _SitesView(), _StaffView()],
        ),
      ),
    );
  }
}

/// Loads data with pull-to-refresh, loading and error states.
class _Loader<T> extends StatefulWidget {
  const _Loader({super.key, required this.load, required this.builder});

  final Future<T> Function(AttendanceApi api) load;
  final Widget Function(BuildContext context, T data, Future<void> Function() reload) builder;

  @override
  State<_Loader<T>> createState() => _LoaderState<T>();
}

class _LoaderState<T> extends State<_Loader<T>> with AutomaticKeepAliveClientMixin {
  T? _data;
  String? _error;
  bool _loading = true;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  @override
  void didUpdateWidget(covariant _Loader<T> oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.key != widget.key) _reload();
  }

  Future<void> _reload() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final data = await widget.load(context.read<AttendanceApi>());
      if (!mounted) return;
      setState(() {
        _data = data;
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

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final data = _data;
    if (data == null) {
      if (_loading) return const Center(child: CircularProgressIndicator());
      return ListView(
        children: [
          EmptyMessage(icon: Icons.cloud_off_outlined, title: 'Could not load', subtitle: _error),
          Center(child: OutlinedButton(onPressed: _reload, child: const Text('Try again'))),
        ],
      );
    }
    return RefreshIndicator(onRefresh: _reload, child: widget.builder(context, data, _reload));
  }
}

// -----------------------------------------------------------------------------
// Who's in
// -----------------------------------------------------------------------------

class _TeamView extends StatelessWidget {
  const _TeamView();

  @override
  Widget build(BuildContext context) {
    return _Loader<List<TeamMember>>(
      load: (api) => api.teamStatus(),
      builder: (context, team, reload) {
        final active = team.where((m) => m.active).toList();
        final inNow = active.where((m) => m.isClockedIn).length;
        return ListView(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
          children: [
            Panel(
              child: Row(
                children: [
                  Expanded(child: _Count(label: 'Clocked in now', value: inNow, color: clockInColor)),
                  Expanded(child: _Count(label: 'Clocked out', value: active.length - inNow)),
                  Expanded(
                    child: _Count(
                      label: 'Awaiting review',
                      value: team.fold<int>(0, (sum, m) => sum + m.pendingReviews),
                      color: const Color(0xFFD97706),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),
            if (team.isEmpty)
              const EmptyMessage(icon: Icons.group_outlined, title: 'No staff yet',
                  subtitle: 'Staff appear here after they create an account.'),
            for (final m in team) _TeamTile(member: m, onChanged: reload),
          ],
        );
      },
    );
  }
}

class _Count extends StatelessWidget {
  const _Count({required this.label, required this.value, this.color});
  final String label;
  final int value;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      children: [
        Text('$value',
            style: theme.textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w800, color: color)),
        Text(label, textAlign: TextAlign.center, style: theme.textTheme.bodySmall),
      ],
    );
  }
}

class _TeamTile extends StatelessWidget {
  const _TeamTile({required this.member, required this.onChanged});
  final TeamMember member;
  final Future<void> Function() onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final status = member.lastType == null
        ? 'No clock-ins yet'
        : member.isClockedIn
            ? 'In since ${formatDayHeading(member.lastTime!) == 'Today' ? '' : '${formatDayHeading(member.lastTime!)} '}${formatTime(member.lastTime!)}'
                '${member.lastSiteName != null ? ' · ${member.lastSiteName}' : ''}'
                '${member.lastWithinSite == false ? ' (outside)' : ''}'
            : 'Out · last ${formatDayHeading(member.lastTime!).toLowerCase()} ${formatTime(member.lastTime!)}';
    final dot = member.isClockedIn ? clockInColor : theme.colorScheme.outline;
    return Card(
      elevation: 0,
      margin: const EdgeInsets.only(bottom: 8),
      color: theme.colorScheme.surfaceContainerLow,
      child: ListTile(
        onTap: () async {
          await Navigator.of(context).push(MaterialPageRoute<void>(
            builder: (_) => Scaffold(
              appBar: AppBar(title: Text(member.displayName)),
              body: HistoryView(userId: member.userId),
            ),
          ));
          await onChanged();
        },
        leading: Stack(
          clipBehavior: Clip.none,
          children: [
            CircleAvatar(child: Text(member.displayName.characters.first.toUpperCase())),
            Positioned(
              right: -1,
              bottom: -1,
              child: Container(
                width: 13,
                height: 13,
                decoration: BoxDecoration(
                  color: dot,
                  shape: BoxShape.circle,
                  border: Border.all(color: theme.colorScheme.surface, width: 2),
                ),
              ),
            ),
          ],
        ),
        title: Text(
          '${member.displayName}${member.active ? '' : ' (inactive)'}',
          style: const TextStyle(fontWeight: FontWeight.w600),
        ),
        subtitle: Text(status, maxLines: 2, overflow: TextOverflow.ellipsis),
        trailing: member.pendingReviews > 0
            ? Badge(
                label: Text('${member.pendingReviews}'),
                backgroundColor: const Color(0xFFD97706),
                child: const Icon(Icons.fact_check_outlined),
              )
            : const Icon(Icons.chevron_right),
      ),
    );
  }
}

// -----------------------------------------------------------------------------
// Review
// -----------------------------------------------------------------------------

enum _ReviewFilter { pending, flagged, all }

class _ReviewView extends StatefulWidget {
  const _ReviewView();

  @override
  State<_ReviewView> createState() => _ReviewViewState();
}

class _ReviewViewState extends State<_ReviewView> {
  _ReviewFilter _filter = _ReviewFilter.pending;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
          child: SegmentedButton<_ReviewFilter>(
            showSelectedIcon: false,
            segments: const [
              ButtonSegment(value: _ReviewFilter.pending, label: Text('Pending')),
              ButtonSegment(value: _ReviewFilter.flagged, label: Text('Flagged')),
              ButtonSegment(value: _ReviewFilter.all, label: Text('All')),
            ],
            selected: {_filter},
            onSelectionChanged: (s) => setState(() => _filter = s.first),
          ),
        ),
        Expanded(
          child: _Loader<List<AttendanceEvent>>(
            key: ValueKey(_filter),
            load: (api) => api.listEvents(
              status: _filter == _ReviewFilter.pending ? ReviewStatus.pending : null,
              flaggedOnly: _filter == _ReviewFilter.flagged,
              from: DateTime.now().subtract(const Duration(days: 60)),
              limit: 300,
            ),
            builder: (context, events, reload) => ListView(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
              children: [
                if (events.isEmpty)
                  EmptyMessage(
                    icon: Icons.task_alt,
                    title: _filter == _ReviewFilter.pending ? 'All caught up' : 'Nothing here',
                    subtitle: _filter == _ReviewFilter.pending
                        ? 'There are no clock-ins waiting for review.'
                        : null,
                  ),
                for (final e in events)
                  EventTile(event: e, showName: true, onChanged: (_) => reload()),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

// -----------------------------------------------------------------------------
// Work sites
// -----------------------------------------------------------------------------

class _SitesView extends StatefulWidget {
  const _SitesView();

  @override
  State<_SitesView> createState() => _SitesViewState();
}

class _SitesViewState extends State<_SitesView> {
  int _version = 0;

  Future<void> _edit([WorkSite? site]) async {
    final api = context.read<AttendanceApi>();
    final attendance = context.read<AttendanceController>();
    final result = await showDialog<WorkSite>(
      context: context,
      builder: (_) => _SiteDialog(site: site),
    );
    if (result == null || !mounted) return;
    try {
      await api.saveSite(result);
      if (!mounted) return;
      showSnack(context, site == null ? 'Work site added.' : 'Work site updated.');
      setState(() => _version++);
      attendance.refresh();
    } on ApiException catch (e) {
      if (mounted) showSnack(context, e.message, error: true);
    }
  }

  Future<void> _delete(WorkSite site) async {
    final api = context.read<AttendanceApi>();
    final ok = await confirm(context,
        title: 'Delete ${site.name}?',
        message: 'Past attendance keeps the site name. Staff who must be on site will need another site.',
        action: 'Delete',
        destructive: true);
    if (!ok || !mounted) return;
    try {
      await api.deleteSite(site.id!);
      if (mounted) setState(() => _version++);
    } on ApiException catch (e) {
      if (mounted) showSnack(context, e.message, error: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _edit(),
        icon: const Icon(Icons.add_location_alt_outlined),
        label: const Text('Add site'),
      ),
      body: _Loader<List<WorkSite>>(
        key: ValueKey(_version),
        load: (api) => api.listSites(),
        builder: (context, sites, reload) => ListView(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 96),
          children: [
            const InfoBanner(
              icon: Icons.info_outline,
              message: 'Clock-ins are matched to the nearest site. Turn on "Must be on site" '
                  'for a staff member to block clock-ins outside every site.',
            ),
            if (sites.isEmpty)
              const EmptyMessage(icon: Icons.location_city_outlined, title: 'No work sites yet',
                  subtitle: 'Add your office or client locations.'),
            for (final s in sites)
              Card(
                elevation: 0,
                margin: const EdgeInsets.only(bottom: 8),
                color: Theme.of(context).colorScheme.surfaceContainerLow,
                child: ListTile(
                  leading: Icon(Icons.location_on, color: s.active ? clockInColor : Colors.grey),
                  title: Text('${s.name}${s.active ? '' : ' (inactive)'}'),
                  subtitle: Text('${s.address ?? formatCoords(s.latitude, s.longitude)}\nRadius ${s.radiusM} m'),
                  isThreeLine: true,
                  onTap: () => _edit(s),
                  trailing: PopupMenuButton<String>(
                    onSelected: (v) {
                      if (v == 'edit') _edit(s);
                      if (v == 'map') openMap(context, s.latitude, s.longitude);
                      if (v == 'delete') _delete(s);
                    },
                    itemBuilder: (_) => const [
                      PopupMenuItem(value: 'edit', child: Text('Edit')),
                      PopupMenuItem(value: 'map', child: Text('Open in maps')),
                      PopupMenuItem(value: 'delete', child: Text('Delete')),
                    ],
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _SiteDialog extends StatefulWidget {
  const _SiteDialog({this.site});
  final WorkSite? site;

  @override
  State<_SiteDialog> createState() => _SiteDialogState();
}

class _SiteDialogState extends State<_SiteDialog> {
  final _form = GlobalKey<FormState>();
  late final _name = TextEditingController(text: widget.site?.name ?? '');
  late final _address = TextEditingController(text: widget.site?.address ?? '');
  late final _lat = TextEditingController(text: widget.site?.latitude.toStringAsFixed(6) ?? '');
  late final _lng = TextEditingController(text: widget.site?.longitude.toStringAsFixed(6) ?? '');
  late double _radius = (widget.site?.radiusM ?? 150).toDouble();
  late bool _active = widget.site?.active ?? true;
  bool _locating = false;

  @override
  void dispose() {
    _name.dispose();
    _address.dispose();
    _lat.dispose();
    _lng.dispose();
    super.dispose();
  }

  Future<void> _useCurrentLocation() async {
    setState(() => _locating = true);
    final service = LocationService();
    try {
      final fix = await service.currentFix();
      final address = await service.addressFor(fix.latitude, fix.longitude);
      if (!mounted) return;
      setState(() {
        _lat.text = fix.latitude.toStringAsFixed(6);
        _lng.text = fix.longitude.toStringAsFixed(6);
        if (address != null && _address.text.trim().isEmpty) _address.text = address;
      });
    } on LocationException catch (e) {
      if (mounted) showSnack(context, e.message, error: true);
    } finally {
      if (mounted) setState(() => _locating = false);
    }
  }

  String? _validateCoord(String? v, double limit) {
    final d = double.tryParse((v ?? '').trim());
    if (d == null) return 'Enter a number';
    if (d < -limit || d > limit) return 'Must be between -$limit and $limit';
    return null;
  }

  void _save() {
    if (!(_form.currentState?.validate() ?? false)) return;
    Navigator.of(context).pop(WorkSite(
      id: widget.site?.id,
      name: _name.text.trim(),
      address: _address.text.trim().isEmpty ? null : _address.text.trim(),
      latitude: double.parse(_lat.text.trim()),
      longitude: double.parse(_lng.text.trim()),
      radiusM: _radius.round(),
      active: _active,
    ));
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.site == null ? 'Add work site' : 'Edit work site'),
      content: SizedBox(
        width: 420,
        child: Form(
          key: _form,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextFormField(
                  controller: _name,
                  textCapitalization: TextCapitalization.words,
                  decoration: const InputDecoration(labelText: 'Name', hintText: 'Head office'),
                  validator: (v) => (v ?? '').trim().isEmpty ? 'Enter a name' : null,
                ),
                TextFormField(
                  controller: _address,
                  decoration: const InputDecoration(labelText: 'Address (optional)'),
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(
                      child: TextFormField(
                        controller: _lat,
                        keyboardType: const TextInputType.numberWithOptions(decimal: true, signed: true),
                        decoration: const InputDecoration(labelText: 'Latitude'),
                        validator: (v) => _validateCoord(v, 90),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: TextFormField(
                        controller: _lng,
                        keyboardType: const TextInputType.numberWithOptions(decimal: true, signed: true),
                        decoration: const InputDecoration(labelText: 'Longitude'),
                        validator: (v) => _validateCoord(v, 180),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton.icon(
                    onPressed: _locating ? null : _useCurrentLocation,
                    icon: _locating
                        ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                        : const Icon(Icons.my_location),
                    label: const Text('Use my current location'),
                  ),
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    const Text('Radius'),
                    Expanded(
                      child: Slider(
                        value: _radius,
                        min: 20,
                        max: 2000,
                        divisions: 199,
                        label: '${_radius.round()} m',
                        onChanged: (v) => setState(() => _radius = v),
                      ),
                    ),
                    SizedBox(width: 64, child: Text('${_radius.round()} m', textAlign: TextAlign.end)),
                  ],
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Active'),
                  value: _active,
                  onChanged: (v) => setState(() => _active = v),
                ),
              ],
            ),
          ),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Cancel')),
        FilledButton(onPressed: _save, child: const Text('Save')),
      ],
    );
  }
}

// -----------------------------------------------------------------------------
// Staff
// -----------------------------------------------------------------------------

class _StaffView extends StatefulWidget {
  const _StaffView();

  @override
  State<_StaffView> createState() => _StaffViewState();
}

class _StaffViewState extends State<_StaffView> {
  int _version = 0;

  Future<void> _update(StaffProfile p, {String? role, bool? requireSite, bool? active}) async {
    final api = context.read<AttendanceApi>();
    try {
      await api.updateStaff(p.userId, role: role, requireSite: requireSite, active: active);
      if (mounted) setState(() => _version++);
    } on ApiException catch (e) {
      if (mounted) showSnack(context, e.message, error: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final myId = context.select<Session, String?>((s) => s.userId);
    return _Loader<List<StaffProfile>>(
      key: ValueKey(_version),
      load: (api) => api.listStaff(),
      builder: (context, staff, reload) => ListView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
        children: [
          const InfoBanner(
            icon: Icons.person_add_alt,
            message: 'New staff join by creating an account in the app with their work email.',
          ),
          for (final p in staff)
            Card(
              elevation: 0,
              margin: const EdgeInsets.only(bottom: 8),
              color: Theme.of(context).colorScheme.surfaceContainerLow,
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Column(
                  children: [
                    ListTile(
                      leading: CircleAvatar(child: Text(p.displayName.characters.first.toUpperCase())),
                      title: Text('${p.displayName}${p.userId == myId ? ' (you)' : ''}',
                          style: const TextStyle(fontWeight: FontWeight.w600)),
                      subtitle: Text([p.email, p.jobTitle].whereType<String>().join(' · ')),
                      trailing: p.userId == myId
                          ? const Chip(label: Text('Manager'))
                          : PopupMenuButton<String>(
                              tooltip: 'Change role',
                              initialValue: p.role,
                              onSelected: (role) => _update(p, role: role),
                              itemBuilder: (_) => const [
                                PopupMenuItem(value: 'staff', child: Text('Staff')),
                                PopupMenuItem(value: 'admin', child: Text('Manager')),
                              ],
                              child: Chip(
                                label: Text(p.role == 'admin' ? 'Manager' : 'Staff'),
                                avatar: const Icon(Icons.arrow_drop_down, size: 18),
                              ),
                            ),
                    ),
                    SwitchListTile(
                      dense: true,
                      title: const Text('Must be on a work site to clock in'),
                      value: p.requireSite,
                      onChanged: (v) => _update(p, requireSite: v),
                    ),
                    if (p.userId != myId)
                      SwitchListTile(
                        dense: true,
                        title: const Text('Account active'),
                        value: p.active,
                        onChanged: (v) => _update(p, active: v),
                      ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}
