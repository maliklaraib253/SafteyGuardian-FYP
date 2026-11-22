import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:iconsax/iconsax.dart';
import 'package:image_picker/image_picker.dart';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:path_provider/path_provider.dart';
import 'package:geolocator/geolocator.dart';

import '../services/evidence_storage.dart';
import '../services/report_analysis_service.dart';
import '../services/face_blur_service.dart';
import '../services/priority_classifier.dart';

import 'package:shared_preferences/shared_preferences.dart';

import '../services/routing_service.dart';
import '../services/auth_service.dart';
import 'live_face_verification_screen.dart';

import 'package:latlong2/latlong.dart' show LatLng;

import 'location_picker_screen.dart';

import 'package:flutter_map/flutter_map.dart';
import 'package:speech_to_text/speech_to_text.dart' as stt;

import '../services/distress_monitor.dart';
import '../theme/app_theme.dart';
import '../theme/responsive.dart';
import '../widgets/map_pin.dart';

class IncidentReportScreen extends StatefulWidget {
  const IncidentReportScreen({super.key});

  @override
  State<IncidentReportScreen> createState() => _IncidentReportScreenState();
}

class _IncidentReportScreenState extends State<IncidentReportScreen> {
  // Controllers
  final TextEditingController _titleController = TextEditingController();
  final TextEditingController _descriptionController = TextEditingController();
  final TextEditingController _locationController = TextEditingController();

  // Selected values
  String? _selectedCategory;
  DateTime? _selectedDate;
  TimeOfDay? _selectedTime;
  final List<XFile> _selectedImages = [];
  // Videos, e.g. recorded with Evidence Capture (saved in the gallery).
  final List<XFile> _selectedVideos = [];
  static const int _maxVideos = 3;
  bool _videoWarningAccepted = false;
  bool _isAnonymous = false;
  // Blur the reporter's OWN face in evidence photos (other people stay
  // visible as evidence). On by default, forced on for anonymous reports.
  bool _blurMyFaceEnabled = true;
  bool get _shouldBlur => _blurMyFaceEnabled || _isAnonymous;
  bool _isLoading = false;
  String _loadingMessage = 'Submitting report...';
  // Map-picked coordinates (overrides current GPS if user explicitly picked).
  double? _pickedLatitude;
  double? _pickedLongitude;

  // Categories for dropdown - FIXED ICONS (removed 'skull')
  final List<Map<String, dynamic>> _categories = [
    {'name': 'Murder', 'icon': Iconsax.danger, 'color': Colors.red},
    {'name': 'Snatching', 'icon': Iconsax.money, 'color': Colors.orange},
    {'name': 'Harassment', 'icon': Iconsax.warning_2, 'color': Colors.purple},
    {'name': 'Corruption', 'icon': Iconsax.money_tick, 'color': Colors.brown},
    {'name': 'Robbery', 'icon': Iconsax.lock, 'color': Colors.deepOrange},
    {'name': 'Theft', 'icon': Iconsax.box_remove, 'color': Colors.blueGrey},
    {'name': 'Assault', 'icon': Iconsax.man, 'color': Colors.redAccent},
    {'name': 'Fraud', 'icon': Iconsax.security_card, 'color': Colors.teal},
    {'name': 'Traffic Violation', 'icon': Iconsax.car, 'color': Colors.indigo},
    {'name': 'Other', 'icon': Iconsax.more, 'color': Colors.grey},
  ];

  // Image picker
  final ImagePicker _picker = ImagePicker();

  @override
  void initState() {
    super.initState();
    _applyWhen('now');
    WidgetsBinding.instance.addPostFrameCallback((_) => _restoreDraft());
    SharedPreferences.getInstance().then((prefs) {
      if (!mounted) return;
      setState(() {
        _blurMyFaceEnabled = prefs.getBool('blur_faces_default') ?? true;
      });
    });
  }

  /// True for empty text or a placeholder shown while an address loads.
  static bool _isPlaceholderAddress(String a) {
    final t = a.trim().toLowerCase();
    return t.isEmpty ||
        t.startsWith('loading') ||
        t.startsWith('resolving') ||
        t.startsWith('location (');
  }

  /// The address saved with the report: what the user typed or picked, or a
  /// freshly resolved street address, or at least the coordinates. Never a
  /// "Loading address..." placeholder.
  Future<String> _finalAddress(double lat, double lng) async {
    final typed = _locationController.text.trim();
    if (!_isPlaceholderAddress(typed)) return typed;
    try {
      final resolved = await RoutingService.reverseGeocode(LatLng(lat, lng))
          .timeout(const Duration(seconds: 8));
      if (!_isPlaceholderAddress(resolved)) return resolved;
    } catch (_) {}
    return '${lat.toStringAsFixed(5)}, ${lng.toStringAsFixed(5)}';
  }

  /// Downloads the CNIC photo saved at registration (users/{uid}.cnicPhotoUrl)
  /// so it can be used, with the selfie, to recognise the reporter's face.
  Future<File?> _downloadCnicPhoto(String uid) async {
    try {
      final doc = await FirebaseFirestore.instance
          .collection('users')
          .doc(uid)
          .get();
      final url = (doc.data()?['cnicPhotoUrl'] ?? '').toString();
      if (url.isEmpty) return null;
      final bytes = await FirebaseStorage.instance
          .refFromURL(url)
          .getData(15 * 1024 * 1024);
      if (bytes == null || bytes.isEmpty) return null;
      final dir = await getTemporaryDirectory();
      final file = File(
        '${dir.path}/cnic_reference_${DateTime.now().millisecondsSinceEpoch}.jpg',
      );
      await file.writeAsBytes(bytes, flush: true);
      return file;
    } catch (e) {
      debugPrint('[OwnerBlur] CNIC photo download failed: $e');
      return null;
    }
  }

