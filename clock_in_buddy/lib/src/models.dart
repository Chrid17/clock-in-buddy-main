import 'dart:convert';
import 'dart:typed_data';

enum ClockType {
  clockIn('clock_in', 'Clock in'),
  clockOut('clock_out', 'Clock out');

  const ClockType(this.apiValue, this.label);

  final String apiValue;
  final String label;

  static ClockType fromApi(Object? value) =>
      value == 'clock_out' ? ClockType.clockOut : ClockType.clockIn;
}

enum ReviewStatus {
  pending('Pending review'),
  verified('Verified'),
  rejected('Rejected');

  const ReviewStatus(this.label);
  final String label;

  static ReviewStatus fromApi(Object? value) => switch (value) {
        'verified' => ReviewStatus.verified,
        'rejected' => ReviewStatus.rejected,
        _ => ReviewStatus.pending,
      };
}

/// Readable names for the review flags the server adds.
const Map<String, String> flagLabels = {
  'mock_location': 'Fake GPS detected',
  'outside_site': 'Outside work site',
  'low_accuracy': 'Low GPS accuracy',
  'offline': 'Captured offline',
  'device_clock_skew': 'Phone clock wrong',
  'imported': 'Imported from v1',
};

double? _toDouble(Object? v) => v is num ? v.toDouble() : null;
DateTime? _toTime(Object? v) =>
    v is String && v.isNotEmpty ? DateTime.tryParse(v)?.toLocal() : null;
String? _toText(Object? v) => v is String && v.trim().isNotEmpty ? v : null;

class AttendanceEvent {
  const AttendanceEvent({
    required this.id,
    required this.userId,
    required this.type,
    required this.serverTime,
    this.staffName,
    this.deviceTime,
    this.latitude,
    this.longitude,
    this.accuracyM,
    this.isMocked = false,
    this.address,
    this.siteName,
    this.distanceM,
    this.withinSite,
    this.photoPath,
    this.photoSha256,
    this.notes,
    this.platform,
    this.capturedOffline = false,
    this.flags = const [],
    this.status = ReviewStatus.pending,
    this.reviewNote,
    this.reviewedAt,
    this.odooSynced = false,
    this.odooError,
  });

  final String id;
  final String userId;
  final ClockType type;

  /// Set by the server when the event was recorded. This is the trusted time.
  final DateTime serverTime;
  final String? staffName;

  /// The phone's clock when the photo and location were captured.
  final DateTime? deviceTime;
  final double? latitude;
  final double? longitude;
  final double? accuracyM;
  final bool isMocked;
  final String? address;
  final String? siteName;
  final double? distanceM;
  final bool? withinSite;
  final String? photoPath;
  final String? photoSha256;
  final String? notes;
  final String? platform;
  final bool capturedOffline;
  final List<String> flags;
  final ReviewStatus status;
  final String? reviewNote;
  final DateTime? reviewedAt;
  final bool odooSynced;
  final String? odooError;

  /// When the person actually clocked: the capture time for offline events,
  /// otherwise the server time.
  DateTime get effectiveTime =>
      capturedOffline && deviceTime != null ? deviceTime! : serverTime;

  bool get hasLocation => latitude != null && longitude != null;
  bool get isFlagged => flags.any((f) => f != 'imported');

  factory AttendanceEvent.fromJson(Map<String, dynamic> json) {
    final rawFlags = json['flags'];
    return AttendanceEvent(
      id: json['id'] as String,
      userId: json['user_id'] as String,
      type: ClockType.fromApi(json['event_type']),
      serverTime: _toTime(json['server_time']) ?? DateTime.now(),
      staffName: _toText(json['staff_name']),
      deviceTime: _toTime(json['device_time']),
      latitude: _toDouble(json['latitude']),
      longitude: _toDouble(json['longitude']),
      accuracyM: _toDouble(json['accuracy_m']),
      isMocked: json['is_mocked'] == true,
      address: _toText(json['address']),
      siteName: _toText(json['site_name']),
      distanceM: _toDouble(json['distance_m']),
      withinSite: json['within_site'] is bool ? json['within_site'] as bool : null,
      photoPath: _toText(json['photo_path']),
      photoSha256: _toText(json['photo_sha256']),
      notes: _toText(json['notes']),
      platform: _toText(json['platform']),
      capturedOffline: json['captured_offline'] == true,
      flags: rawFlags is List ? rawFlags.whereType<String>().toList() : const [],
      status: ReviewStatus.fromApi(json['status']),
      reviewNote: _toText(json['review_note']),
      reviewedAt: _toTime(json['reviewed_at']),
      odooSynced: json['odoo_synced'] == true,
      odooError: _toText(json['odoo_error']),
    );
  }
}

class StaffProfile {
  const StaffProfile({
    required this.userId,
    this.fullName,
    this.email,
    this.jobTitle,
    this.role = 'staff',
    this.requireSite = false,
    this.active = true,
  });

