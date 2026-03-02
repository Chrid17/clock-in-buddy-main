import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../services/clock_events_service.dart';
import '../../services/camera_service.dart';
import '../../services/geolocation_service.dart';
import '../../services/odoo_service.dart';
import '../../services/auth_service.dart';
import 'package:camera/camera.dart';

enum ClockStep { idle, camera, confirm }

class ClockButton extends StatefulWidget {
  const ClockButton({super.key});

  @override
  State<ClockButton> createState() => _ClockButtonState();
}

class _ClockButtonState extends State<ClockButton> {
  ClockStep _step = ClockStep.idle;
  bool _submitting = false;
  String? _capturedPhoto;
  
  final CameraService _cameraService = CameraService();
  final GeolocationService _geoService = GeolocationService();

  @override
  void dispose() {
    _cameraService.dispose();
    super.dispose();
  }

  Future<void> _startClock() async {
    setState(() => _step = ClockStep.camera);
    
    // Initialize camera and get location simultaneously
    await Future.wait([
      _cameraService.initializeCamera(),
      _geoService.getLocation(),
    ]);
    
    if (mounted) setState(() {});
  }

  Future<void> _capturePhoto() async {
    final photo = await _cameraService.capturePhoto();
    if (photo != null && mounted) {
      setState(() {
        _capturedPhoto = photo;
        _step = ClockStep.confirm;
      });
      _cameraService.dispose();
    }
  }

