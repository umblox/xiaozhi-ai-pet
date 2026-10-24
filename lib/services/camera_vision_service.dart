import 'dart:async';
import 'dart:typed_data';
import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

class CameraVisionService {
  List<CameraDescription> _cameras = [];
  CameraController? controller;
  int _selectedCameraIdx = 0;
  bool _isBusy = false;

  bool get isInitialized =>
      controller != null && controller!.value.isInitialized;

  String get currentLensName {
    if (_cameras.isEmpty || _selectedCameraIdx >= _cameras.length) {
      return "front";
    }
    return _cameras[_selectedCameraIdx].lensDirection ==
            CameraLensDirection.front
        ? "front"
        : "back";
  }

  Future<void> initCameras({bool preferFront = true}) async {
    try {
      _cameras = await availableCameras();
      if (_cameras.isEmpty) return;

      if (preferFront) {
        final frontIdx = _cameras
            .indexWhere((c) => c.lensDirection == CameraLensDirection.front);
        _selectedCameraIdx = frontIdx != -1 ? frontIdx : 0;
      } else {
        final backIdx = _cameras
            .indexWhere((c) => c.lensDirection == CameraLensDirection.back);
        _selectedCameraIdx = backIdx != -1 ? backIdx : 0;
      }

      await _startSelectedCamera();
    } catch (_) {}
  }

  Future<void> _startSelectedCamera() async {
    if (_cameras.isEmpty) return;
    try {
      final prev = controller;
      controller = null;
      await prev?.dispose();

      final camCtrl = CameraController(
        _cameras[_selectedCameraIdx],
        ResolutionPreset.low,
        enableAudio: false,
        imageFormatGroup: ImageFormatGroup.jpeg,
      );
      await camCtrl.initialize();
      try {
        await camCtrl.setFlashMode(FlashMode.off);
      } catch (_) {}

      controller = camCtrl;
    } catch (_) {}
  }

  Future<String> switchCameraLens({String? targetDirection}) async {
    if (_cameras.isEmpty) {
      _cameras = await availableCameras();
    }
    if (_cameras.isEmpty) return "unavailable";

    if (targetDirection == "front" || targetDirection == "selfie") {
      final idx = _cameras
          .indexWhere((c) => c.lensDirection == CameraLensDirection.front);
      if (idx != -1) _selectedCameraIdx = idx;
    } else if (targetDirection == "back" || targetDirection == "rear") {
      final idx = _cameras
          .indexWhere((c) => c.lensDirection == CameraLensDirection.back);
      if (idx != -1) _selectedCameraIdx = idx;
    } else {
      _selectedCameraIdx = (_selectedCameraIdx + 1) % _cameras.length;
    }

    await _startSelectedCamera();
    return currentLensName;
  }

  Future<String> captureAndUploadVision({
    required String question,
    required String deviceMac,
    required String clientId,
    required String visionExplainUrl,
    required String visionExplainToken,
    VoidCallback? onCapturing,
  }) async {
    if (_isBusy) {
      return '{"success": false, "message": "Camera is busy"}';
    }
    _isBusy = true;

    try {
      if (!isInitialized) {
        await initCameras(preferFront: true);
      }
      if (!isInitialized) {
        _isBusy = false;
        return '{"success": false, "message": "Camera could not be initialized"}';
      }

      onCapturing?.call();

      await Future.delayed(const Duration(milliseconds: 250));
      try {
        await controller!.setFlashMode(FlashMode.off);
      } catch (_) {}

      final XFile photo = await controller!.takePicture();
      final Uint8List bytes = await photo.readAsBytes();

      final targetUrl = visionExplainUrl.isNotEmpty
          ? visionExplainUrl
          : "https://api.tenclass.net/xiaozhi/vision/explain";

      final req = http.MultipartRequest('POST', Uri.parse(targetUrl));
      req.headers['Device-Id'] = deviceMac;
      req.headers['Client-Id'] = clientId;
      req.headers['User-Agent'] = 'bread-compact-wifi/1.0.0';
      if (visionExplainToken.isNotEmpty) {
        req.headers['Authorization'] = 'Bearer $visionExplainToken';
      }
      req.fields['question'] = question;
      req.files.add(
        http.MultipartFile.fromBytes('file', bytes, filename: 'camera.jpg'),
      );

      final streamedRes =
          await req.send().timeout(const Duration(seconds: 15));
      final body = await streamedRes.stream.bytesToString();
      _isBusy = false;
      return body;
    } catch (e) {
      _isBusy = false;
      return '{"success": false, "message": "Camera error: $e"}';
    }
  }

  void dispose() {
    controller?.dispose();
  }
}
