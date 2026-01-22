import 'dart:convert';
import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';

class CameraService {
  CameraController? _controller;
  List<CameraDescription> _cameras = [];
  bool _isInitialized = false;
  String? _error;

  CameraController? get controller => _controller;
  bool get isInitialized => _isInitialized;
  String? get error => _error;

  Future<void> initializeCamera() async {
    try {
      _cameras = await availableCameras();
      if (_cameras.isEmpty) {
        _error = 'No cameras available';
        return;
      }

      // Use front camera if available, otherwise use first camera
      final frontCamera = _cameras.firstWhere(
        (camera) => camera.lensDirection == CameraLensDirection.front,
        orElse: () => _cameras.first,
      );

      _controller = CameraController(
        frontCamera,
        ResolutionPreset.medium,
        enableAudio: false,
      );

      await _controller!.initialize();
      _isInitialized = true;
      _error = null;
    } catch (e) {
      if (e.toString().contains('MissingPluginException')) {
        _error = 'Camera plugin not found for this platform. If you are on Windows, try running on Chrome/Web for best results.';
      } else if (e.toString().contains('CameraAccessDenied')) {
        _error = 'Camera access denied. Please check your browser/system permissions and refresh.';
      } else {
        _error = 'Unable to access camera. Please ensure a camera is connected and permissions are granted.';
      }
      debugPrint('Camera error: $e');
    }
  }

  Future<String?> capturePhoto() async {
    if (_controller == null || !_controller!.value.isInitialized) {
      return null;
    }

    try {
      final XFile file = await _controller!.takePicture();
      final bytes = await file.readAsBytes();
      final base64Image = 'data:image/jpeg;base64,${base64Encode(bytes)}';
      return base64Image;
    } catch (e) {
      debugPrint('Error capturing photo: $e');
      return null;
    }
  }

  void dispose() {
    _controller?.dispose();
    _controller = null;
    _isInitialized = false;
  }
}