  Future<void> _confirmClock() async {
    if (_capturedPhoto == null) return;

    setState(() => _submitting = true);

    final clockEventsService = context.read<ClockEventsService>();
    final isClockedIn = clockEventsService.isClockedIn;
    final eventType = isClockedIn ? 'clock_out' : 'clock_in';

    final result = await clockEventsService.createClockEvent(
      eventType: eventType,
      photoBase64: _capturedPhoto,
      latitude: _geoService.latitude,
      longitude: _geoService.longitude,
      address: _geoService.address,
    );

    if (mounted) {
      setState(() => _submitting = false);

      if (result.success) {
        // Start Odoo Sync automatically
        _syncToOdoo(eventType);
        
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              isClockedIn ? 'Successfully clocked out!' : 'Successfully clocked in!',
            ),
            backgroundColor: Colors.green,
          ),
        );
        _handleCancel();
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(result.error ?? 'Failed to record clock event'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  Future<void> _syncToOdoo(String eventType) async {
    final odooService = context.read<OdooService>();
    final authService = context.read<AuthService>();
    
    final email = authService.user?.email;
    final fullName = authService.user?.userMetadata?['full_name'];

    debugPrint('Odoo Sync Start (via Edge Function) - Email: $email, Name: $fullName');

    try {
      final success = await odooService.syncClockEvent(
        eventType: eventType,
        email: email,
        name: fullName,
        lat: _geoService.latitude,
        lng: _geoService.longitude,
        address: _geoService.address,
      );

      if (mounted) {
        if (success) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Synced with Odoo successfully'),
              backgroundColor: Colors.blue,
              duration: Duration(seconds: 2),
            ),
          );
        } else {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Odoo Sync Failed: ${odooService.error ?? "Unknown error"}'),
              backgroundColor: Colors.orange,
            ),
          );
        }
      }
    } catch (e) {
      debugPrint('Odoo Sync Exception: $e');
    }
  }

  void _handleCancel() {
    _cameraService.dispose();
    _geoService.reset();
    setState(() {
      _step = ClockStep.idle;
      _capturedPhoto = null;
    });
  }

  void _handleRetake() {
    setState(() {
      _capturedPhoto = null;
      _step = ClockStep.camera;
    });
    _cameraService.initializeCamera().then((_) {
      if (mounted) setState(() {});
    });
  }

  @override
  Widget build(BuildContext context) {
    return switch (_step) {
      ClockStep.idle => _buildIdleView(),
      ClockStep.camera => _buildCameraView(),
      ClockStep.confirm => _buildConfirmView(),
    };
  }

  Widget _buildIdleView() {
    final theme = Theme.of(context);
    final clockEventsService = context.watch<ClockEventsService>();
    final isClockedIn = clockEventsService.isClockedIn;

    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Container(
            width: 180,
            height: 180,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: isClockedIn
                  ? Colors.green.withOpacity(0.1)
                  : theme.colorScheme.surfaceVariant,
              border: Border.all(
                color: isClockedIn ? Colors.green : theme.colorScheme.outline,
                width: 4,
              ),
            ),
            child: Icon(
              Icons.access_time,
              size: 80,
              color: isClockedIn ? Colors.green : theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 24),
          Text(
            isClockedIn ? 'Currently Clocked In' : 'Currently Clocked Out',
            style: theme.textTheme.titleLarge?.copyWith(
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'Tap below to ${isClockedIn ? 'clock out' : 'clock in'}',
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurface.withOpacity(0.6),
            ),
          ),
          const SizedBox(height: 32),
          SizedBox(
            width: double.infinity,
            height: 56,
            child: FilledButton.icon(
              onPressed: _startClock,
              icon: const Icon(Icons.camera_alt),
              label: Text(isClockedIn ? 'Clock Out' : 'Clock In'),
              style: FilledButton.styleFrom(
                backgroundColor: isClockedIn ? Colors.orange : theme.colorScheme.primary,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(16),
                ),
                textStyle: const TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildCameraView() {
    final theme = Theme.of(context);

    return Column(
      children: [
        Expanded(
          child: ClipRRect(
            borderRadius: BorderRadius.circular(20),
            child: Container(
              color: theme.colorScheme.surfaceVariant,
              child: _cameraService.isInitialized && _cameraService.controller != null
                  ? CameraPreview(_cameraService.controller!)
                  : _cameraService.error != null
                      ? Center(
                          child: Padding(
                            padding: const EdgeInsets.all(24),
                            child: Text(
                              _cameraService.error!,
                              textAlign: TextAlign.center,
                              style: TextStyle(color: theme.colorScheme.error),
                            ),
                          ),
                        )
                      : const Center(child: CircularProgressIndicator()),
            ),
          ),
        ),
        const SizedBox(height: 16),
        _buildLocationInfo(),
        const SizedBox(height: 16),
        Row(
          children: [
            Expanded(
              child: OutlinedButton(
                onPressed: _handleCancel,
                style: OutlinedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
                child: const Text('Cancel'),
              ),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: FilledButton.icon(
                onPressed: _cameraService.isInitialized ? _capturePhoto : null,
                icon: const Icon(Icons.camera_alt),
                label: const Text('Capture'),
                style: FilledButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildConfirmView() {
    final theme = Theme.of(context);
    final clockEventsService = context.watch<ClockEventsService>();
    final isClockedIn = clockEventsService.isClockedIn;

    return Column(
      children: [
        Expanded(
          child: ClipRRect(
            borderRadius: BorderRadius.circular(20),
            child: Stack(
              fit: StackFit.expand,
              children: [
                if (_capturedPhoto != null)
                  Image.memory(
                    base64Decode(_capturedPhoto!.split(',').last),
                    fit: BoxFit.cover,
                  ),
                Positioned(
                  top: 12,
                  right: 12,
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                    decoration: BoxDecoration(
                      color: Colors.green,
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: const Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.check_circle, color: Colors.white, size: 16),
                        SizedBox(width: 4),
                        Text(
                          'Photo Ready',
                          style: TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.w600,
                            fontSize: 12,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 16),
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: theme.colorScheme.surfaceVariant,
            borderRadius: BorderRadius.circular(12),
          ),
          child: Row(
            children: [
              Icon(Icons.access_time, size: 20, color: theme.colorScheme.onSurfaceVariant),
              const SizedBox(width: 8),
              Text(
                DateTime.now().toString().substring(0, 19),
                style: theme.textTheme.bodyMedium,
              ),
            ],
          ),
        ),
        const SizedBox(height: 8),
        _buildLocationInfo(),
        const SizedBox(height: 16),
        Row(
          children: [
            Expanded(
              child: OutlinedButton(
                onPressed: _handleRetake,
                style: OutlinedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
                child: const Text('Retake'),
              ),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: FilledButton.icon(
                onPressed: _submitting ? null : _confirmClock,
                icon: _submitting
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Colors.white,
                        ),
                      )
                    : const Icon(Icons.check_circle),
                label: Text('Confirm ${isClockedIn ? 'Clock Out' : 'Clock In'}'),
                style: FilledButton.styleFrom(
                  backgroundColor: isClockedIn ? Colors.orange : Colors.green,
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        TextButton.icon(
          onPressed: _handleCancel,
          icon: const Icon(Icons.cancel),
          label: const Text('Cancel'),
        ),
      ],
    );
  }

  Widget _buildLocationInfo() {
    final theme = Theme.of(context);

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceVariant,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          Icon(Icons.location_on, size: 20, color: theme.colorScheme.onSurfaceVariant),
          const SizedBox(width: 8),
          Expanded(
            child: _geoService.loading
                ? Row(
                    children: [
                      SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: theme.colorScheme.primary,
                        ),
                      ),
                      const SizedBox(width: 8),
                      const Text('Getting location...'),
                    ],
                  )
                : _geoService.error != null
                    ? Text(
                        _geoService.error!,
                        style: TextStyle(color: theme.colorScheme.error),
                      )
                    : Text(
                        _geoService.address ?? 'Location ready',
                        style: theme.textTheme.bodyMedium,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
          ),
        ],
      ),
    );
  }
}