  /// Shows the photos exactly as they will be uploaded and asks to confirm.
  Future<bool> _confirmUploadPreview(List<OwnerBlurResult> results) async {
    final blurred = results.where((r) => r.ownerBlurred).length;
    final unchecked = results.where((r) => !r.checked).length;
    // Why the online check failed (same reason for every photo, usually).
    String? checkError;
    for (final r in results) {
      if (!r.checked && r.detail.isNotEmpty) {
        checkError = r.detail;
        break;
      }
    }
    final ok = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: const Text('Photos to upload'),
        content: SizedBox(
          width: double.maxFinite,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                blurred == 0
                    ? 'Your face was not found in these photos, so they are uploaded as they are.'
                    : 'Your face was blurred in $blurred of ${results.length} photo${results.length == 1 ? '' : 's'}. Other people are not blurred.',
                style: const TextStyle(fontSize: 13),
              ),
              if (unchecked > 0) ...[
                const SizedBox(height: 6),
                Text(
                  '$unchecked photo${unchecked == 1 ? '' : 's'} could not be checked online, so ${unchecked == 1 ? 'it' : 'they'} will be uploaded unchanged.',
                  style: TextStyle(fontSize: 12, color: Colors.orange.shade800),
                ),
                if (checkError != null) ...[
                  const SizedBox(height: 4),
                  Text(
                    'Reason: $checkError',
                    style: TextStyle(fontSize: 11, color: Colors.grey.shade700),
                  ),
                ],
              ],
              const SizedBox(height: 12),
              SizedBox(
                height: 186,
                child: ListView.separated(
                  scrollDirection: Axis.horizontal,
                  itemCount: results.length,
                  separatorBuilder: (_, _) => const SizedBox(width: 8),
                  itemBuilder: (_, i) => SizedBox(
                    width: 120,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Stack(
                          children: [
                            ClipRRect(
                              borderRadius: BorderRadius.circular(10),
                              child: SizedBox(
                                width: 120,
                                height: 120,
                                child: _imagePreview(results[i].file),
                              ),
                            ),
                            if (results[i].ownerBlurred)
                              Positioned(
                                left: 4,
                                right: 4,
                                bottom: 4,
                                child: Container(
                                  padding: const EdgeInsets.symmetric(
                                    vertical: 2,
                                  ),
                                  decoration: BoxDecoration(
                                    color: Colors.black.withValues(alpha: 0.6),
                                    borderRadius: BorderRadius.circular(6),
                                  ),
                                  child: const Text(
                                    'Your face blurred',
                                    textAlign: TextAlign.center,
                                    style: TextStyle(
                                      color: Colors.white,
                                      fontSize: 10,
                                    ),
                                  ),
                                ),
                              ),
                          ],
                        ),
                        const SizedBox(height: 4),
                        Text(
                          results[i].detail,
                          maxLines: 3,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 10,
                            color: Colors.grey.shade700,
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
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            key: const Key('confirm_upload_button'),
            onPressed: () => Navigator.pop(context, true),
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF1D4ED8),
              foregroundColor: Colors.white,
            ),
            child: const Text('Upload & Submit'),
          ),
        ],
      ),
    );
    return ok == true;
  }

  @override
  void dispose() {
    _dictationWatch?.cancel();
    if (_dictating) _dictation.stop();
    if (_resumeDistressVoice) {
      DistressMonitor.instance.voice.startMonitoring();
    }
    _titleController.dispose();
    _descriptionController.dispose();
    _locationController.dispose();
    super.dispose();
  }

  // Pick date
  Future<void> _pickDate() async {
    DateTime? picked = await showDatePicker(
      context: context,
      initialDate: DateTime.now(),
      firstDate: DateTime(2020),
      lastDate: DateTime.now(),
      builder: (context, child) {
        return Theme(
          data: ThemeData.light().copyWith(
            colorScheme: const ColorScheme.light(
              primary: Color(0xFF1D4ED8),
              onPrimary: Colors.white,
              surface: Colors.white,
              onSurface: Colors.black,
            ),
          ),
          child: child!,
        );
      },
    );

    if (picked != null) {
      setState(() {
        _selectedDate = picked;
      });
    }
  }

  // Pick time
  Future<void> _pickTime() async {
    TimeOfDay? picked = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.now(),
      builder: (context, child) {
        return Theme(
          data: ThemeData.light().copyWith(
            colorScheme: const ColorScheme.light(
              primary: Color(0xFF1D4ED8),
              onPrimary: Colors.white,
              surface: Colors.white,
              onSurface: Colors.black,
            ),
          ),
          child: child!,
        );
      },
    );

    if (picked != null) {
      setState(() {
        _selectedTime = picked;
      });
    }
  }

  // Pick images from gallery
  Future<void> _pickImages() async {
    try {
      final List<XFile> images = await _picker.pickMultiImage(
        maxWidth: 1024,
        maxHeight: 1024,
        imageQuality: 80,
      );

      if (!mounted) return;
      setState(() {
        _selectedImages.addAll(images);
      });
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Error picking images: $e'),
          backgroundColor: Colors.red,
        ),
      );
    }
  }

  // Take photo with camera
  Future<void> _takePhoto() async {
    try {
      final XFile? image = await _picker.pickImage(
        source: ImageSource.camera,
        maxWidth: 1024,
        maxHeight: 1024,
        imageQuality: 80,
      );

      if (image != null && mounted) {
        setState(() {
          _selectedImages.add(image);
        });
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Error taking photo: $e'),
          backgroundColor: Colors.red,
        ),
      );
    }
  }

  // Remove image from list
  void _removeImage(int index) {
    setState(() {
      _selectedImages.removeAt(index);
    });
  }

  Widget _imagePreview(XFile xfile) {
    if (kIsWeb) {
      return Image.network(xfile.path, fit: BoxFit.cover);
    }
    return Image.file(File(xfile.path), fit: BoxFit.cover);
  }

  // Submit report with required biometric identity verification
  void _submitReport() async {
    if (!_validateAll()) return;

    if (_selectedCategory == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Please select a category'),
          backgroundColor: Colors.orange,
        ),
      );
      return;
    }

    final user = FirebaseAuth.instance.currentUser;
    if (user == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Please login to submit a report'),
          backgroundColor: Colors.red,
        ),
      );
      return;
    }

    // Step 1: Prompt user for mandatory identity verification
    final bool? proceed = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: const Row(
          children: [
            Icon(Iconsax.shield_security, color: Color(0xFF1D4ED8), size: 28),
            SizedBox(width: 10),
            Expanded(
              child: Text(
                'Identity Verification Required',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
              ),
            ),
          ],
        ),
        content: const Text(
          'Before submitting this report to law enforcement, SafetyGuardian requires biometric face verification to confirm the reporter\'s identity and reduce fraudulent complaints.\n\nYou will now take a selfie to verify.',
          style: TextStyle(fontSize: 14, height: 1.4),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(context, true),
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF1D4ED8),
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
            ),
            child: const Text('Verify Identity'),
          ),
        ],
      ),
    );

    if (proceed != true) return;

    setState(() {
      _isLoading = true;
      _loadingMessage = 'Preparing identity check...';
    });

    // Step 2: Fetch the registered references: face embedding + CNIC photo.
    final authService = AuthService();
    final List<double>? refEmbedding = await authService
        .getUserIdentityEmbedding(user.uid);
    final File? cnicFile = await _downloadCnicPhoto(user.uid);
    // Small copies of the CNIC face and selfie taken at sign-up.
    final refs = await authService.getReferenceFaceFiles(user.uid);
    final File? signupSelfie = refs.selfie;
    final File? signupCnicFace = refs.cnicFace ?? cnicFile;

    if (!mounted) return;
    setState(() {
      _isLoading = false;
      _loadingMessage = 'Submitting report...';
    });

    if ((refEmbedding == null || refEmbedding.isEmpty) &&
        signupCnicFace == null) {
      if (!mounted) return;
      showDialog(
        context: context,
        builder: (context) => AlertDialog(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(20),
          ),
          title: const Text('Identity Profile Incomplete'),
          content: const Text(
            'Your account does not have a registered CNIC reference face. Please complete CNIC identity registration in your profile before submitting incident reports.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('OK'),
            ),
          ],
        ),
      );
      return;
    }

    // Step 3: Open front camera for liveness check and face matching
    final LiveVerificationResult?
    verificationResult = await Navigator.push<LiveVerificationResult>(
      context,
      MaterialPageRoute(
        builder: (context) => LiveFaceVerificationScreen(
          title: 'Report Identity Verification',
          subtitle:
              'Verify live identity against your registered biometric profile',
          referenceEmbedding: (refEmbedding == null || refEmbedding.isEmpty)
              ? null
              : refEmbedding,
          // The new selfie must match the face on the user's CNIC (cloud
          // AWS match): the face cut from the CNIC at sign-up, plus the full
          // CNIC picture when it is available.
          referenceImageFile: signupCnicFace,
          fullCnicImageFile: (cnicFile != null && cnicFile != signupCnicFace)
              ? cnicFile
              : null,
          strictCloudMatch: signupCnicFace != null,
          referenceLabel: 'the photo on your CNIC',
        ),
      ),
    );

    // Step 4: Validate verification outcome
    if (verificationResult == null ||
        !verificationResult.verified ||
        verificationResult.embedding == null) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            verificationResult?.message ??
                'Face Verification Failed. Submission was cancelled.',
          ),
          backgroundColor: Colors.red,
          duration: const Duration(seconds: 4),
        ),
      );
      return; // Report must NOT be written to Firestore!
    }

    // The verification screen already matched the selfie against the CNIC
    // photo (AWS) or the registered face profile (on-device), so its verdict
    // is final. A second, stricter on-device check here used to reject
    // genuine users ("Biometric mismatch 57%").

    // Older accounts: keep this verified selfie as their reference face.
    if (signupSelfie == null) {
      await authService.saveReferenceSelfieIfMissing(
        user.uid,
        verificationResult.processedSelfieFile ?? verificationResult.selfieFile,
      );
    }

    // Step 5: Blur ONLY the reporter's own face in the evidence photos, using
    // the selfie they just verified with. Everyone else stays visible.
    List<XFile> filesToUpload = List<XFile>.from(_selectedImages);
    int ownerBlurredCount = 0;
    if (_shouldBlur && _selectedImages.isNotEmpty) {
      setState(() {
        _isLoading = true;
        _loadingMessage = 'Finding your face in photos...';
      });
      // Pictures of the reporter only: the selfie just verified against
      // their CNIC, the CNIC face and the sign-up selfie. Only faces matching
      // these are blurred; everyone else stays visible.
      final references = <File>[
        if (verificationResult.processedSelfieFile != null)
          verificationResult.processedSelfieFile!
        else if (verificationResult.selfieFile != null)
          verificationResult.selfieFile!,
        ?signupCnicFace,
        ?signupSelfie,
      ];
      final preparedRefs = await OwnerFaceBlur.prepareReferences(references);
      debugPrint(
        '[OwnerBlur] ${preparedRefs.length} reference picture(s) of the reporter',
      );

      final results = await OwnerFaceBlur.blurOwnerFaceInAll(
        _selectedImages,
        ownerReferences: preparedRefs,
        ownerEmbedding: verificationResult.embedding,
      );
      if (!mounted) return;
      setState(() {
        _isLoading = false;
        _loadingMessage = 'Submitting report...';
      });
      final confirmed = await _confirmUploadPreview(results);
      if (!confirmed || !mounted) return;
      filesToUpload = results.map((r) => r.file).toList();
      ownerBlurredCount = results.where((r) => r.ownerBlurred).length;
    }

    if (!mounted) return;
    final formattedTime = _selectedTime?.format(context) ?? '';
    setState(() {
      _isLoading = true;
      _loadingMessage = 'Submitting report...';
    });

    try {
      double latitude;
      double longitude;
      final typedAddress = _locationController.text.trim();
      PlaceSuggestion? typedPlace;
      if (_pickedLatitude == null && !_isPlaceholderAddress(typedAddress)) {
        // The user typed an address: put the pin there, not on their GPS.
        setState(() => _loadingMessage = 'Finding the address on the map...');
        try {
          // Prefer matches near the user (same street names exist in many
          // cities).
          final near = await Geolocator.getLastKnownPosition();
          typedPlace = await RoutingService.geocodeQuery(
            typedAddress,
            nearLocation: near == null
                ? null
                : LatLng(near.latitude, near.longitude),
          ).timeout(const Duration(seconds: 10));
        } catch (_) {}
        if (mounted) setState(() => _loadingMessage = 'Submitting report...');
      }
      if (_pickedLatitude != null && _pickedLongitude != null) {
        latitude = _pickedLatitude!;
        longitude = _pickedLongitude!;
      } else if (typedPlace != null) {
        latitude = typedPlace.latitude;
        longitude = typedPlace.longitude;
      } else {
        Position? position;
        try {
          position = await Geolocator.getCurrentPosition(
            locationSettings: const LocationSettings(
              accuracy: LocationAccuracy.high,
              timeLimit: Duration(seconds: 15),
            ),
          );
        } catch (_) {
          // Only a recent last-known fix (under 2 minutes old) is accurate
          // enough; an old one could be somewhere else entirely.
          final last = await Geolocator.getLastKnownPosition();
          if (last == null ||
              DateTime.now().difference(last.timestamp).inMinutes >= 2) {
            throw Exception(
              "Couldn't get your location. Turn on GPS or use \"Pick on map\".",
            );
          }
          position = last;
        }
        latitude = position.latitude;
        longitude = position.longitude;
      }

      // Videos are uploaded after the report is saved (in the background),
      // so the reporter doesn't wait for large files.
      final pendingVideos = List<XFile>.from(_selectedVideos);

      // Photos, the verification selfie and the address all at once.
      final photoUploads = Future.wait(
        filesToUpload.map((f) => EvidenceStorage.upload(f, user.uid)),
      );
      final selfieUpload = verificationResult.selfieFile != null
          ? EvidenceStorage.upload(
              XFile(verificationResult.selfieFile!.path),
              user.uid,
              folder: 'selfie',
            )
          : Future<String?>.value(null);
      final addressLookup = _finalAddress(latitude, longitude);

      final imageUrls = (await photoUploads).whereType<String>().toList();
      final String? verificationSelfieUrl = await selfieUpload;
      final address = await addressLookup;

      final failed = filesToUpload.length - imageUrls.length;
      if (failed > 0 && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            backgroundColor: Colors.orange,
            content: Text(
              '$failed photo(s) could not be uploaded. Check the internet '
              'connection; the report is still being sent.',
            ),
          ),
        );
      }

      final title = _titleController.text.trim();
      final description = _descriptionController.text.trim();
      final category = _selectedCategory ?? 'Other';

      // 1. Save original report to Firestore
      final reportDocRef = await FirebaseFirestore.instance
          .collection('reports')
          .add({
            'userId': user.uid,
            // Anonymous: no email or selfie on the report police can read.
            if (!_isAnonymous) 'userEmail': user.email,
            'category': category,
            'title': title,
            'description': description,
            'latitude': latitude,
            'longitude': longitude,
            'address': address,
            'date': _selectedDate != null
                ? Timestamp.fromDate(_selectedDate!)
                : null,
            'time': formattedTime,
            'isAnonymous': _isAnonymous,
            'reporterFaceBlurred': ownerBlurredCount > 0,
            'reporterFaceBlurredCount': ownerBlurredCount,
            'images': imageUrls,
            'videos': <String>[],
            if (pendingVideos.isNotEmpty) 'videosPending': pendingVideos.length,
            if (!_isAnonymous) 'verificationSelfieUrl': verificationSelfieUrl,
            'verified': true,
            'identityVerified': true,
            'identityMatchScore': verificationResult.similarityScore,
            'identityVerifiedAt': FieldValue.serverTimestamp(),
            'status': 'pending',
            'priority': 'PENDING',
            'timestamp': FieldValue.serverTimestamp(),
          });

      // Anonymous reports: keep who sent it in a locked record that only an
      // administrator can open (e.g. for a court order or a malicious report).
      if (_isAnonymous) {
        try {
          await FirebaseFirestore.instance
              .collection('report_identity')
              .doc(reportDocRef.id)
              .set({
                'userId': user.uid,
                'userEmail': user.email,
                'verificationSelfieUrl': verificationSelfieUrl,
                'createdAt': FieldValue.serverTimestamp(),
              });
        } catch (e) {
          debugPrint('[IncidentReport] identity record failed: $e');
        }
      }

      // AI priority analysis and video uploads run in the background; the
      // report is already saved, so the reporter can move on right away.
      unawaited(
        _analyzeReport(
          reportDocRef,
          title: title,
          description: description,
          category: category,
          address: address,
        ),
      );
      if (pendingVideos.isNotEmpty) {
        unawaited(
          EvidenceStorage.uploadReportVideos(
            reportDocRef,
            pendingVideos,
            user.uid,
          ),
        );
      }

      await _clearDraft();
      if (!mounted) return;
      _titleController.clear();
      _descriptionController.clear();
      _locationController.clear();
      setState(() {
        _selectedCategory = null;
        _selectedImages.clear();
        _selectedVideos.clear();
        _pickedLatitude = null;
        _pickedLongitude = null;
        _step = 0;
      });
      Navigator.pushReplacement(
        context,
        MaterialPageRoute(
          builder: (_) => ReportSubmittedScreen(
            reportId: reportDocRef.id,
            videosUploading: pendingVideos.length,
          ),
        ),
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('❌ Error: $e'), backgroundColor: Colors.red),
        );
      }
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  // ===========================================================================
  // 4-step flow: What happened → Where and when → Evidence → Review
  // ===========================================================================

  int _step = 0;
  static const List<String> _stepTitles = [
    'What happened',
    'Where and when',
    'Evidence',
    'Review',
  ];
  static const List<String> _mainCategories = [
    'Harassment',
    'Snatching',
    'Robbery',
    'Theft',
    'Assault',
  ];
  bool _showAllCategories = false;
  bool _draftRestored = false;
  String? _categoryError;
  String? _titleError;
  String? _descriptionError;
  String? _locationError;
  String _when = 'now';
  bool _locating = false;

  // Voice typing for the description
  final stt.SpeechToText _dictation = stt.SpeechToText();
  bool _dictating = false;
  bool _resumeDistressVoice = false;
  String _dictationLocale = 'en_US';
  String _textBeforeDictation = '';
  Timer? _dictationWatch;

  static const String _draftKey = 'incident_report_draft';

  // ---------------------------------------------------------------------------
  // Validation & navigation
  // ---------------------------------------------------------------------------

  bool _validateStep(int step) {
    setState(() {
      if (step == 0) {
        _categoryError = _selectedCategory == null
            ? 'Choose what happened'
            : null;
        _titleError = _titleController.text.trim().isEmpty
            ? 'Add a short title'
            : null;
        final d = _descriptionController.text.trim();
        _descriptionError = d.isEmpty
            ? 'Describe what happened'
            : d.length < 20
            ? 'Add a little more detail (at least 20 characters)'
            : null;
      } else if (step == 1) {
        _locationError = _isPlaceholderAddress(_locationController.text)
            ? 'Add where it happened'
            : null;
      }
    });
    if (step == 0) {
      return _categoryError == null &&
          _titleError == null &&
          _descriptionError == null;
    }
    if (step == 1) return _locationError == null;
    return true;
  }

  /// Checks every step before submitting; jumps to the first one with a gap.
  bool _validateAll() {
    for (var s = 0; s < 2; s++) {
      if (!_validateStep(s)) {
        setState(() => _step = s);
        return false;
      }
    }
    return true;
  }

  void _next() {
    if (!_validateStep(_step)) return;
    FocusScope.of(context).unfocus();
    _saveDraft();
    setState(() => _step++);
    if (_step == 1) _autoLocate();
  }

  void _back() {
    if (_step == 0) return;
    FocusScope.of(context).unfocus();
    setState(() => _step--);
  }

  void _goTo(int step) {
    if (step > _step) {
      for (var s = _step; s < step; s++) {
        if (!_validateStep(s)) {
          setState(() => _step = s);
          return;
        }
      }
    }
    setState(() => _step = step);
    if (step == 1) _autoLocate();
  }

  // ---------------------------------------------------------------------------
  // Location & time
  // ---------------------------------------------------------------------------

  /// Fills the location from GPS (with a street address) when it's empty.
  Future<void> _autoLocate({bool force = false}) async {
    if (_locating) return;
    if (!force && !_isPlaceholderAddress(_locationController.text)) return;
    setState(() => _locating = true);
    try {
      var perm = await Geolocator.checkPermission();
      if (perm == LocationPermission.denied) {
        perm = await Geolocator.requestPermission();
      }
      if (perm == LocationPermission.denied ||
          perm == LocationPermission.deniedForever) {
        return;
      }
      final p = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high,
          timeLimit: Duration(seconds: 10),
        ),
      );
      String address = '';
      try {
        address = await RoutingService.reverseGeocode(
          LatLng(p.latitude, p.longitude),
        ).timeout(const Duration(seconds: 8));
      } catch (_) {}
      if (_isPlaceholderAddress(address)) {
        address =
            '${p.latitude.toStringAsFixed(5)}, ${p.longitude.toStringAsFixed(5)}';
      }
      if (!mounted) return;
      setState(() {
        _pickedLatitude = p.latitude;
        _pickedLongitude = p.longitude;
        _locationController.text = address;
        _locationError = null;
      });
    } catch (e) {
      debugPrint('[Report] auto-locate failed: $e');
    } finally {
      if (mounted) setState(() => _locating = false);
    }
  }

  Future<void> _openMapPicker() async {
    final result = await Navigator.push<LocationPickerResult>(
      context,
      MaterialPageRoute(
        builder: (_) => LocationPickerScreen(
          initialPosition: _pickedLatitude != null
              ? LatLng(_pickedLatitude!, _pickedLongitude!)
              : null,
          title: 'Pick incident location',
        ),
      ),
    );
    if (result != null && mounted) {
      setState(() {
        _pickedLatitude = result.latitude;
        _pickedLongitude = result.longitude;
        _locationController.text = result.address;
        _locationError = null;
      });
    }
  }

  void _applyWhen(String when) {
    final now = DateTime.now();
    final t = when == '1h' ? now.subtract(const Duration(hours: 1)) : now;
    _when = when;
    _selectedDate = DateTime(t.year, t.month, t.day);
    _selectedTime = when == 'today' ? null : TimeOfDay.fromDateTime(t);
  }

  Future<void> _setWhen(String when) async {
    if (when == 'custom') {
      await _pickDate();
      if (!mounted) return;
      await _pickTime();
      if (!mounted) return;
      setState(() => _when = 'custom');
      return;
    }
    setState(() => _applyWhen(when));
  }

  String get _whenLabel {
    final d = _selectedDate;
    if (d == null) return 'Not set';
    final date = '${d.day}/${d.month}/${d.year}';
    final time = _selectedTime?.format(context);
    switch (_when) {
      case 'now':
        return 'Just now ($date${time != null ? ', $time' : ''})';
      case '1h':
        return 'About an hour ago (${time ?? date})';
      case 'today':
        return 'Earlier today ($date)';
      default:
        return time != null ? '$date, $time' : date;
    }
  }

  // ---------------------------------------------------------------------------
  // Voice typing (pauses distress listening while the mic is in use)
  // ---------------------------------------------------------------------------

  Future<void> _toggleDictation() async {
    if (_dictating) {
      await _dictation.stop();
      _endDictation();
      return;
    }
    final monitor = DistressMonitor.instance;
    _resumeDistressVoice = monitor.isRunning && monitor.isVoiceEnabled;
    if (_resumeDistressVoice) await monitor.voice.stopMonitoring();

    final ok = await _dictation.initialize();
    if (!ok) {
      _endDictation();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text("Voice typing isn't available on this phone"),
          ),
        );
      }
      return;
    }
    _textBeforeDictation = _descriptionController.text.trim();
    setState(() => _dictating = true);
    await _dictation.listen(
      listenOptions: stt.SpeechListenOptions(
        localeId: _dictationLocale,
        listenFor: const Duration(minutes: 1),
        pauseFor: const Duration(seconds: 5),
        partialResults: true,
        listenMode: stt.ListenMode.dictation,
      ),
      onResult: (r) {
        final text = [
          _textBeforeDictation,
          r.recognizedWords,
        ].where((s) => s.trim().isNotEmpty).join(' ');
        _descriptionController.value = TextEditingValue(
          text: text,
          selection: TextSelection.collapsed(offset: text.length),
        );
        if (_descriptionError != null) {
          setState(() => _descriptionError = null);
        }
        if (r.finalResult) _endDictation();
      },
    );
    // Stop the mic state once the recognizer finishes on its own.
    _dictationWatch?.cancel();
    _dictationWatch = Timer.periodic(const Duration(milliseconds: 600), (t) {
      if (!_dictation.isListening) {
        t.cancel();
        _endDictation();
      }
    });
  }

  void _endDictation() {
    _dictationWatch?.cancel();
    _dictationWatch = null;
    if (mounted && _dictating) setState(() => _dictating = false);
    if (_resumeDistressVoice) {
      _resumeDistressVoice = false;
      DistressMonitor.instance.voice.startMonitoring();
    }
  }

  // ---------------------------------------------------------------------------
  // Drafts
  // ---------------------------------------------------------------------------

  Future<void> _saveDraft() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final empty =
          _titleController.text.trim().isEmpty &&
          _descriptionController.text.trim().isEmpty &&
          _selectedCategory == null;
      if (empty) {
        await prefs.remove(_draftKey);
        return;
      }
      await prefs.setString(
        _draftKey,
        jsonEncode({
          'category': _selectedCategory,
          'title': _titleController.text,
          'description': _descriptionController.text,
          'location': _isPlaceholderAddress(_locationController.text)
              ? ''
              : _locationController.text,
          'lat': _pickedLatitude,
          'lng': _pickedLongitude,
          'anonymous': _isAnonymous,
        }),
      );
    } catch (_) {}
  }

  Future<void> _clearDraft() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_draftKey);
    } catch (_) {}
  }

  Future<void> _restoreDraft() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_draftKey);
      if (raw == null || !mounted) return;
      final d = jsonDecode(raw) as Map<String, dynamic>;
      setState(() {
        _selectedCategory = d['category'] as String?;
        _titleController.text = (d['title'] ?? '') as String;
        _descriptionController.text = (d['description'] ?? '') as String;
        _locationController.text = (d['location'] ?? '') as String;
        _pickedLatitude = (d['lat'] as num?)?.toDouble();
        _pickedLongitude = (d['lng'] as num?)?.toDouble();
        _isAnonymous = d['anonymous'] == true;
        if (_selectedCategory != null &&
            !_mainCategories.contains(_selectedCategory)) {
          _showAllCategories = true;
        }
      });
      // Shown as a small banner at the top of the form (a snackbar with a
      // button stays on screen and covered the Continue button).
      setState(() => _draftRestored = true);
    } catch (_) {}
  }

  // ---------------------------------------------------------------------------
  // Build
  // ---------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final wide = MediaQuery.sizeOf(context).width >= 720;
    final pad = Responsive.pagePadding(context);

    final content = Column(
      children: [
        if (!wide) _buildProgressBar(),
        if (_draftRestored) _buildDraftBanner(),
        Expanded(
          child: SingleChildScrollView(
            padding: EdgeInsets.fromLTRB(pad, 16, pad, 24),
            child: ContentWidth(
              maxWidth: 640,
              child: AnimatedSwitcher(
                duration: const Duration(milliseconds: 200),
                child: KeyedSubtree(key: ValueKey(_step), child: _buildStep()),
              ),
            ),
          ),
        ),
        _buildBottomBar(),
      ],
    );

    return PopScope(
      canPop: _step == 0 && !_isLoading,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) {
          _saveDraft();
          return;
        }
        if (!_isLoading) _back();
      },
      child: Scaffold(
        appBar: AppBar(
          title: Text(_step == 0 ? 'Report incident' : _stepTitles[_step]),
          actions: [
            Padding(
              padding: const EdgeInsets.only(right: 16),
              child: Center(
                child: Text(
                  'Step ${_step + 1} of 4',
                  style: const TextStyle(
                    fontSize: 13,
                    color: AppColors.textMuted,
                  ),
                ),
              ),
            ),
          ],
        ),
        body: Stack(
          children: [
            if (wide)
              Row(
                children: [
                  SizedBox(width: 240, child: _buildStepList()),
                  const VerticalDivider(width: 1, color: AppColors.border),
                  Expanded(child: content),
                ],
              )
            else
              content,
            if (_isLoading) _buildLoadingOverlay(),
          ],
        ),
      ),
    );
  }

  Widget _buildDraftBanner() {
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 10, 16, 0),
      padding: const EdgeInsets.fromLTRB(12, 4, 4, 4),
      decoration: BoxDecoration(
        color: AppColors.primarySoft,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          const Icon(Icons.restore, size: 18, color: AppColors.primary),
          const SizedBox(width: 8),
          const Expanded(
            child: Text(
              'Your unfinished report was restored',
              style: TextStyle(fontSize: 13, color: AppColors.primaryDark),
            ),
          ),
          TextButton(
            onPressed: () {
              _clearDraft();
              setState(() {
                _selectedCategory = null;
                _titleController.clear();
                _descriptionController.clear();
                _locationController.clear();
                _pickedLatitude = null;
                _pickedLongitude = null;
                _isAnonymous = false;
                _step = 0;
                _draftRestored = false;
              });
            },
            child: const Text('Start over'),
          ),
          IconButton(
            tooltip: 'Dismiss',
            visualDensity: VisualDensity.compact,
            icon: const Icon(Icons.close, size: 18),
            onPressed: () => setState(() => _draftRestored = false),
          ),
        ],
      ),
    );
  }

  Widget _buildProgressBar() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      child: Row(
        children: [
          for (var i = 0; i < 4; i++) ...[
            if (i > 0) const SizedBox(width: 6),
            Expanded(
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 250),
                height: 4,
                decoration: BoxDecoration(
                  color: i <= _step ? AppColors.primary : AppColors.border,
                  borderRadius: BorderRadius.circular(4),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildStepList() {
    return ListView(
      padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 12),
      children: [
        for (var i = 0; i < 4; i++)
          Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: Material(
              color: i == _step ? AppColors.primarySoft : Colors.transparent,
              borderRadius: BorderRadius.circular(12),
              child: InkWell(
                borderRadius: BorderRadius.circular(12),
                onTap: _isLoading ? null : () => _goTo(i),
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Row(
                    children: [
                      CircleAvatar(
                        radius: 13,
                        backgroundColor: i <= _step
                            ? AppColors.primary
                            : AppColors.border,
                        child: i < _step
                            ? const Icon(
                                Icons.check,
                                size: 15,
                                color: Colors.white,
                              )
                            : Text(
                                '${i + 1}',
                                style: TextStyle(
                                  fontSize: 12,
                                  fontWeight: FontWeight.w700,
                                  color: i <= _step
                                      ? Colors.white
                                      : AppColors.textMuted,
                                ),
                              ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          _stepTitles[i],
                          style: TextStyle(
                            fontSize: 14,
                            fontWeight: i == _step
                                ? FontWeight.w600
                                : FontWeight.w500,
                            color: i == _step
                                ? AppColors.primary
                                : AppColors.text,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }

  Widget _buildStep() {
    switch (_step) {
      case 0:
        return _buildWhatStep();
      case 1:
        return _buildWhereStep();
      case 2:
        return _buildEvidenceStep();
      default:
        return _buildReviewStep();
    }
  }

  Widget _label(String text) => Padding(
    padding: const EdgeInsets.only(bottom: 8, left: 2),
    child: Text(
      text,
      style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
    ),
  );

  Widget _error(String? text) => text == null
      ? const SizedBox.shrink()
      : Padding(
          padding: const EdgeInsets.only(top: 6, left: 2),
          child: Text(
            text,
            style: const TextStyle(fontSize: 12.5, color: AppColors.danger),
          ),
        );

  Widget _card({required Widget child, EdgeInsets? padding}) => Container(
    width: double.infinity,
    padding: padding ?? const EdgeInsets.all(16),
    decoration: BoxDecoration(
      color: AppColors.surface,
      borderRadius: BorderRadius.circular(AppRadius.lg),
      border: Border.all(color: AppColors.border),
    ),
    // Own Material so ListTile / SwitchListTile ink shows above the card
    // colour (avoids the "ink splashes may be invisible" assertion).
    child: Material(type: MaterialType.transparency, child: child),
  );

  // ---- Step 1: What happened ----------------------------------------------

  Widget _buildWhatStep() {
    final visible = _showAllCategories
        ? _categories
        : _categories
              .where((c) => _mainCategories.contains(c['name']))
              .toList();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _label('What happened?'),
        LayoutBuilder(
          builder: (context, c) {
            final cols = c.maxWidth >= 520 ? 4 : 3;
            const gap = 8.0;
            final w = (c.maxWidth - gap * (cols - 1)) / cols;
            return Wrap(
              spacing: gap,
              runSpacing: gap,
              children: [
                for (final cat in visible)
                  SizedBox(width: w, child: _categoryTile(cat)),
                if (!_showAllCategories)
                  SizedBox(
                    width: w,
                    child: _categoryTile({
                      'name': 'More',
                      'icon': Iconsax.more,
                    }, onTap: () => setState(() => _showAllCategories = true)),
                  ),
              ],
            );
          },
        ),
        _error(_categoryError),
        const SizedBox(height: 22),
        _label('Short title'),
        TextField(
          key: const Key('report_title_field'),
          controller: _titleController,
          textCapitalization: TextCapitalization.sentences,
          maxLength: 80,
          onChanged: (_) {
            if (_titleError != null) setState(() => _titleError = null);
          },
          decoration: InputDecoration(
            hintText: 'Man following me near the bus stop',
            errorText: _titleError,
            counterText: '',
          ),
        ),
        const SizedBox(height: 18),
        _label('Describe it'),
        TextField(
          key: const Key('report_description_field'),
          controller: _descriptionController,
          minLines: 4,
          maxLines: 8,
          textCapitalization: TextCapitalization.sentences,
          onChanged: (_) {
            if (_descriptionError != null) {
              setState(() => _descriptionError = null);
            }
          },
          decoration: InputDecoration(
            hintText:
                'What did you see? Who was involved? What did they look like?',
            errorText: _descriptionError,
            suffixIcon: Padding(
              padding: const EdgeInsets.only(right: 4),
              child: IconButton(
                tooltip: _dictating
                    ? 'Stop voice typing'
                    : 'Speak instead of typing',
                onPressed: _toggleDictation,
                icon: Icon(
                  _dictating ? Icons.stop_circle : Iconsax.microphone_2,
                  color: _dictating ? AppColors.danger : AppColors.primary,
                ),
              ),
            ),
          ),
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(
              child: Text(
                _dictating
                    ? 'Listening… speak now'
                    : 'Tap the mic to speak instead of typing',
                style: TextStyle(
                  fontSize: 12,
                  color: _dictating ? AppColors.danger : AppColors.textMuted,
                ),
              ),
            ),
            _langChip('English', 'en_US'),
            const SizedBox(width: 6),
            _langChip('اردو', 'ur_PK'),
          ],
        ),
        const SizedBox(height: 20),
        Material(
          color: AppColors.warningSoft,
          borderRadius: BorderRadius.circular(12),
          child: InkWell(
            borderRadius: BorderRadius.circular(12),
            onTap: () => Navigator.pushNamed(context, '/sos'),
            child: const Padding(
              padding: EdgeInsets.symmetric(horizontal: 14, vertical: 12),
              child: Row(
                children: [
                  Icon(Iconsax.warning_2, size: 18, color: AppColors.warning),
                  SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      'In danger right now? Use SOS instead',
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: AppColors.warning,
                      ),
                    ),
                  ),
                  Icon(Icons.chevron_right, color: AppColors.warning),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _categoryTile(Map<String, dynamic> cat, {VoidCallback? onTap}) {
    final name = cat['name'] as String;
    final selected = _selectedCategory == name;
    return Material(
      color: selected ? AppColors.primarySoft : AppColors.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(
          color: selected ? AppColors.primary : AppColors.border,
          width: selected ? 1.5 : 1,
        ),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap:
            onTap ??
            () => setState(() {
              _selectedCategory = name;
              _categoryError = null;
            }),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 6),
          child: Column(
            children: [
              Icon(
                cat['icon'] as IconData,
                size: 22,
                color: selected ? AppColors.primary : AppColors.textMuted,
              ),
              const SizedBox(height: 6),
              Text(
                name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 12.5,
                  fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                  color: selected ? AppColors.primary : AppColors.text,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _langChip(String label, String locale) {
    final on = _dictationLocale == locale;
    return InkWell(
      borderRadius: BorderRadius.circular(999),
      onTap: () => setState(() => _dictationLocale = locale),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration: BoxDecoration(
          color: on ? AppColors.primarySoft : Colors.transparent,
          borderRadius: BorderRadius.circular(999),
          border: Border.all(color: on ? AppColors.primary : AppColors.border),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 12,
            color: on ? AppColors.primary : AppColors.textMuted,
          ),
        ),
      ),
    );
  }

  // ---- Step 2: Where and when ---------------------------------------------

  Widget _buildWhereStep() {
    final hasPoint = _pickedLatitude != null && _pickedLongitude != null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _label('Where did it happen?'),
        _card(
          padding: EdgeInsets.zero,
          child: Column(
            children: [
              ClipRRect(
                borderRadius: const BorderRadius.vertical(
                  top: Radius.circular(AppRadius.lg),
                ),
                child: SizedBox(
                  height: 160,
                  child: hasPoint
                      ? FlutterMap(
                          key: ValueKey('$_pickedLatitude,$_pickedLongitude'),
                          options: MapOptions(
                            initialCenter: LatLng(
                              _pickedLatitude!,
                              _pickedLongitude!,
                            ),
                            initialZoom: 16,
                            interactionOptions: const InteractionOptions(
                              flags: InteractiveFlag.none,
                            ),
                            onTap: (_, _) => _openMapPicker(),
                          ),
                          children: [
                            appTileLayer(),
                            MarkerLayer(
                              markers: [
                                pinMarker(
                                  point: LatLng(
                                    _pickedLatitude!,
                                    _pickedLongitude!,
                                  ),
                                  color: AppColors.danger,
                                  size: 40,
                                ),
                              ],
                            ),
                          ],
                        )
                      : Container(
                          color: AppColors.background,
                          alignment: Alignment.center,
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              _locating
                                  ? const SizedBox(
                                      width: 24,
                                      height: 24,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2.4,
                                      ),
                                    )
                                  : const Icon(
                                      Iconsax.location,
                                      color: AppColors.textSubtle,
                                      size: 28,
                                    ),
                              const SizedBox(height: 8),
                              Text(
                                _locating
                                    ? 'Finding your location…'
                                    : 'No location yet',
                                style: const TextStyle(
                                  color: AppColors.textMuted,
                                  fontSize: 13,
                                ),
                              ),
                            ],
                          ),
                        ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  children: [
                    TextField(
                      key: const Key('report_location_field'),
                      controller: _locationController,
                      onChanged: (_) {
                        // Typed by hand: the old GPS/map pin no longer
                        // matches, so the pin is found from the text on submit.
                        setState(() {
                          _locationError = null;
                          _pickedLatitude = null;
                          _pickedLongitude = null;
                        });
                      },
                      decoration: InputDecoration(
                        hintText: 'Street, area or landmark',
                        prefixIcon: const Icon(Iconsax.location, size: 20),
                        errorText: _locationError,
                      ),
                    ),
                    if (!_locating &&
                        !_isPlaceholderAddress(_locationController.text)) ...[
                      const SizedBox(height: 6),
                      Row(
                        children: [
                          Icon(
                            _pickedLatitude != null
                                ? Icons.check_circle
                                : Icons.info_outline,
                            size: 14,
                            color: _pickedLatitude != null
                                ? AppColors.success
                                : AppColors.textMuted,
                          ),
                          const SizedBox(width: 6),
                          Expanded(
                            child: Text(
                              _pickedLatitude != null
                                  ? 'Pin set: ${_pickedLatitude!.toStringAsFixed(5)}, '
                                        '${_pickedLongitude!.toStringAsFixed(5)}'
                                  : 'The pin will be found from this address. '
                                        'For the exact spot use "Pick on map".',
                              style: const TextStyle(
                                fontSize: 12,
                                color: AppColors.textMuted,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ],
                    const SizedBox(height: 10),
                    Row(
                      children: [
                        Expanded(
                          child: OutlinedButton.icon(
                            onPressed: _locating
                                ? null
                                : () => _autoLocate(force: true),
                            icon: const Icon(Iconsax.gps, size: 18),
                            label: const FittedBox(
                              fit: BoxFit.scaleDown,
                              child: Text('Use my location', maxLines: 1),
                            ),
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: OutlinedButton.icon(
                            onPressed: _openMapPicker,
                            icon: const Icon(Iconsax.map, size: 18),
                            label: const FittedBox(
                              fit: BoxFit.scaleDown,
                              child: Text('Pick on map', maxLines: 1),
                            ),
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
        const SizedBox(height: 24),
        _label('When did it happen?'),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            _whenChip('Just now', 'now'),
            _whenChip('1 hour ago', '1h'),
            _whenChip('Earlier today', 'today'),
            _whenChip(
              _when == 'custom' ? _whenLabel : 'Pick date and time',
              'custom',
              icon: Iconsax.calendar_1,
            ),
          ],
        ),
      ],
    );
  }

  Widget _whenChip(String label, String value, {IconData? icon}) {
    final on = _when == value;
    return ChoiceChip(
      selected: on,
      onSelected: (_) => _setWhen(value),
      showCheckmark: false,
      avatar: icon == null
          ? null
          : Icon(
              icon,
              size: 16,
              color: on ? AppColors.primary : AppColors.textMuted,
            ),
      label: Text(label),
      labelStyle: TextStyle(
        color: on ? AppColors.primary : AppColors.text,
        fontWeight: on ? FontWeight.w600 : FontWeight.w500,
      ),
      side: BorderSide(color: on ? AppColors.primary : AppColors.border),
    );
  }

  /// Gemini priority analysis, with the on-device classifier as fallback.
  static Future<void> _analyzeReport(
    DocumentReference<Map<String, dynamic>> reportDocRef, {
    required String title,
    required String description,
    required String category,
    required String address,
  }) async {
    try {
      final analysis = await ReportAnalysisService().analyzeReport(
        title: title,
        description: description,
        category: category,
        location: address,
      );
      await reportDocRef.update({
        'priority': analysis.priority,
        'severityScore': analysis.severityScore,
        'reason': analysis.reason,
        'detectedFactors': analysis.detectedFactors,
        'immediateDanger': analysis.immediateDanger,
        'violenceDetected': analysis.violenceDetected,
        'weaponDetected': analysis.weaponDetected,
        'injuryDetected': analysis.injuryDetected,
        'threatDetected': analysis.threatDetected,
        'analysisSource': 'gemini',
        'priorityAnalyzedAt': FieldValue.serverTimestamp(),
      });
    } catch (aiError) {
      debugPrint('[IncidentReportScreen] AI analysis failed: $aiError');
      // Keyword classifier so the police dashboard still gets a priority.
      // Police can re-run the AI analysis later from the dashboard.
      try {
        await reportDocRef.update(
          PriorityClassifier.offlineAnalysisFields(
            category: category,
            title: title,
            description: description,
          )..['priorityAnalyzedAt'] = FieldValue.serverTimestamp(),
        );
      } catch (_) {}
    }
  }

  /// Faces in videos are not blurred: say so before the first video.
  Future<bool> _confirmVideoWarning() async {
    if (_videoWarningAccepted) return true;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        icon: const Icon(Icons.warning_amber_rounded, color: Colors.orange),
        title: const Text('Faces in videos are not blurred'),
        content: Text(
          _isAnonymous
              ? 'Videos are sent to police exactly as recorded. Your face or '
                    'voice in the video can reveal who you are, even though '
                    'this report is anonymous.'
              : 'Videos are sent to police exactly as recorded. Your face and '
                    "other people's faces will be visible. Only photos get "
                    'face blur.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('I understand'),
          ),
        ],
      ),
    );
    if (ok == true) _videoWarningAccepted = true;
    return ok == true;
  }

  Future<void> _pickVideo([ImageSource source = ImageSource.gallery]) async {
    if (!await _confirmVideoWarning() || !mounted) return;
    try {
      final video = await _picker.pickVideo(
        source: source,
        maxDuration: const Duration(minutes: 3),
      );
      if (video == null || !mounted) return;
      final size = await video.length();
      if (!mounted) return;
      if (size > EvidenceStorage.maxVideoBytes) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'This video is ${(size / (1024 * 1024)).toStringAsFixed(0)} MB. '
              'Please choose one under 100 MB.',
            ),
          ),
        );
        return;
      }
      setState(() => _selectedVideos.add(video));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Could not add the video: $e')));
    }
  }

  // ---- Step 3: Evidence ----------------------------------------------------

  Widget _buildEvidenceStep() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _label('Add photos and videos'),
        const Text(
          'Optional, but evidence helps police act faster.',
          style: TextStyle(fontSize: 13, color: AppColors.textMuted),
        ),
        const SizedBox(height: 12),
        LayoutBuilder(
          builder: (context, c) {
            final cols = c.maxWidth >= 520 ? 4 : 3;
            const gap = 8.0;
            final w = (c.maxWidth - gap * (cols - 1)) / cols;
            return Wrap(
              spacing: gap,
              runSpacing: gap,
              children: [
                for (var i = 0; i < _selectedImages.length; i++)
                  SizedBox(width: w, height: w, child: _photoTile(i)),
                for (var i = 0; i < _selectedVideos.length; i++)
                  SizedBox(width: w, height: w, child: _videoTile(i)),
                SizedBox(
                  width: w,
                  height: w,
                  child: Material(
                    color: AppColors.primarySoft,
                    borderRadius: BorderRadius.circular(12),
                    child: InkWell(
                      borderRadius: BorderRadius.circular(12),
                      onTap: _showAddEvidenceSheet,
                      child: const Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(Iconsax.add, color: AppColors.primary),
                          SizedBox(height: 4),
                          Text(
                            'Add',
                            style: TextStyle(
                              color: AppColors.primary,
                              fontWeight: FontWeight.w600,
                              fontSize: 12.5,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ],
            );
          },
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(
              child: OutlinedButton.icon(
                onPressed: _takePhoto,
                icon: const Icon(Iconsax.camera, size: 18),
                label: const FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Text('Camera'),
                ),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: OutlinedButton.icon(
                onPressed: _pickImages,
                icon: const Icon(Iconsax.gallery, size: 18),
                label: const FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Text('Gallery'),
                ),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: OutlinedButton.icon(
                onPressed: _canAddVideo ? _showAddVideoSheet : null,
                icon: const Icon(Iconsax.video, size: 18),
                label: const FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Text('Video'),
                ),
              ),
            ),
          ],
        ),
        if (_selectedVideos.isNotEmpty || !EvidenceStorage.canUploadVideos) ...[
          const SizedBox(height: 8),
          Text(
            EvidenceStorage.canUploadVideos
                ? '⚠ Faces in videos are NOT blurred. Up to $_maxVideos '
                      'videos, 100 MB each.'
                : 'Video upload is not set up in this build yet.',
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: EvidenceStorage.canUploadVideos
                  ? Colors.orange.shade800
                  : AppColors.textMuted,
            ),
          ),
        ],
        const SizedBox(height: 24),
        _label('Privacy'),
        _card(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Column(
            children: [
              SwitchListTile(
                key: const Key('anonymous_switch'),
                value: _isAnonymous,
                onChanged: (v) => setState(() => _isAnonymous = v),
                secondary: const Icon(Iconsax.eye_slash),
                title: const Text(
                  'Report anonymously',
                  style: TextStyle(fontWeight: FontWeight.w600, fontSize: 14.5),
                ),
                subtitle: const Text("Police won't see your name"),
              ),
              const Divider(indent: 16, endIndent: 16),
              SwitchListTile(
                key: const Key('blur_faces_switch'),
                value: _shouldBlur,
                onChanged: _isAnonymous
                    ? null
                    : (v) async {
                        setState(() => _blurMyFaceEnabled = v);
                        try {
                          final prefs = await SharedPreferences.getInstance();
                          await prefs.setBool('blur_faces_default', v);
                        } catch (_) {}
                      },
                secondary: const Icon(Iconsax.mask),
                title: const Text(
                  'Blur my face in photos',
                  style: TextStyle(fontWeight: FontWeight.w600, fontSize: 14.5),
                ),
                subtitle: Text(
                  _isAnonymous
                      ? 'Always on for anonymous reports'
                      : 'Other people stay visible as evidence',
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _photoTile(int i) {
    return Stack(
      fit: StackFit.expand,
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(12),
          child: _imagePreview(_selectedImages[i]),
        ),
        Positioned(
          top: 4,
          right: 4,
          child: Material(
            color: Colors.black54,
            shape: const CircleBorder(),
            child: InkWell(
              customBorder: const CircleBorder(),
              onTap: () => _removeImage(i),
              child: const Padding(
                padding: EdgeInsets.all(4),
                child: Icon(Icons.close, size: 16, color: Colors.white),
              ),
            ),
          ),
        ),
        if (_shouldBlur)
          Positioned(
            left: 4,
            bottom: 4,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color: AppColors.successSoft,
                borderRadius: BorderRadius.circular(6),
              ),
              child: const Text(
                'Face blur on',
                style: TextStyle(
                  fontSize: 10,
                  fontWeight: FontWeight.w600,
                  color: AppColors.success,
                ),
              ),
            ),
          ),
      ],
    );
  }

  bool get _canAddVideo =>
      EvidenceStorage.canUploadVideos && _selectedVideos.length < _maxVideos;

  Widget _videoTile(int i) {
    return Stack(
      fit: StackFit.expand,
      children: [
        Container(
          decoration: BoxDecoration(
            color: const Color(0xFF1E293B),
            borderRadius: BorderRadius.circular(12),
          ),
          padding: const EdgeInsets.all(6),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.play_circle_fill, color: Colors.white, size: 34),
              const SizedBox(height: 4),
              Text(
                'Video ${i + 1}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 11.5,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
        Positioned(
          top: 4,
          right: 4,
          child: Material(
            color: Colors.black54,
            shape: const CircleBorder(),
            child: InkWell(
              customBorder: const CircleBorder(),
              onTap: () => setState(() => _selectedVideos.removeAt(i)),
              child: const Padding(
                padding: EdgeInsets.all(4),
                child: Icon(Icons.close, size: 16, color: Colors.white),
              ),
            ),
          ),
        ),
      ],
    );
  }

  void _showAddEvidenceSheet() {
    showModalBottomSheet<void>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Iconsax.camera),
              title: const Text('Take a photo'),
              onTap: () {
                Navigator.pop(ctx);
                _takePhoto();
              },
            ),
            ListTile(
              leading: const Icon(Iconsax.gallery),
              title: const Text('Choose photos'),
              onTap: () {
                Navigator.pop(ctx);
                _pickImages();
              },
            ),
            ListTile(
              enabled: _canAddVideo,
              leading: const Icon(Iconsax.video),
              title: const Text('Record a video'),
              onTap: () {
                Navigator.pop(ctx);
                _pickVideo(ImageSource.camera);
              },
            ),
            ListTile(
              enabled: _canAddVideo,
              leading: const Icon(Icons.video_library_outlined),
              title: const Text('Choose a video'),
              subtitle: const Text('e.g. one recorded in Evidence Capture'),
              onTap: () {
                Navigator.pop(ctx);
                _pickVideo(ImageSource.gallery);
              },
            ),
          ],
        ),
      ),
    );
  }

  void _showAddVideoSheet() {
    showModalBottomSheet<void>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Iconsax.video),
              title: const Text('Record a video'),
              onTap: () {
                Navigator.pop(ctx);
                _pickVideo(ImageSource.camera);
              },
            ),
            ListTile(
              leading: const Icon(Icons.video_library_outlined),
              title: const Text('Choose from gallery'),
              subtitle: const Text('e.g. one recorded in Evidence Capture'),
              onTap: () {
                Navigator.pop(ctx);
                _pickVideo(ImageSource.gallery);
              },
            ),
          ],
        ),
      ),
    );
  }

  // ---- Step 4: Review ------------------------------------------------------

  Widget _buildReviewStep() {
    final photos = _selectedImages.length;
    final videos = _selectedVideos.length;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _label('Check your report'),
        _card(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
          child: Column(
            children: [
              _reviewRow(
                Iconsax.category,
                'Category',
                _selectedCategory ?? '-',
                0,
              ),
              _reviewRow(
                Iconsax.text,
                'Title',
                _titleController.text.trim(),
                0,
              ),
              _reviewRow(
                Iconsax.document_text,
                'Description',
                _descriptionController.text.trim(),
                0,
                maxLines: 3,
              ),
              _reviewRow(
                Iconsax.location,
                'Location',
                _locationController.text.trim(),
                1,
              ),
              _reviewRow(Iconsax.clock, 'When', _whenLabel, 1),
              _reviewRow(
                Iconsax.gallery,
                'Evidence',
                (photos == 0 && videos == 0)
                    ? 'No photos or videos'
                    : [
                        if (photos > 0)
                          '$photos photo${photos == 1 ? '' : 's'}',
                        if (videos > 0)
                          '$videos video${videos == 1 ? '' : 's'}',
                      ].join(', '),
                2,
              ),
              _reviewRow(
                Iconsax.shield_tick,
                'Privacy',
                [
                  _isAnonymous
                      ? 'Anonymous'
                      : 'Your name is shared with police',
                  if (_shouldBlur) 'your face blurred',
                ].join(', '),
                2,
                last: true,
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: AppColors.primarySoft,
            borderRadius: BorderRadius.circular(14),
          ),
          child: const Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(Iconsax.scan, color: AppColors.primary, size: 20),
              SizedBox(width: 10),
              Expanded(
                child: Text(
                  "Next, you'll take a quick selfie so we can confirm it's really you. "
                  'This keeps fake reports out.',
                  style: TextStyle(
                    fontSize: 13,
                    color: AppColors.primaryDark,
                    height: 1.4,
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _reviewRow(
    IconData icon,
    String label,
    String value,
    int editStep, {
    int maxLines = 2,
    bool last = false,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 12),
      decoration: BoxDecoration(
        border: last
            ? null
            : const Border(bottom: BorderSide(color: AppColors.divider)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 18, color: AppColors.textMuted),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: const TextStyle(
                    fontSize: 12,
                    color: AppColors.textMuted,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  value.isEmpty ? '-' : value,
                  maxLines: maxLines,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 14.5,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ],
            ),
          ),
          TextButton(
            onPressed: () => setState(() => _step = editStep),
            child: const Text('Edit'),
          ),
        ],
      ),
    );
  }

  // ---- Bottom bar & loading ------------------------------------------------

  Widget _buildBottomBar() {
    final label = switch (_step) {
      0 || 1 => 'Continue',
      2 => 'Review report',
      _ => 'Verify and submit',
    };
    return Container(
      decoration: const BoxDecoration(
        color: AppColors.surface,
        border: Border(top: BorderSide(color: AppColors.border)),
      ),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
          child: ContentWidth(
            maxWidth: 640,
            child: Row(
              children: [
                if (_step > 0) ...[
                  Expanded(
                    child: OutlinedButton(
                      onPressed: _isLoading ? null : _back,
                      child: const Text('Back'),
                    ),
                  ),
                  const SizedBox(width: 10),
                ],
                Expanded(
                  flex: 2,
                  child: FilledButton(
                    key: const Key('report_next_button'),
                    onPressed: _isLoading
                        ? null
                        : (_step < 3 ? _next : _submitReport),
                    child: Text(label),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildLoadingOverlay() {
    return Container(
      color: AppColors.text.withValues(alpha: 0.45),
      alignment: Alignment.center,
      child: Container(
        margin: const EdgeInsets.all(32),
        padding: const EdgeInsets.all(24),
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(AppRadius.lg),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const CircularProgressIndicator(),
            const SizedBox(height: 16),
            Text(
              _loadingMessage,
              textAlign: TextAlign.center,
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
          ],
        ),
      ),
    );
  }
}

/// Shown after a report is submitted.
class ReportSubmittedScreen extends StatelessWidget {
  final String reportId;
  final int videosUploading;
  const ReportSubmittedScreen({
    super.key,
    required this.reportId,
    this.videosUploading = 0,
  });

  @override
  Widget build(BuildContext context) {
    final ref = reportId.length > 8
        ? reportId.substring(0, 8).toUpperCase()
        : reportId.toUpperCase();
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 480),
            child: FillScroll(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  children: [
                    const Spacer(),
                    Container(
                      width: 88,
                      height: 88,
                      decoration: const BoxDecoration(
                        color: AppColors.successSoft,
                        shape: BoxShape.circle,
                      ),
                      child: const Icon(
                        Iconsax.tick_circle,
                        size: 44,
                        color: AppColors.success,
                      ),
                    ),
                    const SizedBox(height: 20),
                    const Text(
                      'Report submitted',
                      style: TextStyle(
                        fontSize: 24,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      'Reference #$ref',
                      style: const TextStyle(color: AppColors.textMuted),
                    ),
                    if (videosUploading > 0) ...[
                      const SizedBox(height: 16),
                      ValueListenableBuilder<String?>(
                        valueListenable: EvidenceStorage.videoStatus,
                        builder: (_, status, _) => Container(
                          width: double.infinity,
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: AppColors.primarySoft,
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: Row(
                            children: [
                              if (status != null && !status.startsWith('✓'))
                                const SizedBox(
                                  width: 18,
                                  height: 18,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                )
                              else
                                const Icon(
                                  Iconsax.video,
                                  size: 18,
                                  color: AppColors.primary,
                                ),
                              const SizedBox(width: 10),
                              Expanded(
                                child: Text(
                                  status ??
                                      'Videos are uploading in the background. '
                                          'Keep the app open until done.',
                                  style: const TextStyle(fontSize: 13),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ],
                    const SizedBox(height: 24),
                    Container(
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        color: AppColors.surface,
                        borderRadius: BorderRadius.circular(AppRadius.lg),
                        border: Border.all(color: AppColors.border),
                      ),
                      child: const Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'What happens next',
                            style: TextStyle(fontWeight: FontWeight.w700),
                          ),
                          SizedBox(height: 10),
                          _NextLine(
                            Iconsax.flash_1,
                            'Police review new reports, most urgent first.',
                          ),
                          _NextLine(
                            Iconsax.notification,
                            'Status updates appear in My reports.',
                          ),
                          _NextLine(
                            Iconsax.danger,
                            'In danger right now? Use SOS from the home screen.',
                          ),
                        ],
                      ),
                    ),
                    const Spacer(),
                    SizedBox(
                      width: double.infinity,
                      height: 54,
                      child: FilledButton(
                        onPressed: () => Navigator.pushReplacementNamed(
                          context,
                          '/my-reports',
                        ),
                        child: const Text('Track in My reports'),
                      ),
                    ),
                    const SizedBox(height: 8),
                    TextButton(
                      onPressed: () => Navigator.pop(context),
                      child: const Text('Back to home'),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _NextLine extends StatelessWidget {
  final IconData icon;
  final String text;
  const _NextLine(this.icon, this.text);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 18, color: AppColors.primary),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              text,
              style: const TextStyle(
                fontSize: 13.5,
                color: AppColors.textMuted,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
