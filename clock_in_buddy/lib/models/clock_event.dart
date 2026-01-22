class ClockEvent {
  final String id;
  final String userId;
  final String eventType; // 'clock_in' or 'clock_out'
  final String? photoUrl;
  final double? latitude;
  final double? longitude;
  final String? address;
  final String? notes;
  final DateTime createdAt;

  ClockEvent({
    required this.id,
    required this.userId,
    required this.eventType,
    this.photoUrl,
    this.latitude,
    this.longitude,
    this.address,
    this.notes,
    required this.createdAt,
  });

  factory ClockEvent.fromJson(Map<String, dynamic> json) {
    return ClockEvent(
      id: json['id'] as String,
      userId: json['user_id'] as String,
      eventType: json['event_type'] as String,
      photoUrl: json['photo_url'] as String?,
      latitude: json['latitude'] != null ? (json['latitude'] as num).toDouble() : null,
      longitude: json['longitude'] != null ? (json['longitude'] as num).toDouble() : null,
      address: json['address'] as String?,
      notes: json['notes'] as String?,
      createdAt: DateTime.parse(json['created_at'] as String),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'user_id': userId,
      'event_type': eventType,
      'photo_url': photoUrl,
      'latitude': latitude,
      'longitude': longitude,
      'address': address,
      'notes': notes,
      'created_at': createdAt.toIso8601String(),
    };
  }

  bool get isClockIn => eventType == 'clock_in';
  bool get isClockOut => eventType == 'clock_out';
}