  final String userId;
  final String? fullName;
  final String? email;
  final String? jobTitle;
  final String role;
  final bool requireSite;
  final bool active;

  bool get isAdmin => role == 'admin' && active;

  String get displayName => fullName ?? email ?? 'Staff member';

  factory StaffProfile.fromJson(Map<String, dynamic> json) => StaffProfile(
        userId: json['user_id'] as String,
        fullName: _toText(json['full_name']),
        email: _toText(json['email']),
        jobTitle: _toText(json['job_title']),
        role: json['role'] == 'admin' ? 'admin' : 'staff',
        requireSite: json['require_site'] == true,
        active: json['active'] != false,
      );
}

class WorkSite {
  const WorkSite({
    this.id,
    required this.name,
    required this.latitude,
    required this.longitude,
    this.radiusM = 150,
    this.address,
    this.active = true,
  });

  final String? id;
  final String name;
  final double latitude;
  final double longitude;
  final int radiusM;
  final String? address;
  final bool active;

  Map<String, dynamic> toJson() => {
        'name': name,
        'latitude': latitude,
        'longitude': longitude,
        'radius_m': radiusM,
        'address': address,
        'active': active,
      };

  factory WorkSite.fromJson(Map<String, dynamic> json) => WorkSite(
        id: json['id'] as String?,
        name: (json['name'] as String?) ?? 'Site',
        latitude: _toDouble(json['latitude']) ?? 0,
        longitude: _toDouble(json['longitude']) ?? 0,
        radiusM: (json['radius_m'] as num?)?.toInt() ?? 150,
        address: _toText(json['address']),
        active: json['active'] != false,
      );
}

class TeamMember {
  const TeamMember({
    required this.userId,
    this.fullName,
    this.email,
    this.jobTitle,
    this.role = 'staff',
    this.active = true,
    this.lastType,
    this.lastTime,
    this.lastSiteName,
    this.lastWithinSite,
    this.pendingReviews = 0,
  });

  final String userId;
  final String? fullName;
  final String? email;
  final String? jobTitle;
  final String role;
  final bool active;
  final ClockType? lastType;
  final DateTime? lastTime;
  final String? lastSiteName;
  final bool? lastWithinSite;
  final int pendingReviews;

  bool get isClockedIn => lastType == ClockType.clockIn;
  String get displayName => fullName ?? email ?? 'Staff member';

  factory TeamMember.fromJson(Map<String, dynamic> json) => TeamMember(
        userId: json['user_id'] as String,
        fullName: _toText(json['full_name']),
        email: _toText(json['email']),
        jobTitle: _toText(json['job_title']),
        role: json['role'] == 'admin' ? 'admin' : 'staff',
        active: json['active'] != false,
        lastType: json['last_event_type'] == null
            ? null
            : ClockType.fromApi(json['last_event_type']),
        lastTime: _toTime(json['last_event_time']),
        lastSiteName: _toText(json['last_site_name']),
        lastWithinSite:
            json['last_within_site'] is bool ? json['last_within_site'] as bool : null,
        pendingReviews: (json['pending_reviews'] as num?)?.toInt() ?? 0,
      );
}

/// Everything captured on the phone for one clock action.
class ClockDraft {
  ClockDraft({
    required this.type,
    required this.photo,
    required this.photoSha256,
    required this.latitude,
    required this.longitude,
    required this.accuracyM,
    required this.isMocked,
    required this.deviceTime,
    required this.platform,
    this.address,
    this.notes,
    String? id,
  }) : id = id ?? '${deviceTime.microsecondsSinceEpoch}';

  final String id;
  final ClockType type;
  final Uint8List photo;
  final String photoSha256;
  final double latitude;
  final double longitude;
  final double accuracyM;
  final bool isMocked;
  final DateTime deviceTime;
  final String platform;
  final String? address;
  final String? notes;

  Map<String, dynamic> toJson() => {
        'id': id,
        'type': type.apiValue,
        'photo': base64Encode(photo),
        'photoSha256': photoSha256,
        'latitude': latitude,
        'longitude': longitude,
        'accuracyM': accuracyM,
        'isMocked': isMocked,
        'deviceTime': deviceTime.toUtc().toIso8601String(),
        'platform': platform,
        'address': address,
        'notes': notes,
      };

  factory ClockDraft.fromJson(Map<String, dynamic> json) => ClockDraft(
        id: json['id'] as String?,
        type: ClockType.fromApi(json['type']),
        photo: base64Decode(json['photo'] as String),
        photoSha256: json['photoSha256'] as String,
        latitude: (json['latitude'] as num).toDouble(),
        longitude: (json['longitude'] as num).toDouble(),
        accuracyM: (json['accuracyM'] as num).toDouble(),
        isMocked: json['isMocked'] == true,
        deviceTime: DateTime.parse(json['deviceTime'] as String).toLocal(),
        platform: (json['platform'] as String?) ?? 'unknown',
        address: json['address'] as String?,
        notes: json['notes'] as String?,
      );
}
