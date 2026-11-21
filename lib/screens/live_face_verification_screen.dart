import 'dart:io';
import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:iconsax/iconsax.dart';
import 'package:image_picker/image_picker.dart';
import '../services/aws_rekognition_service.dart';
import '../services/face_service.dart';
import '../services/face_verification_config.dart';

class LiveVerificationResult {
  final bool verified;
  final File? selfieFile;

  /// Upright, resized copy of the selfie (better for face matching).
  final File? processedSelfieFile;
  final List<double>? embedding;
  final double similarityScore;
  final String message;

  LiveVerificationResult({
    required this.verified,
    this.selfieFile,
    this.processedSelfieFile,
    this.embedding,
    this.similarityScore = 0.0,
    required this.message,
  });
}

class LiveFaceVerificationScreen extends StatefulWidget {
  final String title;
  final String subtitle;
  final List<double>? referenceEmbedding; // If provided, matches against this (local fallback)
  final File? referenceImageFile; // If provided, matches against this using AWS Rekognition
  final File? fullCnicImageFile; // Full CNIC image for dual-pass AWS comparison
  final double awsMatchThreshold;

  /// When true, a cloud "no match" can't be overruled by the weaker
  /// on-device score (used when verifying against the sign-up selfie).
  final bool strictCloudMatch;

  /// What the reference picture is, for messages ("your CNIC photograph").
  final String referenceLabel;

  const LiveFaceVerificationScreen({
    super.key,
    this.title = 'Live Identity Verification',
    this.subtitle = 'Take a clear selfie to verify your identity',
    this.referenceEmbedding,
    this.referenceImageFile,
    this.fullCnicImageFile,
    this.awsMatchThreshold = 65.0,
    this.strictCloudMatch = false,
    this.referenceLabel = 'the CNIC photograph',
  });

  @override
  State<LiveFaceVerificationScreen> createState() =>
      _LiveFaceVerificationScreenState();
}

enum _VerifyPhase { preview, checking, review, verifying, success }

