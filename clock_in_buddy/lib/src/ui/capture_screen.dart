import 'dart:typed_data';

import 'package:camera/camera.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../config.dart';
import '../models.dart';
import '../services/location_service.dart';
import '../state/attendance_controller.dart';
import '../utils.dart';
import 'widgets.dart';

/// Takes the verification selfie and location, then records the clock action.
class CaptureScreen extends StatefulWidget {
  const CaptureScreen({super.key, required this.type});

  final ClockType type;

  @override
  State<CaptureScreen> createState() => _CaptureScreenState();
}

class _CaptureScreenState extends State<CaptureScreen> with WidgetsBindingObserver {
  final _location = LocationService();
  final _notes = TextEditingController();

  CameraController? _camera;
  bool _cameraLoading = true;
  String? _cameraError;
  bool _taking = false;

  Uint8List? _photo;
  String? _photoHash;
  DateTime? _photoTime;

  LocationFix? _fix;
  String? _address;
  bool _locating = false;
  LocationException? _locationError;

  bool _submitting = false;
  String? _submitError;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _startCamera();
    _locate();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _camera?.dispose();
    _notes.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final camera = _camera;
    if (state == AppLifecycleState.inactive && camera != null) {
      _camera = null;
      camera.dispose();
      if (mounted) setState(() {});
    } else if (state == AppLifecycleState.resumed && _camera == null && _photo == null) {
      _startCamera();
    }
  }

  // ---------------------------------------------------------------------------
  // Camera
  // ---------------------------------------------------------------------------

  Future<void> _startCamera() async {
    setState(() {
      _cameraLoading = true;
      _cameraError = null;
    });
    try {
      final cameras = await availableCameras();
      if (cameras.isEmpty) {
        throw CameraException('NoCamera', 'No camera found');
      }
      final camera = cameras.firstWhere(
        (c) => c.lensDirection == CameraLensDirection.front,
        orElse: () => cameras.first,
      );
      final controller = CameraController(
        camera,
        ResolutionPreset.medium,
        enableAudio: false,
        imageFormatGroup: ImageFormatGroup.jpeg,
      );
      await controller.initialize();
      if (!mounted) {
        await controller.dispose();
        return;
      }
      setState(() {
        _camera = controller;
        _cameraLoading = false;
      });
    } on CameraException catch (e) {
      if (!mounted) return;
      setState(() {
        _cameraLoading = false;
        _cameraError = switch (e.code) {
          'CameraAccessDenied' ||
          'CameraAccessDeniedWithoutPrompt' ||
          'CameraAccessRestricted' ||
          'cameraPermission' =>
            'Camera permission is needed for your verification photo. Allow it in Settings.',
          'NoCamera' => 'No camera was found. A photo is required to clock in or out.',
          _ => 'Could not start the camera (${e.description ?? e.code}).',
        };
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _cameraLoading = false;
        _cameraError = 'Could not start the camera on this device.';
      });
    }
  }

  Future<void> _takePhoto() async {
    final camera = _camera;
    if (camera == null || !camera.value.isInitialized || _taking) return;
    setState(() => _taking = true);
    try {
      final file = await camera.takePicture();
      final bytes = await file.readAsBytes();
      if (!mounted) return;
      setState(() {
        _photo = bytes;
        _photoHash = sha256.convert(bytes).toString();
        _photoTime = DateTime.now();
      });
    } catch (e) {
      if (mounted) showSnack(context, 'Could not take the photo. Please try again.', error: true);
    } finally {
      if (mounted) setState(() => _taking = false);
    }
  }

  void _retake() => setState(() {
        _photo = null;
        _photoHash = null;
        _photoTime = null;
      });

  // ---------------------------------------------------------------------------
  // Location
  // ---------------------------------------------------------------------------

  Future<void> _locate() async {
    setState(() {
      _locating = true;
      _locationError = null;
    });
    try {
      final fix = await _location.currentFix();
      if (!mounted) return;
      setState(() {
        _fix = fix;
        _address = null;
        _locating = false;
      });
      final address = await _location.addressFor(fix.latitude, fix.longitude);
      if (mounted && identical(_fix, fix)) setState(() => _address = address);
    } on LocationException catch (e) {
      if (!mounted) return;
      setState(() {
        _locationError = e;
        _locating = false;
      });
    }
  }

  // ---------------------------------------------------------------------------
  // Submit
  // ---------------------------------------------------------------------------

  bool get _ready => _photo != null && _fix != null && !_submitting;

  Future<void> _submit() async {
    final photo = _photo;
    final fix = _fix;
    if (photo == null || fix == null) return;
    setState(() {
      _submitting = true;
      _submitError = null;
    });
    final draft = ClockDraft(
      type: widget.type,
      photo: photo,
      photoSha256: _photoHash!,
      latitude: fix.latitude,
      longitude: fix.longitude,
      accuracyM: fix.accuracyM,
      isMocked: fix.isMocked,
      deviceTime: _photoTime ?? DateTime.now(),
      platform: kIsWeb ? 'web' : defaultTargetPlatform.name,
      address: _address,
      notes: _notes.text.trim().isEmpty ? null : _notes.text.trim(),
    );
    final result = await context.read<AttendanceController>().submit(draft);
    if (!mounted) return;
    if (result.outcome == SubmitOutcome.failed) {
      setState(() {
        _submitting = false;
        _submitError = result.message;
      });
      return;
    }
    Navigator.of(context).pop(result);
  }

  // ---------------------------------------------------------------------------
  // UI
  // ---------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = typeColor(widget.type);
    return Scaffold(
      appBar: AppBar(title: Text(widget.type.label)),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 560),
            child: ListView(
              padding: const EdgeInsets.fromLTRB(20, 4, 20, 24),
              children: [
                _StepTitle(number: 1, title: 'Take a selfie', done: _photo != null),
                const SizedBox(height: 10),
                _buildCamera(context),
                const SizedBox(height: 24),
                _StepTitle(number: 2, title: 'Confirm your location', done: _fix != null),
                const SizedBox(height: 10),
                _buildLocation(context),
                const SizedBox(height: 24),
                _StepTitle(number: 3, title: 'Add a note (optional)', done: false, optional: true),
                const SizedBox(height: 10),
                TextField(
                  controller: _notes,
                  maxLength: 300,
                  maxLines: 2,
                  textCapitalization: TextCapitalization.sentences,
                  decoration: const InputDecoration(
                    hintText: 'e.g. Visiting client in Katutura',
                    border: OutlineInputBorder(),
                  ),
                ),
                if (_submitError != null) ...[
                  const SizedBox(height: 8),
                  InfoBanner(icon: Icons.error_outline, message: _submitError!, color: theme.colorScheme.error),
                ],
                const SizedBox(height: 8),
                FilledButton.icon(
                  onPressed: _ready ? _submit : null,
                  style: FilledButton.styleFrom(
                    backgroundColor: color,
                    foregroundColor: Colors.white,
                    minimumSize: const Size.fromHeight(56),
                    textStyle: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700),
                  ),
                  icon: _submitting
                      ? const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(strokeWidth: 2.5, color: Colors.white))
                      : Icon(typeIcon(widget.type)),
                  label: Text(_submitting ? 'Recording…' : '${widget.type.label} now'),
                ),
                const SizedBox(height: 8),
                Text(
                  'The official time is set by the server when you submit.',
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildCamera(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    const height = 360.0;
    final photo = _photo;
    final camera = _camera;

    Widget frame(Widget child) => ClipRRect(
          borderRadius: BorderRadius.circular(20),
          child: Container(color: Colors.black, height: height, width: double.infinity, child: child),
        );

    if (photo != null) {
      return Column(
        children: [
          frame(Image.memory(photo, fit: BoxFit.cover, width: double.infinity, height: height)),
          const SizedBox(height: 8),
          Row(
            children: [
              const Icon(Icons.check_circle, color: clockInColor, size: 18),
              const SizedBox(width: 6),
              Expanded(
                child: Text('Photo taken at ${formatTimeSeconds(_photoTime!)}',
                    style: Theme.of(context).textTheme.bodySmall),
              ),
              TextButton.icon(
                onPressed: _submitting ? null : _retake,
                icon: const Icon(Icons.refresh),
                label: const Text('Retake'),
              ),
            ],
          ),
        ],
      );
    }

    if (_cameraError != null) {
      return Panel(
        child: Column(
          children: [
            Icon(Icons.no_photography_outlined, size: 40, color: scheme.error),
            const SizedBox(height: 8),
            Text(_cameraError!, textAlign: TextAlign.center),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              onPressed: _startCamera,
              icon: const Icon(Icons.refresh),
              label: const Text('Try again'),
            ),
          ],
        ),
      );
    }

    if (_cameraLoading || camera == null || !camera.value.isInitialized) {
      return frame(const Center(child: CircularProgressIndicator(color: Colors.white)));
    }

    return Column(
      children: [
        frame(Stack(
          fit: StackFit.expand,
          children: [
            Center(child: CameraPreview(camera)),
            IgnorePointer(
              child: Center(
                child: Container(
                  width: 200,
                  height: 250,
                  decoration: BoxDecoration(
                    border: Border.all(color: Colors.white70, width: 2),
                    borderRadius: const BorderRadius.all(Radius.elliptical(100, 125)),
                  ),
                ),
              ),
            ),
          ],
        )),
        const SizedBox(height: 12),
        FilledButton.tonalIcon(
          onPressed: _taking ? null : _takePhoto,
          icon: _taking
              ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
              : const Icon(Icons.camera_alt_rounded),
          label: const Text('Take photo'),
          style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(48)),
        ),
        const SizedBox(height: 4),
        Text('Make sure your face is clearly visible.',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant)),
      ],
    );
  }

  Widget _buildLocation(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    if (_locating) {
      return const Panel(
        child: Row(
          children: [
            SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2.5)),
            SizedBox(width: 14),
            Expanded(child: Text('Getting an accurate GPS fix…')),
          ],
        ),
      );
    }

    final error = _locationError;
    if (error != null) {
      return Panel(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.location_off_outlined, color: scheme.error),
                const SizedBox(width: 10),
                Expanded(child: Text(error.message)),
              ],
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              children: [
                OutlinedButton.icon(
                  onPressed: _locate,
                  icon: const Icon(Icons.my_location),
                  label: const Text('Try again'),
                ),
                if (error.fix != LocationFixAction.none)
                  TextButton(
                    onPressed: () => _location.openSettings(error.fix),
                    child: const Text('Open settings'),
                  ),
              ],
            ),
          ],
        ),
      );
    }

    final fix = _fix;
    if (fix == null) return const SizedBox.shrink();

    // Nearest work site, for a preview. The server makes the final decision.
    final sites = context.watch<AttendanceController>().sites.where((s) => s.active).toList();
    WorkSite? nearest;
    double? nearestDistance;
    for (final s in sites) {
      final d = distanceMeters(fix.latitude, fix.longitude, s.latitude, s.longitude);
      if (nearestDistance == null || d < nearestDistance) {
        nearest = s;
        nearestDistance = d;
      }
    }
    final onSite = nearest != null &&
        nearestDistance! <= nearest.radiusM + (fix.accuracyM < 100 ? fix.accuracyM : 100);
    final poorAccuracy = fix.accuracyM > AppConfig.goodAccuracyMeters;

    return Panel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.location_on, color: clockInColor),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  _address ?? formatCoords(fix.latitude, fix.longitude),
                  style: theme.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600),
                ),
              ),
              IconButton(
                tooltip: 'Refresh location',
                onPressed: _locate,
                icon: const Icon(Icons.refresh),
              ),
            ],
          ),
          Text(
            '${formatCoords(fix.latitude, fix.longitude)} · accurate to ±${fix.accuracyM.round()} m',
            style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
          ),
          if (nearest != null) ...[
            const SizedBox(height: 8),
            Row(
              children: [
                Icon(onSite ? Icons.verified_outlined : Icons.near_me_outlined,
                    size: 18, color: onSite ? clockInColor : const Color(0xFFD97706)),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    onSite
                        ? 'At ${nearest.name}'
                        : '${formatDistance(nearestDistance!)} from ${nearest.name}',
                    style: theme.textTheme.bodySmall,
                  ),
                ),
              ],
            ),
          ],
          if (fix.isMocked) ...[
            const SizedBox(height: 8),
            InfoBanner(
              icon: Icons.gpp_maybe_outlined,
              message: 'A fake-GPS app was detected. This record will be flagged for your manager.',
              color: scheme.error,
            ),
          ] else if (poorAccuracy) ...[
            const SizedBox(height: 8),
            const InfoBanner(
              icon: Icons.gps_not_fixed,
              message: 'GPS accuracy is low. Move outside or near a window and tap refresh.',
              color: Color(0xFFD97706),
            ),
          ],
          const SizedBox(height: 4),
          TextButton.icon(
            onPressed: () => openMap(context, fix.latitude, fix.longitude),
            icon: const Icon(Icons.map_outlined, size: 18),
            label: const Text('View on map'),
          ),
        ],
      ),
    );
  }
}

class _StepTitle extends StatelessWidget {
  const _StepTitle({required this.number, required this.title, required this.done, this.optional = false});

  final int number;
  final String title;
  final bool done;
  final bool optional;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Row(
      children: [
        CircleAvatar(
          radius: 13,
          backgroundColor: done ? clockInColor : (optional ? scheme.surfaceContainerHighest : scheme.primary),
          child: done
              ? const Icon(Icons.check, size: 16, color: Colors.white)
              : Text('$number',
                  style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                      color: optional ? scheme.onSurfaceVariant : scheme.onPrimary)),
        ),
        const SizedBox(width: 10),
        Text(title, style: Theme.of(context).textTheme.titleMedium),
      ],
    );
  }
}
