import 'dart:io';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:iconsax/iconsax.dart';
import 'package:image_picker/image_picker.dart';
import '../widgets/custom_button.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:path_provider/path_provider.dart';
import 'package:geolocator/geolocator.dart';
import '../services/storage_service.dart';
import '../services/report_analysis_service.dart';
import '../services/face_blur_service.dart';
import '../services/priority_classifier.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../services/routing_service.dart';
import '../services/auth_service.dart';
import 'live_face_verification_screen.dart';
import 'package:dio/dio.dart';
import 'package:latlong2/latlong.dart' show LatLng;
import 'location_picker_screen.dart';

class IncidentReportScreen extends StatefulWidget {
  const IncidentReportScreen({super.key});

  @override
  State<IncidentReportScreen> createState() => _IncidentReportScreenState();
}

class _IncidentReportScreenState extends State<IncidentReportScreen> {
  static const String _imgbbApiKey = String.fromEnvironment('IMGBB_API_KEY');

  Future<String?> uploadToImgBB(XFile imageFile) async {
    try {
      String url = 'https://api.imgbb.com/1/upload?key=$_imgbbApiKey';

      final bytes = await imageFile.readAsBytes();
      FormData formData = FormData.fromMap({
        'image': MultipartFile.fromBytes(bytes, filename: imageFile.name),
      });

      Response response = await Dio().post(url, data: formData);

      if (response.statusCode == 200) {
        return response.data['data']['url'];
      }
      return null;
    } catch (e) {
      print('Upload error: $e');
      return null;
    }
  }

  final StorageService _storage = StorageService();
  final bool _isUploading = false;
  // Controllers
  final TextEditingController _titleController = TextEditingController();
  final TextEditingController _descriptionController = TextEditingController();
  final TextEditingController _locationController = TextEditingController();

  // Form key
  final _formKey = GlobalKey<FormState>();