/// Manual capture flow:
///   1. The user lines their face up in the oval (live preview only, nothing
///      is captured automatically).
///   2. The user taps Capture. The photo is checked once for face quality.
///   3. The user reviews the photo and taps Verify, or Retake.
/// A failed check never restarts on its own; the user decides when to retry.
class _LiveFaceVerificationScreenState extends State<LiveFaceVerificationScreen>
    with WidgetsBindingObserver {
  CameraController? _cameraController;
  bool _isCameraInitialized = false;
  bool _isInitializingCamera = false;
  bool _usedSystemCamera = false;

  _VerifyPhase _phase = _VerifyPhase.preview;
  String _instructionText = 'Place your face inside the oval, then tap Capture';
  String? _statusError;

  File? _capturedFile;
  FaceProcessingResult? _selfieResult;

  bool get _busy =>
      _phase == _VerifyPhase.checking ||
      _phase == _VerifyPhase.verifying ||
      _phase == _VerifyPhase.success;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _initCamera();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Release the camera in the background and reopen it on return.
    if (state == AppLifecycleState.paused) {
      final controller = _cameraController;
      _cameraController = null;
      if (mounted) setState(() => _isCameraInitialized = false);
      controller?.dispose();
    } else if (state == AppLifecycleState.resumed &&
        _cameraController == null &&
        !_usedSystemCamera) {
      _initCamera();
    }
  }

  Future<void> _initCamera() async {
    if (_isInitializingCamera) return;
    _isInitializingCamera = true;
    try {
      final cameras = await availableCameras();
      final frontCamera = cameras.firstWhere(
        (c) => c.lensDirection == CameraLensDirection.front,
        orElse: () => cameras.first,
      );

      final controller = CameraController(
        frontCamera,
        ResolutionPreset.high,
        enableAudio: false,
        imageFormatGroup: ImageFormatGroup.jpeg,
      );

      await controller.initialize();
      try {
        await controller.setFlashMode(FlashMode.off);
      } catch (_) {
        // Front cameras without a flash throw here; safe to ignore.
      }
      if (!mounted) {
        await controller.dispose();
        return;
      }

      setState(() {
        _cameraController = controller;
        _isCameraInitialized = true;
      });
    } catch (e) {
      if (mounted) {
        setState(() {
          _isCameraInitialized = false;
          _statusError =
              'Camera preview unavailable. Use the button below to take a selfie.';
        });
      }
    } finally {
      _isInitializingCamera = false;
    }
  }

  /// Takes ONE photo when the user taps Capture and checks its quality.
  Future<void> _capture() async {
    final controller = _cameraController;
    if (_busy || controller == null || !controller.value.isInitialized) return;
    if (controller.value.isTakingPicture) return;

    setState(() {
      _phase = _VerifyPhase.checking;
      _instructionText = 'Checking photo...';
      _statusError = null;
    });

    try {
      final XFile pic = await controller.takePicture();
      _usedSystemCamera = false;
      await _checkCapturedPhoto(File(pic.path));
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _phase = _VerifyPhase.preview;
        _instructionText = 'Place your face inside the oval, then tap Capture';
        _statusError = 'Could not take the photo. Please try again.';
      });
    }
  }

  /// Fallback when the in-app preview is unavailable: system camera.
  Future<void> _captureWithSystemCamera() async {
    if (_busy) return;
    try {
      final XFile? image = await ImagePicker().pickImage(
        source: ImageSource.camera,
        preferredCameraDevice: CameraDevice.front,
        maxWidth: 1280,
        maxHeight: 1280,
        imageQuality: 92,
      );
      if (image == null || !mounted) return;
      _usedSystemCamera = true;
      setState(() {
        _phase = _VerifyPhase.checking;
        _instructionText = 'Checking photo...';
        _statusError = null;
      });
      await _checkCapturedPhoto(File(image.path));
    } catch (e) {
      if (mounted) setState(() => _statusError = 'Capture error: $e');
    }
  }

  Future<void> _checkCapturedPhoto(File file) async {
    final result = await FaceService.processSelfie(file);
    if (!mounted) return;

    if (!result.success || result.embedding == null) {
      setState(() {
        _capturedFile = file;
        _selfieResult = null;
        _phase = _VerifyPhase.review;
        _instructionText = 'This photo cannot be used';
        _statusError = result.message;
      });
      return;
    }

    setState(() {
      _capturedFile = file;
      _selfieResult = result;
      _phase = _VerifyPhase.review;
      _instructionText = 'Photo looks good. Tap Verify, or retake it';
      _statusError = null;
    });
  }

  void _retake() {
    if (_busy) return;
    final old = _capturedFile;
    setState(() {
      _capturedFile = null;
      _selfieResult = null;
      _phase = _VerifyPhase.preview;
      _instructionText = 'Place your face inside the oval, then tap Capture';
      _statusError = null;
    });
    if (old != null) {
      old.delete().catchError((_) => old);
    }
    if (!_isCameraInitialized && _usedSystemCamera) {
      _captureWithSystemCamera();
    }
  }

  void _verificationFailed(String title, String reason) {
    if (!mounted) return;
    setState(() {
      // Stay on the review step: the user chooses to retake. No auto-retry.
      _selfieResult = null;
      _phase = _VerifyPhase.review;
      _instructionText = title;
      _statusError = reason;
    });
  }

  Future<void> _verificationSucceeded({
    required String banner,
    required double similarityScore,
    required String message,
  }) async {
    if (!mounted) return;
    setState(() {
      _phase = _VerifyPhase.success;
      _instructionText = banner;
      _statusError = null;
    });
    await Future.delayed(const Duration(milliseconds: 800));
    if (!mounted) return;
    Navigator.pop(
      context,
      LiveVerificationResult(
        verified: true,
        selfieFile: _capturedFile,
        processedSelfieFile: _selfieResult?.processedImageFile,
        embedding: _selfieResult?.embedding,
        similarityScore: similarityScore,
        message: message,
      ),
    );
  }

  /// Runs the identity check on the photo the user approved.
  Future<void> _verify() async {
    final selfieFile = _capturedFile;
    final selfieResult = _selfieResult;
    if (_busy || selfieFile == null || selfieResult?.embedding == null) return;

    setState(() {
      _phase = _VerifyPhase.verifying;
      _instructionText = 'Verifying identity...';
      _statusError = null;
    });

    try {
      // Collect reference candidates (cropped high-res portrait + full CNIC document)
      final List<File> referenceCandidates = [];
      if (widget.referenceImageFile != null) {
        referenceCandidates.add(widget.referenceImageFile!);
      }
      if (widget.fullCnicImageFile != null &&
          widget.fullCnicImageFile?.path != widget.referenceImageFile?.path) {
        referenceCandidates.add(widget.fullCnicImageFile!);
      }

      // Compute on-device score if embedding is available
      double localScore = 0.0;
      if (widget.referenceEmbedding != null) {
        localScore = FaceService.compareEmbeddings(
          widget.referenceEmbedding!,
          selfieResult!.embedding!,
        );
      }

      // Priority 1: Cloud AI Verification with AWS Rekognition (Multi-candidate comparison)
      if (referenceCandidates.isNotEmpty) {
        final awsResult = await AwsRekognitionService().compareWithBestReference(
          referenceFiles: referenceCandidates,
          // Upright copy the face was found in (no EXIF rotation surprises).
          targetFile: selfieResult!.processedImageFile ?? selfieFile,
          similarityThreshold: widget.awsMatchThreshold,
        );

        debugPrint(
          '[LiveFace] AWS Result: success=${awsResult.success}, match=${awsResult.isMatch}, '
          'sim=${awsResult.similarity.toStringAsFixed(1)}%, localScore=${(localScore * 100).toStringAsFixed(1)}%',
        );

        if (awsResult.success) {
          // Confirmed identity:
          // 1. AWS Rekognition similarity >= threshold (65%), OR
          // 2. AWS shows strong correlation (>= 55%) AND on-device features agree (>= 0.50), OR
          // 3. On-device biometrics independently verifies (>= 0.65)
          final bool isConfirmed = widget.strictCloudMatch
              ? awsResult.isMatch
              : awsResult.isMatch ||
                    (awsResult.similarity >= 55.0 && localScore >= 0.50) ||
                    (localScore >= FaceVerificationConfig.matchThreshold);

          if (isConfirmed) {
            final effectiveSim = awsResult.similarity > 0
                ? awsResult.similarity
                : (localScore * 100.0);
            await _verificationSucceeded(
              banner:
                  'Identity verified successfully! ✅ (${effectiveSim.toStringAsFixed(1)}% match)',
              similarityScore: effectiveSim / 100.0,
              message:
                  'AWS Rekognition verified identity (${effectiveSim.toStringAsFixed(1)}% match).',
            );
          } else {
            _verificationFailed(
              'Face does not match ❌',
              'Selfie does not match ${widget.referenceLabel} (${awsResult.similarity.toStringAsFixed(1)}% similarity). Retake the photo in good lighting, looking straight at the camera.',
            );
          }
          return;
        }

        // AWS service error or offline: fallback to on-device biometrics
        debugPrint(
          '[LiveFace] AWS Rekognition unavailable (${awsResult.errorMessage}). Falling back to on-device biometrics.',
        );
      }

      // Priority 2: On-device biometric matching fallback
      if (widget.referenceEmbedding != null) {
        // On-device fallback (AWS unreachable). The on-device features are
        // less precise than AWS, so the bar is lower here.
        final isMatch = localScore >= 0.50;

        if (isMatch) {
          await _verificationSucceeded(
            banner: 'Identity verified successfully! ✅',
            similarityScore: localScore,
            message: 'Identity verified successfully.',
          );
        } else {
          _verificationFailed(
            'Face does not match ❌',
            'Face does not match the reference document (${(localScore * 100).toStringAsFixed(0)}% match). Retake the photo in good lighting, looking straight at the camera.',
          );
        }
      } else if (referenceCandidates.isNotEmpty) {
        // A reference photo exists but the cloud check could not run and
        // there is no on-device profile to fall back on.
        _verificationFailed(
          'Could not verify right now',
          'Face check needs an internet connection. Check your connection and tap Verify again.',
        );
      } else {
        // No reference passed: registration selfie capture step
        await _verificationSucceeded(
          banner: 'Selfie captured successfully! ✅',
          similarityScore: 1.0,
          message: 'Selfie verified successfully.',
        );
      }
    } catch (e) {
      _verificationFailed('Verification error', 'Something went wrong: $e');
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _cameraController?.dispose();
    super.dispose();
  }

  int get _stepIndex {
    switch (_phase) {
      case _VerifyPhase.preview:
      case _VerifyPhase.checking:
        return 0;
      case _VerifyPhase.review:
        return 1;
      case _VerifyPhase.verifying:
        return 2;
      case _VerifyPhase.success:
        return 3;
    }
  }

  Color get _ovalColor {
    if (_phase == _VerifyPhase.success) return Colors.greenAccent;
    if (_statusError != null && _phase == _VerifyPhase.review) {
      return Colors.redAccent;
    }
    if (_phase == _VerifyPhase.review) return Colors.greenAccent;
    if (_busy) return Colors.amberAccent;
    return Colors.blueAccent;
  }

  @override
  Widget build(BuildContext context) {
    const primaryColor = Color(0xFF1D4ED8);
    final bool canVerify =
        _phase == _VerifyPhase.review && _selfieResult?.embedding != null;

    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        iconTheme: const IconThemeData(color: Colors.white),
        title: Text(
          widget.title,
          style: const TextStyle(color: Colors.white, fontSize: 18),
        ),
        elevation: 0,
      ),
      body: SafeArea(
        child: Column(
          children: [
            // Header instruction banner
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
              color: Colors.grey.shade900,
              child: Row(
                children: [
                  Icon(
                    _phase == _VerifyPhase.success
                        ? Iconsax.verify
                        : _phase == _VerifyPhase.review
                            ? Iconsax.gallery
                            : Iconsax.user,
                    color: Colors.blueAccent,
                    size: 26,
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Text(
                      _instructionText,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ],
              ),
            ),

            // Step Progress Indicator
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
              child: Row(
                children: [
                  _buildStepIndicator(0, 'Capture'),
                  _buildStepDivider(0),
                  _buildStepIndicator(1, 'Review'),
                  _buildStepDivider(1),
                  _buildStepIndicator(2, 'Verify'),
                ],
              ),
            ),

            // Camera preview / captured photo inside the oval frame
            Expanded(
              child: Center(
                child: Padding(
                  padding: const EdgeInsets.all(20.0),
                  child: AspectRatio(
                    aspectRatio: 3 / 4,
                    child: Stack(
                      children: [
                        Positioned.fill(
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(150),
                            child: _buildOvalContent(),
                          ),
                        ),

                        // Oval frame
                        Positioned.fill(
                          child: IgnorePointer(
                            child: Container(
                              decoration: BoxDecoration(
                                borderRadius: BorderRadius.circular(150),
                                border: Border.all(color: _ovalColor, width: 4),
                              ),
                            ),
                          ),
                        ),

                        // Spinner while checking / verifying
                        if (_phase == _VerifyPhase.checking ||
                            _phase == _VerifyPhase.verifying)
                          Positioned.fill(
                            child: Container(
                              decoration: BoxDecoration(
                                color: Colors.black54,
                                borderRadius: BorderRadius.circular(150),
                              ),
                              child: Center(
                                child: Column(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    const CircularProgressIndicator(
                                      color: Colors.blueAccent,
                                      strokeWidth: 3,
                                    ),
                                    const SizedBox(height: 16),
                                    Text(
                                      _phase == _VerifyPhase.checking
                                          ? 'Checking photo...'
                                          : 'Verifying identity...',
                                      style: const TextStyle(
                                        color: Colors.white,
                                        fontWeight: FontWeight.bold,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              ),
            ),

            // Status error message
            if (_statusError != null)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 8),
                child: Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Colors.red.shade900.withValues(alpha: 0.5),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: Colors.redAccent.shade400),
                  ),
                  child: Row(
                    children: [
                      const Icon(Iconsax.warning_2, color: Colors.redAccent, size: 20),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          _statusError!,
                          style: const TextStyle(color: Colors.white, fontSize: 13),
                        ),
                      ),
                    ],
                  ),
                ),
              ),

            // Bottom controls
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
              color: const Color(0xFF121212),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (_phase == _VerifyPhase.review ||
                      _phase == _VerifyPhase.verifying ||
                      _phase == _VerifyPhase.success)
                    Row(
                      children: [
                        Expanded(
                          child: SizedBox(
                            height: 52,
                            child: OutlinedButton.icon(
                              key: const Key('face_retake_button'),
                              onPressed: _busy ? null : _retake,
                              icon: const Icon(Icons.refresh, color: Colors.white),
                              label: const Text(
                                'Retake',
                                style: TextStyle(color: Colors.white, fontSize: 16),
                              ),
                              style: OutlinedButton.styleFrom(
                                side: const BorderSide(color: Colors.white54),
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(16),
                                ),
                              ),
                            ),
                          ),
                        ),
                        if (canVerify || _phase != _VerifyPhase.review) ...[
                          const SizedBox(width: 12),
                          Expanded(
                            child: SizedBox(
                              height: 52,
                              child: ElevatedButton.icon(
                                key: const Key('face_verify_button'),
                                onPressed: canVerify ? _verify : null,
                                icon: const Icon(Iconsax.verify, color: Colors.white),
                                label: const Text(
                                  'Verify',
                                  style: TextStyle(color: Colors.white, fontSize: 16),
                                ),
                                style: ElevatedButton.styleFrom(
                                  backgroundColor: primaryColor,
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(16),
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ],
                      ],
                    )
                  else
                    SizedBox(
                      width: double.infinity,
                      height: 52,
                      child: ElevatedButton.icon(
                        key: const Key('face_capture_button'),
                        onPressed: _busy
                            ? null
                            : (_isCameraInitialized
                                ? _capture
                                : _captureWithSystemCamera),
                        icon: const Icon(Iconsax.camera, color: Colors.white),
                        label: Text(
                          _isCameraInitialized ? 'Capture' : 'Open Camera',
                          style: const TextStyle(color: Colors.white, fontSize: 16),
                        ),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: primaryColor,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(16),
                          ),
                        ),
                      ),
                    ),
                  const SizedBox(height: 8),
                  Text(
                    'Hold the phone at arm\'s length, use bright lighting, and look straight at the camera',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: Colors.grey.shade500, fontSize: 12),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Live preview while capturing, the taken photo while reviewing.
  Widget _buildOvalContent() {
    final captured = _capturedFile;
    if (captured != null) {
      final image = Image.file(captured, fit: BoxFit.cover);
      // The live front-camera preview is mirrored; mirror the photo too so it
      // does not appear to flip after capture.
      return _usedSystemCamera ? image : Transform.flip(flipX: true, child: image);
    }

    final controller = _cameraController;
    if (_isCameraInitialized && controller != null && controller.value.isInitialized) {
      final size = controller.value.previewSize;
      if (size == null) return CameraPreview(controller);
      // previewSize is reported in landscape; swap for portrait and fill the oval.
      return FittedBox(
        fit: BoxFit.cover,
        clipBehavior: Clip.hardEdge,
        child: SizedBox(
          width: size.height,
          height: size.width,
          child: CameraPreview(controller),
        ),
      );
    }

    return Container(
      color: Colors.grey.shade900,
      child: const Center(
        child: Icon(Iconsax.camera, color: Colors.white38, size: 72),
      ),
    );
  }

  Widget _buildStepIndicator(int stepIndex, String title) {
    final isDone = _stepIndex > stepIndex;
    final isCurrent = _stepIndex == stepIndex;

    return Row(
      children: [
        Container(
          width: 26,
          height: 26,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: isDone
                ? Colors.greenAccent
                : isCurrent
                    ? Colors.blueAccent
                    : Colors.grey.shade800,
          ),
          child: Center(
            child: isDone
                ? const Icon(Icons.check, size: 16, color: Colors.black)
                : Text(
                    '${stepIndex + 1}',
                    style: TextStyle(
                      color: isCurrent ? Colors.white : Colors.grey.shade400,
                      fontSize: 12,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
          ),
        ),
        const SizedBox(width: 6),
        Text(
          title,
          style: TextStyle(
            color: isCurrent ? Colors.white : Colors.grey.shade500,
            fontSize: 12,
            fontWeight: isCurrent ? FontWeight.bold : FontWeight.normal,
          ),
        ),
      ],
    );
  }

  Widget _buildStepDivider(int stepIndex) {
    final isDone = _stepIndex > stepIndex;
    return Expanded(
      child: Container(
        height: 2,
        margin: const EdgeInsets.symmetric(horizontal: 8),
        color: isDone ? Colors.greenAccent : Colors.grey.shade800,
      ),
    );
  }
}