  // Selected values
  String? _selectedCategory;
  DateTime? _selectedDate;
  TimeOfDay? _selectedTime;
  final List<XFile> _selectedImages = [];
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
      final doc = await FirebaseFirestore.instance.collection('users').doc(uid).get();
      final url = (doc.data()?['cnicPhotoUrl'] ?? '').toString();
      if (url.isEmpty) return null;
      final bytes = await FirebaseStorage.instance
          .refFromURL(url)
          .getData(15 * 1024 * 1024);
      if (bytes == null || bytes.isEmpty) return null;
      final dir = await getTemporaryDirectory();
      final file = File('${dir.path}/cnic_reference_${DateTime.now().millisecondsSinceEpoch}.jpg');
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
                  '$unchecked photo${unchecked == 1 ? '' : 's'} could not be checked (no internet). They will be uploaded unchanged.',
                  style: TextStyle(fontSize: 12, color: Colors.orange.shade800),
                ),
              ],
              const SizedBox(height: 12),
              SizedBox(
                height: 150,
                child: ListView.separated(
                  scrollDirection: Axis.horizontal,
                  itemCount: results.length,
                  separatorBuilder: (_, __) => const SizedBox(width: 8),
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
                            padding: const EdgeInsets.symmetric(vertical: 2),
                            decoration: BoxDecoration(
                              color: Colors.black.withValues(alpha: 0.6),
                              borderRadius: BorderRadius.circular(6),
                            ),
                            child: const Text(
                              'Your face blurred',
                              textAlign: TextAlign.center,
                              style: TextStyle(color: Colors.white, fontSize: 10),
                            ),
                          ),
                        ),
                    ],
                  ),
                        const SizedBox(height: 4),
                        Text(
                          results[i].detail,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(fontSize: 10, color: Colors.grey.shade700),
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

      setState(() {
        _selectedImages.addAll(images);
      });
    } catch (e) {
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

      if (image != null) {
        setState(() {
          _selectedImages.add(image);
        });
      }
    } catch (e) {
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
    if (!_formKey.currentState!.validate()) return;

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
    final List<double>? refEmbedding =
        await authService.getUserIdentityEmbedding(user.uid);
    final File? cnicFile = await _downloadCnicPhoto(user.uid);

    if (!mounted) return;
    setState(() {
      _isLoading = false;
      _loadingMessage = 'Submitting report...';
    });

    if ((refEmbedding == null || refEmbedding.isEmpty) && cnicFile == null) {
      if (!mounted) return;
      showDialog(
        context: context,
        builder: (context) => AlertDialog(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
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
    final LiveVerificationResult? verificationResult =
        await Navigator.push<LiveVerificationResult>(
      context,
      MaterialPageRoute(
        builder: (context) => LiveFaceVerificationScreen(
          title: 'Report Identity Verification',
          subtitle: 'Verify live identity against your registered biometric profile',
          referenceEmbedding:
              (refEmbedding == null || refEmbedding.isEmpty) ? null : refEmbedding,
          // CNIC photo enables the accurate cloud (AWS) face match.
          referenceImageFile: cnicFile,
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

    // Step 5: Blur ONLY the reporter's own face in the evidence photos, using
    // the selfie they just verified with. Everyone else stays visible.
    List<XFile> filesToUpload = List<XFile>.from(_selectedImages);
    int ownerBlurredCount = 0;
    if (_shouldBlur && _selectedImages.isNotEmpty) {
      setState(() {
        _isLoading = true;
        _loadingMessage = 'Finding your face in photos...';
      });
      // Pictures of the reporter: the selfie just verified + their CNIC photo.
      final references = <File>[
        if (verificationResult.processedSelfieFile != null)
          verificationResult.processedSelfieFile!
        else if (verificationResult.selfieFile != null)
          verificationResult.selfieFile!,
      ];
      if (cnicFile != null) references.add(cnicFile);
      final preparedRefs = await OwnerFaceBlur.prepareReferences(references);
      debugPrint('[OwnerBlur] ${preparedRefs.length} reference picture(s) of the reporter');

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

    final formattedTime = _selectedTime?.format(context) ?? '';
    setState(() {
      _isLoading = true;
      _loadingMessage = 'Submitting report...';
    });

    try {
      double latitude;
      double longitude;
      if (_pickedLatitude != null && _pickedLongitude != null) {
        latitude = _pickedLatitude!;
        longitude = _pickedLongitude!;
      } else {
        final position = await Geolocator.getCurrentPosition(
          desiredAccuracy: LocationAccuracy.high,
        );
        latitude = position.latitude;
        longitude = position.longitude;
      }

      List<String> imageUrls = [];
      if (filesToUpload.isNotEmpty) {
        for (final XFile toUpload in filesToUpload) {
          String? url = await uploadToImgBB(toUpload);
          if (url != null) {
            imageUrls.add(url);
          }
        }
      }

      String? verificationSelfieUrl;
      if (verificationResult.selfieFile != null) {
        verificationSelfieUrl =
            await uploadToImgBB(XFile(verificationResult.selfieFile!.path));
      }

      final title = _titleController.text.trim();
      final description = _descriptionController.text.trim();
      final category = _selectedCategory ?? 'Other';
      final address = await _finalAddress(latitude, longitude);

      // 1. Save original report to Firestore
      final reportDocRef = await FirebaseFirestore.instance.collection('reports').add({
        'userId': user.uid,
        'userEmail': user.email,
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
        'verificationSelfieUrl': verificationSelfieUrl,
        'verified': true,
        'identityVerified': true,
        'identityMatchScore': verificationResult.similarityScore,
        'identityVerifiedAt': FieldValue.serverTimestamp(),
        'status': 'pending',
        'priority': 'PENDING',
        'timestamp': FieldValue.serverTimestamp(),
      });

      // 2. Perform semantic AI analysis via Gemini ReportAnalysisService
      try {
        final analysisService = ReportAnalysisService();
        final analysis = await analysisService.analyzeReport(
          title: title,
          description: description,
          category: category,
          location: address,
        );

        // 3. Save AI analysis fields into the SAME Firestore report document
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
        debugPrint('[IncidentReportScreen] AI Analysis warning (non-fatal): $aiError');
        // If AI analysis fails, the original report is safely preserved in Firestore
        // Fall back to the on-device keyword classifier so the police
        // dashboard still gets a meaningful priority. Police can re-run the
        // AI analysis later from the dashboard.
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

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('✅ Identity Verified & Report submitted successfully!'),
          backgroundColor: Colors.green,
        ),
      );

      // Clear form
      _titleController.clear();
      _descriptionController.clear();
      _locationController.clear();
      setState(() {
        _selectedCategory = null;
        _selectedDate = null;
        _selectedTime = null;
        _selectedImages.clear();
        _pickedLatitude = null;
        _pickedLongitude = null;
      });

      Navigator.pop(context);
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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Report Incident'),
      ),
      body: Stack(
        children: [
          // Main content
          SingleChildScrollView(
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Anonymous toggle
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 8,
                  ),
                  decoration: BoxDecoration(
                    color: Colors.blue.shade50,
                    borderRadius: BorderRadius.circular(15),
                    border: Border.all(color: Colors.blue.shade200),
                  ),
                  child: Row(
                    children: [
                      Icon(
                        _isAnonymous ? Iconsax.eye_slash : Iconsax.eye,
                        color: const Color(0xFF1D4ED8),
                      ),
                      const SizedBox(width: 10),
                      const Text(
                        'Report Anonymously',
                        style: TextStyle(fontWeight: FontWeight.w600),
                      ),
                      const Spacer(),
                      Switch(
                        value: _isAnonymous,
                        onChanged: (value) {
                          setState(() {
                            _isAnonymous = value;
                          });
                        },
                        activeThumbColor: const Color(0xFF1D4ED8),
                      ),
                    ],
                  ),
                ),

                const SizedBox(height: 12),

                // Face blurring toggle
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 8,
                  ),
                  decoration: BoxDecoration(
                    color: Colors.teal.shade50,
                    borderRadius: BorderRadius.circular(15),
                    border: Border.all(color: Colors.teal.shade200),
                  ),
                  child: Row(
                    children: [
                      Icon(Icons.face_retouching_off, color: Colors.teal.shade700),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text(
                              'Blur My Face in Photos',
                              style: TextStyle(fontWeight: FontWeight.w600),
                            ),
                            Text(
                              _isAnonymous
                                  ? 'Always on for anonymous reports'
                                  : 'Only your face is blurred. Other people stay visible as evidence.',
                              style: TextStyle(
                                fontSize: 12,
                                color: Colors.grey.shade700,
                              ),
                            ),
                          ],
                        ),
                      ),
                      Switch(
                        key: const Key('blur_faces_switch'),
                        value: _shouldBlur,
                        onChanged: _isAnonymous
                            ? null
                            : (value) {
                                setState(() => _blurMyFaceEnabled = value);
                              },
                        activeThumbColor: Colors.teal,
                      ),
                    ],
                  ),
                ),

                const SizedBox(height: 20),

                // Form
                Form(
                  key: _formKey,
                  child: Column(
                    children: [
                      // Category Selection
                      const Text(
                        'Select Incident Category',
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 10),

                      // Categories grid
                      GridView.builder(
                        shrinkWrap: true,
                        physics: const NeverScrollableScrollPhysics(),
                        gridDelegate:
                            const SliverGridDelegateWithFixedCrossAxisCount(
                              crossAxisCount: 3,
                              childAspectRatio: 1,
                              crossAxisSpacing: 10,
                              mainAxisSpacing: 10,
                            ),
                        itemCount: _categories.length,
                        itemBuilder: (context, index) {
                          final category = _categories[index];
                          final isSelected =
                              _selectedCategory == category['name'];

                          return GestureDetector(
                            onTap: () {
                              setState(() {
                                _selectedCategory = category['name'];
                              });
                            },
                            child: Container(
                              decoration: BoxDecoration(
                                color: isSelected
                                    ? category['color'].withOpacity(0.2)
                                    : Colors.grey.shade50,
                                borderRadius: BorderRadius.circular(15),
                                border: Border.all(
                                  color: isSelected
                                      ? category['color']
                                      : Colors.grey.shade200,
                                  width: isSelected ? 2 : 1,
                                ),
                              ),
                              child: Column(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  Icon(
                                    category['icon'],
                                    color: isSelected
                                        ? category['color']
                                        : Colors.grey.shade600,
                                    size: 30,
                                  ),
                                  const SizedBox(height: 5),
                                  Text(
                                    category['name'],
                                    textAlign: TextAlign.center,
                                    style: TextStyle(
                                      fontSize: 11,
                                      fontWeight: isSelected
                                          ? FontWeight.bold
                                          : FontWeight.normal,
                                      color: isSelected
                                          ? category['color']
                                          : Colors.grey.shade700,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          );
                        },
                      ),

                      const SizedBox(height: 20),

                      // Title
                      TextFormField(
                        controller: _titleController,
                        decoration: InputDecoration(
                          labelText: 'Incident Title',
                          prefixIcon: const Icon(
                            Iconsax.edit,
                            color: Color(0xFF1D4ED8),
                          ),
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(15),
                            borderSide: BorderSide.none,
                          ),
                          filled: true,
                          fillColor: Colors.grey.shade50,
                          hintText: 'Brief title of the incident',
                        ),
                        validator: (value) {
                          if (value == null || value.isEmpty) {
                            return 'Please enter a title';
                          }
                          return null;
                        },
                      ),

                      const SizedBox(height: 15),

                      // Date and Time Row
                      Row(
                        children: [
                          // Date
                          Expanded(
                            child: GestureDetector(
                              onTap: _pickDate,
                              child: Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 12,
                                  vertical: 16,
                                ),
                                decoration: BoxDecoration(
                                  color: Colors.grey.shade50,
                                  borderRadius: BorderRadius.circular(15),
                                  border: Border.all(
                                    color: Colors.grey.shade200,
                                  ),
                                ),
                                child: Row(
                                  children: [
                                    const Icon(
                                      Iconsax.calendar,
                                      color: Color(0xFF1D4ED8),
                                      size: 20,
                                    ),
                                    const SizedBox(width: 10),
                                    Expanded(
                                      child: Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                          Text(
                                            'Date',
                                            style: TextStyle(
                                              fontSize: 12,
                                              color: Colors.grey.shade600,
                                            ),
                                          ),
                                          Text(
                                            _selectedDate == null
                                                ? 'Select date'
                                                : '${_selectedDate!.day}/${_selectedDate!.month}/${_selectedDate!.year}',
                                            style: const TextStyle(
                                              fontWeight: FontWeight.w600,
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(width: 10),

                          // Time
                          Expanded(
                            child: GestureDetector(
                              onTap: _pickTime,
                              child: Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 12,
                                  vertical: 16,
                                ),
                                decoration: BoxDecoration(
                                  color: Colors.grey.shade50,
                                  borderRadius: BorderRadius.circular(15),
                                  border: Border.all(
                                    color: Colors.grey.shade200,
                                  ),
                                ),
                                child: Row(
                                  children: [
                                    const Icon(
                                      Iconsax.clock,
                                      color: Color(0xFF1D4ED8),
                                      size: 20,
                                    ),
                                    const SizedBox(width: 10),
                                    Expanded(
                                      child: Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                          Text(
                                            'Time',
                                            style: TextStyle(
                                              fontSize: 12,
                                              color: Colors.grey.shade600,
                                            ),
                                          ),
                                          Text(
                                            _selectedTime == null
                                                ? 'Select time'
                                                : _selectedTime!.format(
                                                    context,
                                                  ),
                                            style: const TextStyle(
                                              fontWeight: FontWeight.w600,
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),

                      const SizedBox(height: 15),

                      // Location
                      TextFormField(
                        controller: _locationController,
                        decoration: InputDecoration(
                          labelText: 'Location',
                          prefixIcon: const Icon(
                            Iconsax.location,
                            color: Color(0xFF1D4ED8),
                          ),
                          suffixIcon: IconButton(
                            icon: const Icon(
                              Iconsax.map,
                              color: Color(0xFF1D4ED8),
                            ),
                            onPressed: () async {
                              final result =
                                  await Navigator.push<LocationPickerResult>(
                                context,
                                MaterialPageRoute(
                                  builder: (_) => LocationPickerScreen(
                                    initialPosition: _pickedLatitude != null
                                        ? LatLng(
                                            _pickedLatitude!,
                                            _pickedLongitude!,
                                          )
                                        : null,
                                    title: 'Pick Incident Location',
                                  ),
                                ),
                              );
                              if (result != null) {
                                setState(() {
                                  _pickedLatitude = result.latitude;
                                  _pickedLongitude = result.longitude;
                                  _locationController.text = result.address;
                                });
                              }
                            },
                          ),
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(15),
                            borderSide: BorderSide.none,
                          ),
                          filled: true,
                          fillColor: Colors.grey.shade50,
                          hintText: 'Enter location or pick from map',
                        ),
                        validator: (value) {
                          if (value == null || value.isEmpty) {
                            return 'Please enter location';
                          }
                          return null;
                        },
                      ),

                      const SizedBox(height: 15),

                      // Description
                      TextFormField(
                        controller: _descriptionController,
                        maxLines: 5,
                        decoration: InputDecoration(
                          labelText: 'Incident Description',
                          prefixIcon: const Padding(
                            padding: EdgeInsets.only(bottom: 50),
                            child: Icon(Iconsax.note, color: Color(0xFF1D4ED8)),
                          ),
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(15),
                            borderSide: BorderSide.none,
                          ),
                          filled: true,
                          fillColor: Colors.grey.shade50,
                          hintText:
                              'Provide detailed description of the incident...',
                          alignLabelWithHint: true,
                        ),
                        validator: (value) {
                          if (value == null || value.isEmpty) {
                            return 'Please enter description';
                          }
                          if (value.length < 20) {
                            return 'Description must be at least 20 characters';
                          }
                          return null;
                        },
                      ),

                      const SizedBox(height: 20),

                      // Media Upload Section
                      Container(
                        padding: const EdgeInsets.all(15),
                        decoration: BoxDecoration(
                          color: Colors.blue.shade50,
                          borderRadius: BorderRadius.circular(15),
                          border: Border.all(color: Colors.blue.shade200),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                const Icon(
                                  Iconsax.gallery,
                                  color: Color(0xFF1D4ED8),
                                ),
                                const SizedBox(width: 10),
                                const Text(
                                  'Upload Evidence',
                                  style: TextStyle(
                                    fontWeight: FontWeight.w600,
                                    fontSize: 16,
                                  ),
                                ),
                                const Spacer(),
                                Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 8,
                                    vertical: 4,
                                  ),
                                  decoration: BoxDecoration(
                                    color: Colors.orange.shade100,
                                    borderRadius: BorderRadius.circular(10),
                                  ),
                                  child: Text(
                                    'Optional',
                                    style: TextStyle(
                                      fontSize: 12,
                                      color: Colors.orange.shade800,
                                      fontWeight: FontWeight.w500,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 10),
                            const Text(
                              'Upload photos or videos as evidence.',
                              style: TextStyle(
                                fontSize: 12,
                                color: Colors.grey,
                              ),
                            ),
                            const SizedBox(height: 15),

                            // Image picker buttons
                            Row(
                              children: [
                                Expanded(
                                  child: OutlinedButton.icon(
                                    onPressed: _takePhoto,
                                    icon: const Icon(Iconsax.camera),
                                    label: const Text('Camera'),
                                    style: OutlinedButton.styleFrom(
                                      shape: RoundedRectangleBorder(
                                        borderRadius: BorderRadius.circular(10),
                                      ),
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 10),
                                Expanded(
                                  child: OutlinedButton.icon(
                                    onPressed: _pickImages,
                                    icon: const Icon(Iconsax.gallery),
                                    label: const Text('Gallery'),
                                    style: OutlinedButton.styleFrom(
                                      shape: RoundedRectangleBorder(
                                        borderRadius: BorderRadius.circular(10),
                                      ),
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),

                      const SizedBox(height: 15),

                      // Selected images grid
                      if (_selectedImages.isNotEmpty) ...[
                        const Text(
                          'Selected Images',
                          style: TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(height: 10),
                        GridView.builder(
                          shrinkWrap: true,
                          physics: const NeverScrollableScrollPhysics(),
                          gridDelegate:
                              const SliverGridDelegateWithFixedCrossAxisCount(
                                crossAxisCount: 3,
                                crossAxisSpacing: 5,
                                mainAxisSpacing: 5,
                              ),
                          itemCount: _selectedImages.length,
                          itemBuilder: (context, index) {
                            return Stack(
                              children: [
                                Positioned.fill(
                                  child: ClipRRect(
                                    borderRadius: BorderRadius.circular(10),
                                    child: _imagePreview(_selectedImages[index]),
                                  ),
                                ),
                                Positioned(
                                  top: 5,
                                  right: 5,
                                  child: GestureDetector(
                                    onTap: () => _removeImage(index),
                                    child: Container(
                                      padding: const EdgeInsets.all(3),
                                      decoration: BoxDecoration(
                                        color: Colors.red,
                                        shape: BoxShape.circle,
                                      ),
                                      child: const Icon(
                                        Icons.close,
                                        color: Colors.white,
                                        size: 12,
                                      ),
                                    ),
                                  ),
                                ),
                              ],
                            );
                          },
                        ),
                        const SizedBox(height: 10),
                      ],

                      const SizedBox(height: 20),

                      // Biometric Identity Verification Requirement Notice
                      Container(
                        padding: const EdgeInsets.all(16),
                        decoration: BoxDecoration(
                          color: const Color(0xFF1D4ED8).withOpacity(0.06),
                          borderRadius: BorderRadius.circular(16),
                          border: Border.all(
                            color: const Color(0xFF1D4ED8).withOpacity(0.2),
                          ),
                        ),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Icon(
                              Iconsax.shield_security,
                              color: Color(0xFF1D4ED8),
                              size: 26,
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  const Text(
                                    'Biometric Identity Verification Enforced',
                                    style: TextStyle(
                                      fontWeight: FontWeight.bold,
                                      fontSize: 14,
                                      color: Color(0xFF1D4ED8),
                                    ),
                                  ),
                                  const SizedBox(height: 4),
                                  Text(
                                    'Upon tapping "Submit Report", you will verify your live identity with a front-camera selfie matched against your registered CNIC reference face.',
                                    style: TextStyle(
                                      fontSize: 12,
                                      color: Colors.grey.shade700,
                                      height: 1.3,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 20),

                      const SizedBox(height: 10),

                      // Submit button
                      CustomButton(
                        text: 'Submit Report',
                        onPressed: _submitReport,
                        isLoading: _isLoading,
                      ),

                      const SizedBox(height: 20),

                      // Privacy note
                      Container(
                        padding: const EdgeInsets.all(15),
                        decoration: BoxDecoration(
                          color: Colors.grey.shade100,
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: Row(
                          children: [
                            Icon(
                              Iconsax.shield_tick,
                              color: Colors.green.shade600,
                              size: 20,
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Text(
                                'Your identity is protected.',
                                style: TextStyle(
                                  fontSize: 11,
                                  color: Colors.grey.shade700,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),

                      const SizedBox(height: 20),
                    ],
                  ),
                ),
              ],
            ),
          ),

          // Loading overlay
          if (_isLoading)
            Container(
              color: Colors.black.withValues(alpha: 0.5),
              child: Center(
                child: Card(
                  elevation: 10,
                  shape: const RoundedRectangleBorder(
                    borderRadius: BorderRadius.all(Radius.circular(20)),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.all(20),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const CircularProgressIndicator(
                          valueColor: AlwaysStoppedAnimation<Color>(
                            Color(0xFF1D4ED8),
                          ),
                        ),
                        const SizedBox(height: 15),
                        Text(_loadingMessage),
                      ],
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
