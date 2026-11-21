import 'dart:io';

import '../theme/responsive.dart';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:iconsax/iconsax.dart';
import 'package:image_picker/image_picker.dart';

import '../services/auth_service.dart';
import '../services/face_service.dart';
import '../services/face_verification_config.dart';
import '../services/storage_service.dart';
import 'live_face_verification_screen.dart';

class SignUpScreen extends StatefulWidget {
  const SignUpScreen({super.key});

  @override
  State<SignUpScreen> createState() => _SignUpScreenState();
}

class _SignUpScreenState extends State<SignUpScreen> {
  final TextEditingController _nameController = TextEditingController();
  final TextEditingController _emailController = TextEditingController();
  final TextEditingController _passwordController = TextEditingController();
  final TextEditingController _confirmPasswordController =
      TextEditingController();
  final TextEditingController _cnicController = TextEditingController();

  final _formKey = GlobalKey<FormState>();
  final AuthService _authService = AuthService();
  final StorageService _storageService = StorageService();

  int _currentStep =
      0; // 0: Form, 1: CNIC Upload, 2: Selfie & Liveness, 3: Success
  bool _isLoading = false;
  bool _isAnalyzingCNIC = false;
  bool _obscurePassword = true;
  bool _obscureConfirmPassword = true;

  // CNIC verification state
  File? _cnicImageFile;
  File? _cnicCroppedFaceFile;
  List<double>? _cnicEmbedding;
  String? _detectedCnic;
  String? _cnicError;

  // Live Selfie verification state
  File? _selfieImageFile;
  List<double>? _selfieEmbedding;
  double _matchSimilarity = 0.0;
  bool _isIdentityVerified = false;
  String? _verificationError;

  // Step 1 Credential availability check state
  bool _isCheckingAvailability = false;
  String? _step1Error;
  bool _emailTaken = false;
  bool _cnicTaken = false;

  @override
  void dispose() {
    _nameController.dispose();
    _emailController.dispose();
    _passwordController.dispose();
    _confirmPasswordController.dispose();
    _cnicController.dispose();
    super.dispose();
  }

  // CNIC Formatter (35000-1234567-8)
  String _formatCNIC(String value) {
    value = value.replaceAll(RegExp(r'[^0-9]'), '');
    if (value.length > 13) value = value.substring(0, 13);

    if (value.length > 5) {
      value = '${value.substring(0, 5)}-${value.substring(5)}';
    }
    if (value.length > 13) {
      value = '${value.substring(0, 13)}-${value.substring(13, 14)}';
    }
    return value;
  }

  // Validate Step 1 form and verify Email & CNIC availability directly
  Future<void> _validateAndProceedToCNIC() async {
    // 1. Basic form validation
    if (_formKey.currentState == null || !_formKey.currentState!.validate()) {
      return;
    }

    FocusScope.of(context).unfocus();

    setState(() {
      _isCheckingAvailability = true;
      _step1Error = null;
      _emailTaken = false;
      _cnicTaken = false;
    });

    final email = _emailController.text.trim();
    final cnic = _cnicController.text.trim();
    final rawCnic = cnic.replaceAll(RegExp(r'[^0-9]'), '');

    try {
      // 1. Safe non-blocking check on Firestore for existing verified email
      try {
        final emailQuery = await FirebaseFirestore.instance
            .collection('users')
            .where('email', isEqualTo: email.toLowerCase())
            .limit(1)
            .get()
            .timeout(const Duration(seconds: 4));

        if (emailQuery.docs.isNotEmpty) {
          final data = emailQuery.docs.first.data();
          if (data['isIdentityVerified'] == true) {
            if (mounted) {
              setState(() {
                _isCheckingAvailability = false;
                _emailTaken = true;
                _step1Error = 'This email is already registered and verified. Please sign in instead.';
              });
              _formKey.currentState?.validate();
            }
            return;
          }
        }
      } catch (e) {
        debugPrint('Firestore email check note (non-blocking): $e');
      }

      // 2. Safe non-blocking check on Firestore for existing verified CNIC
      try {
        final cnicQuery = await FirebaseFirestore.instance
            .collection('users')
            .where('cnic', isEqualTo: cnic)
            .limit(1)
            .get()
            .timeout(const Duration(seconds: 4));

        DocumentSnapshot<Map<String, dynamic>>? existingCnicDoc;
        if (cnicQuery.docs.isNotEmpty) {
          existingCnicDoc = cnicQuery.docs.first;
        } else if (rawCnic.isNotEmpty && rawCnic != cnic) {
          final rawCnicQuery = await FirebaseFirestore.instance
              .collection('users')
              .where('cnic', isEqualTo: rawCnic)
              .limit(1)
              .get()
              .timeout(const Duration(seconds: 4));
          if (rawCnicQuery.docs.isNotEmpty) {
            existingCnicDoc = rawCnicQuery.docs.first;
          }
        }

        if (existingCnicDoc != null) {
          final existingData = existingCnicDoc.data() ?? {};
          final existingDocEmail = (existingData['email'] as String? ?? '')
              .trim()
              .toLowerCase();
          final bool isExistingVerified =
              existingData['isIdentityVerified'] == true;

          // Only block if verified on a DIFFERENT email
          if (isExistingVerified &&
              existingDocEmail.isNotEmpty &&
              existingDocEmail != email.toLowerCase()) {
            if (mounted) {
              setState(() {
                _isCheckingAvailability = false;
                _cnicTaken = true;
                _step1Error = 'This CNIC is already registered to another verified account. Please sign in with your registered email.';
              });
              _formKey.currentState?.validate();
            }
            return;
          }
        }
      } catch (e) {
        debugPrint('Firestore CNIC check note (non-blocking): $e');
      }

      // 3. Move cleanly to Step 2 (CNIC Verification)
      if (mounted) {
        setState(() {
          _isCheckingAvailability = false;
          _step1Error = null;
          _emailTaken = false;
          _cnicTaken = false;
          _currentStep = 1;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isCheckingAvailability = false;
          _currentStep = 1; // Always let user proceed to Step 2
        });
      }
    }
  }

  // Pick and process CNIC image
  Future<void> _pickAndProcessCNIC(ImageSource source) async {
    setState(() {
      _cnicError = null;
      _isAnalyzingCNIC = true;
    });

    try {
      final picker = ImagePicker();
      final XFile? picked = await picker.pickImage(
        source: source,
        maxWidth: 2400,
        maxHeight: 2400,
        imageQuality: 98,
      );

      if (picked == null) {
        setState(() => _isAnalyzingCNIC = false);
        return;
      }

      final file = File(picked.path);
      final cnicEntered = _cnicController.text.trim();
      final result = await FaceService.processCNIC(
        file,
        expectedCnic: cnicEntered.isNotEmpty ? cnicEntered : null,
      );

      setState(() {
        _isAnalyzingCNIC = false;
        if (result.success && result.embedding != null) {
          _cnicImageFile = file;
          _cnicCroppedFaceFile = result.croppedFaceFile;
          _cnicEmbedding = result.embedding;
          _detectedCnic = result.detectedCnic;
          _cnicError = null;
        } else {
          _cnicImageFile = null;
          _cnicCroppedFaceFile = null;
          _cnicEmbedding = null;
          _detectedCnic = null;
          _cnicError = result.message;
        }
      });
    } catch (e) {
      debugPrint('CNIC processing error: $e');
      setState(() {
        _isAnalyzingCNIC = false;
        _cnicError = 'Error processing card image: $e';
      });
    }
  }

  // Launch Live Selfie and Liveness Screen
  Future<void> _startLiveSelfieVerification() async {
    if (_cnicEmbedding == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Please upload and verify your CNIC first.'),
          backgroundColor: Colors.orange,
        ),
      );
      return;
    }

    setState(() {
      _verificationError = null;
    });

    final LiveVerificationResult? result =
        await Navigator.push<LiveVerificationResult>(
          context,
          MaterialPageRoute(
            builder: (context) => LiveFaceVerificationScreen(
              title: 'Registration Selfie',
              subtitle: 'Verify that you are the physical owner of this CNIC',
              referenceEmbedding: _cnicEmbedding,
              referenceImageFile: _cnicCroppedFaceFile,
              fullCnicImageFile: _cnicImageFile,
              awsMatchThreshold: 65.0,
            ),
          ),
        );

    if (result == null || !result.verified || result.embedding == null) {
      setState(() {
        _isIdentityVerified = false;
        _verificationError = result?.message ?? 'Live selfie verification was not completed or failed. Please retry.';
      });
      return;
    }

    setState(() {
      _selfieImageFile = result.selfieFile;
      _selfieEmbedding = result.embedding;
      _matchSimilarity = result.similarityScore;
      _isIdentityVerified = true;
      _verificationError = null;
    });
  }

  // Final Registration: Only allowed when verification succeeds
  Future<void> _signUp() async {
    if (_formKey.currentState != null && !_formKey.currentState!.validate()) {
      setState(() => _currentStep = 0);
      return;
    }

    final name = _nameController.text.trim();
    final email = _emailController.text.trim();
    final password = _passwordController.text.trim();
    final cnic = _cnicController.text.trim();

    if (name.isEmpty || email.isEmpty || password.isEmpty || cnic.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Please complete all account details in Step 1.'),
          backgroundColor: Colors.red,
        ),
      );
      setState(() => _currentStep = 0);
      return;
    }

    if (!_isIdentityVerified ||
        _cnicEmbedding == null ||
        _selfieEmbedding == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'You must complete identity verification before creating an account.',
          ),
          backgroundColor: Colors.red,
        ),
      );
      return;
    }

    // Defense-in-depth biometric verification before creating account
    final double matchScore = FaceService.compareEmbeddings(
      _cnicEmbedding!,
      _selfieEmbedding!,
    );
    final bool isBiometricMatch =
        _isIdentityVerified ||
        (_matchSimilarity >= 0.60) ||
        (matchScore >= 0.50);

    if (!isBiometricMatch) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Biometric mismatch (${(matchScore * 100).toStringAsFixed(0)}% match). '
            'The selfie does not match the CNIC cardholder.',
          ),
          backgroundColor: Colors.red,
        ),
      );
      setState(() {
        _isIdentityVerified = false;
        _verificationError = 'Identity verification failed. Selfie does not match the CNIC portrait.';
      });
      return;
    }

    setState(() => _isLoading = true);

    try {
      // 1. Ensure user is authenticated / created in Firebase Auth
      User? user = FirebaseAuth.instance.currentUser;
      if (user == null || user.email?.toLowerCase() != email.toLowerCase()) {
        try {
          final userCredential = await FirebaseAuth.instance
              .createUserWithEmailAndPassword(email: email, password: password);
          user = userCredential.user;
        } on FirebaseAuthException catch (authErr) {
          if (authErr.code == 'email-already-in-use') {
            // If email already exists in Auth (e.g. from prior incomplete attempt),
            // attempt sign in with password to finalize registration
            try {
              final signInCredential = await FirebaseAuth.instance
                  .signInWithEmailAndPassword(email: email, password: password);
              user = signInCredential.user;
            } catch (_) {
              throw FirebaseAuthException(
                code: 'email-already-in-use',
                message: 'This email is already registered. If this is your account, please sign in instead.',
              );
            }
          } else {
            rethrow;
          }
        }
      }
      if (user == null)
        throw Exception(
          'Registration failed: User session could not be authenticated.',
        );
      final uid = user.uid;

      // 2. Upload private CNIC reference image to protected storage
      String? cnicPhotoUrl;
      if (_cnicImageFile != null) {
        try {
          cnicPhotoUrl = await _storageService.uploadIdentityDocument(
            _cnicImageFile!,
            uid,
          );
        } catch (e) {
          debugPrint('Storage upload note: $e');
        }
      }

      // 3. Save standard user profile to Firestore (with identity verification data on the document)
      await FirebaseFirestore.instance.collection('users').doc(uid).set({
        'name': name,
        'email': email,
        'cnic': cnic,
        'createdAt': FieldValue.serverTimestamp(),
        'isVerified': false, // Email verification
        'isIdentityVerified': true, // Biometric verification
        'identityVerifiedAt': FieldValue.serverTimestamp(),
        'faceEmbedding': _selfieEmbedding ?? _cnicEmbedding,
        'selfieEmbedding': _selfieEmbedding,
        'cnicEmbedding': _cnicEmbedding,
        'similarityScore': _matchSimilarity,
        'cnicPhotoUrl': cnicPhotoUrl,
        'trustedContacts': [],
      }, SetOptions(merge: true));

      // 4. Save biometric reference data in private subcollection users/{uid}/identity/reference
      try {
        await _authService.saveUserIdentityReference(
          uid: uid,
          faceEmbedding: _selfieEmbedding ?? _cnicEmbedding!,
          selfieEmbedding: _selfieEmbedding,
          cnicEmbedding: _cnicEmbedding,
          similarityScore: _matchSimilarity,
          cnicPhotoUrl: cnicPhotoUrl,
        );
      } catch (e) {
        debugPrint('Subcollection save note: $e');
      }

      // Clean up any stale unverified orphan documents with this CNIC from prior incomplete attempts
      try {
        final staleDocs = await FirebaseFirestore.instance
            .collection('users')
            .where('cnic', isEqualTo: cnic)
            .get();
        for (final doc in staleDocs.docs) {
          if (doc.id != uid && doc.data()['isVerified'] != true) {
            await doc.reference.delete().catchError((_) {});
          }
        }
      } catch (_) {}

      // 5. Send verification email (police domain accounts skip this)
      if (!email.toLowerCase().endsWith('@police.gov.pk')) {
        await user.sendEmailVerification().catchError((e) {
          debugPrint('Verification email note (non-fatal): $e');
        });
      }

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Identity Verified! Account created. Check your email for confirmation.',
            ),
            backgroundColor: Colors.green,
            duration: Duration(seconds: 4),
          ),
        );
        Navigator.of(context).pushNamedAndRemoveUntil('/', (route) => false);
      }
    } on FirebaseAuthException catch (e) {
      String message = 'Sign up failed';
      if (e.code == 'email-already-in-use') {
        message =
            e.message ??
            'This email is already registered. Please sign in instead.';
      } else if (e.code == 'weak-password') {
        message = 'Password is too weak. Please use at least 6 characters.';
      } else if (e.code == 'invalid-email') {
        message = 'Invalid email address format.';
      } else if (e.code == 'network-request-failed') {
        message = 'Network error. Please check your internet connection.';
      } else {
        message = e.message ?? 'An error occurred during registration.';
      }

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(message), backgroundColor: Colors.red),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error: $e'), backgroundColor: Colors.red),
        );
      }
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: _currentStep == 0,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop && _currentStep > 0) {
          setState(() => _currentStep--);
        }
      },
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Create Verified Account'),
          backgroundColor: Colors.transparent,
          elevation: 0,
          leading: _currentStep > 0
              ? IconButton(
                  icon: const Icon(Icons.arrow_back),
                  onPressed: () => setState(() => _currentStep--),
                )
              : null,
        ),
        body: ContentWidth(
          maxWidth: 520,
          child: SafeArea(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(24.0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Header
                  const Text(
                    'Join Safety Guardian',
                    style: TextStyle(fontSize: 28, fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    'A secure platform requiring verified identity to prevent false incident reporting.',
                    style: TextStyle(fontSize: 14, color: Colors.grey.shade600),
                  ),
                  const SizedBox(height: 24),

                  // Step Wizard Tabs
                  _buildStepTabs(),
                  const SizedBox(height: 28),

                  // Step Content
                  if (_currentStep == 0) ...[
                    _buildAccountDetailsForm(),
                  ] else if (_currentStep == 1) ...[
                    _buildCNICVerificationStep(),
                  ] else if (_currentStep == 2) ...[
                    _buildLiveSelfieVerificationStep(),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildStepTabs() {
    return Row(
      children: [
        _buildStepBadge(0, '1. Account', Iconsax.user),
        const Expanded(child: Divider(thickness: 2)),
        _buildStepBadge(1, '2. CNIC Face', Iconsax.card),
        const Expanded(child: Divider(thickness: 2)),
        _buildStepBadge(2, '3. Selfie', Iconsax.scan),
      ],
    );
  }

  Widget _buildStepBadge(int stepIndex, String title, IconData icon) {
    final isDone =
        _currentStep > stepIndex ||
        (stepIndex == 1 && _cnicEmbedding != null) ||
        (stepIndex == 2 && _isIdentityVerified);
    final isCurrent = _currentStep == stepIndex;

    return InkWell(
      onTap: () {
        if (stepIndex == 0) {
          setState(() => _currentStep = 0);
        } else if (stepIndex == 1) {
          if (_currentStep == 0) {
            _validateAndProceedToCNIC();
          } else {
            setState(() => _currentStep = 1);
          }
        } else if (stepIndex == 2 && _cnicEmbedding != null) {
          setState(() => _currentStep = 2);
        }
      },
      child: Column(
        children: [
          CircleAvatar(
            radius: 18,
            backgroundColor: isDone
                ? Colors.green
                : isCurrent
                ? const Color(0xFF1D4ED8)
                : Colors.grey.shade300,
            child: Icon(
              isDone ? Icons.check : icon,
              size: 18,
              color: (isDone || isCurrent)
                  ? Colors.white
                  : Colors.grey.shade700,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            title,
            style: TextStyle(
              fontSize: 11,
              fontWeight: isCurrent ? FontWeight.bold : FontWeight.normal,
              color: isCurrent ? const Color(0xFF1D4ED8) : Colors.grey.shade700,
            ),
          ),
        ],
      ),
    );
  }

  // ─── STEP 1: ACCOUNT DETAILS ───────────────────────────────────────────────
  Widget _buildAccountDetailsForm() {
    return Form(
      key: _formKey,
      child: Column(
        children: [
          // Credentials Error Banner
          if (_step1Error != null) ...[
            Container(
              margin: const EdgeInsets.only(bottom: 20),
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              decoration: BoxDecoration(
                color: const Color(0xFFFEF2F2),
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: const Color(0xFFFCA5A5)),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      const Icon(
                        Iconsax.warning_2,
                        color: Color(0xFFDC2626),
                        size: 22,
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          _step1Error!,
                          style: const TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                            color: Color(0xFF991B1B),
                          ),
                        ),
                      ),
                    ],
                  ),
                  if (_emailTaken) ...[
                    const SizedBox(height: 10),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: [
                        TextButton.icon(
                          onPressed: () => Navigator.pop(context),
                          icon: const Icon(
                            Icons.login,
                            size: 16,
                            color: Color(0xFF1D4ED8),
                          ),
                          label: const Text(
                            'Sign In',
                            style: TextStyle(
                              fontWeight: FontWeight.bold,
                              fontSize: 13,
                              color: Color(0xFF1D4ED8),
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        TextButton.icon(
                          onPressed: () {
                            Navigator.pushNamed(context, '/forgot-password');
                          },
                          icon: const Icon(
                            Icons.lock_reset,
                            size: 16,
                            color: Color(0xFF1D4ED8),
                          ),
                          label: const Text(
                            'Reset Password',
                            style: TextStyle(
                              fontWeight: FontWeight.bold,
                              fontSize: 13,
                              color: Color(0xFF1D4ED8),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                ],
              ),
            ),
          ],

          // Full Name
          TextFormField(
            controller: _nameController,
            decoration: InputDecoration(
              labelText: 'Full Name',
              prefixIcon: const Icon(Iconsax.user),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(20),
                borderSide: BorderSide.none,
              ),
              filled: true,
              fillColor: Colors.grey.shade50,
            ),
            validator: (value) {
              if (value == null || value.trim().isEmpty) {
                return 'Please enter your name';
              }
              return null;
            },
          ),
          const SizedBox(height: 18),

          // Email
          TextFormField(
            controller: _emailController,
            keyboardType: TextInputType.emailAddress,
            decoration: InputDecoration(
              labelText: 'Email',
              prefixIcon: const Icon(Iconsax.sms),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(20),
                borderSide: BorderSide.none,
              ),
              filled: true,
              fillColor: Colors.grey.shade50,
            ),
            onChanged: (value) {
              if (_emailTaken || _step1Error != null) {
                setState(() {
                  _emailTaken = false;
                  _step1Error = null;
                });
              }
            },
            validator: (value) {
              if (value == null || value.trim().isEmpty) {
                return 'Please enter your email';
              }
              if (!value.contains('@') || !value.contains('.')) {
                return 'Enter a valid email';
              }
              if (_emailTaken) {
                return 'Email is already used';
              }
              return null;
            },
          ),
          const SizedBox(height: 18),

          // CNIC
          TextFormField(
            controller: _cnicController,
            keyboardType: TextInputType.number,
            decoration: InputDecoration(
              labelText: 'CNIC (35000-1234567-8)',
              prefixIcon: const Icon(Iconsax.card),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(20),
                borderSide: BorderSide.none,
              ),
              filled: true,
              fillColor: Colors.grey.shade50,
            ),
            onChanged: (value) {
              if (_cnicTaken || _step1Error != null || _cnicEmbedding != null) {
                setState(() {
                  _cnicTaken = false;
                  _step1Error = null;
                  _cnicEmbedding = null;
                  _cnicImageFile = null;
                  _cnicCroppedFaceFile = null;
                  _detectedCnic = null;
                  _isIdentityVerified = false;
                });
              }
              String formatted = _formatCNIC(value);
              if (formatted != value) {
                _cnicController.value = TextEditingValue(
                  text: formatted,
                  selection: TextSelection.collapsed(offset: formatted.length),
                );
              }
            },
            validator: (value) {
              if (value == null || value.isEmpty) {
                return 'Please enter your CNIC';
              }
              String digits = value.replaceAll(RegExp(r'[^0-9]'), '');
              if (digits.length != 13) {
                return 'CNIC must be 13 digits';
              }
              if (_cnicTaken) {
                return 'CNIC is already used';
              }
              return null;
            },
          ),
          const SizedBox(height: 18),

          // Password
          TextFormField(
            controller: _passwordController,
            obscureText: _obscurePassword,
            decoration: InputDecoration(
              labelText: 'Password',
              prefixIcon: const Icon(Iconsax.lock),
              suffixIcon: IconButton(
                icon: Icon(_obscurePassword ? Iconsax.eye : Iconsax.eye_slash),
                onPressed: () =>
                    setState(() => _obscurePassword = !_obscurePassword),
              ),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(20),
                borderSide: BorderSide.none,
              ),
              filled: true,
              fillColor: Colors.grey.shade50,
            ),
            validator: (value) {
              if (value == null || value.isEmpty) {
                return 'Please enter your password';
              }
              if (value.length < 6) {
                return 'Password must be at least 6 characters';
              }
              return null;
            },
          ),
          const SizedBox(height: 18),

          // Confirm Password
          TextFormField(
            controller: _confirmPasswordController,
            obscureText: _obscureConfirmPassword,
            decoration: InputDecoration(
              labelText: 'Confirm Password',
              prefixIcon: const Icon(Iconsax.lock),
              suffixIcon: IconButton(
                icon: Icon(
                  _obscureConfirmPassword ? Iconsax.eye : Iconsax.eye_slash,
                ),
                onPressed: () => setState(
                  () => _obscureConfirmPassword = !_obscureConfirmPassword,
                ),
              ),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(20),
                borderSide: BorderSide.none,
              ),
              filled: true,
              fillColor: Colors.grey.shade50,
            ),
            validator: (value) {
              if (value == null || value.isEmpty) {
                return 'Please confirm your password';
              }
              if (value != _passwordController.text) {
                return 'Passwords do not match';
              }
              return null;
            },
          ),
          const SizedBox(height: 28),

          // Next Button with Availability Verification
          SizedBox(
            width: double.infinity,
            height: 54,
            child: ElevatedButton.icon(
              onPressed: _isCheckingAvailability
                  ? null
                  : _validateAndProceedToCNIC,
              icon: _isCheckingAvailability
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(
                        strokeWidth: 2.2,
                        color: Colors.white,
                      ),
                    )
                  : const Icon(Icons.arrow_forward),
              label: Text(
                _isCheckingAvailability
                    ? 'Verifying Credentials...'
                    : 'Next: CNIC Verification',
                style: const TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                ),
              ),
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF1D4ED8),
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(18),
                ),
              ),
            ),
          ),
          const SizedBox(height: 16),

          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text(
                "Already have an account? ",
                style: TextStyle(color: Colors.grey.shade600),
              ),
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text(
                  'Sign In',
                  style: TextStyle(
                    color: Color(0xFF1D4ED8),
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  // ─── STEP 2: CNIC UPLOAD & DETECTION ───────────────────────────────────────
  Widget _buildCNICVerificationStep() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'CNIC Document Verification',
          style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 8),
        Text(
          'Please take or upload a clear, glare-free photo of the FRONT side of your National Identity Card (CNIC). Exactly one face must be visible.',
          style: TextStyle(fontSize: 14, color: Colors.grey.shade600),
        ),
        const SizedBox(height: 14),
        // Helpful Tip Banner
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: Colors.blue.shade50,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: Colors.blue.shade200),
          ),
          child: Row(
            children: [
              const Icon(
                Iconsax.info_circle,
                color: Color(0xFF1D4ED8),
                size: 20,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  'Tip: Place your CNIC on a flat surface. Avoid camera flash glare directly on the cardholder portrait.',
                  style: TextStyle(fontSize: 12, color: Colors.blue.shade900),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),

        if (_cnicImageFile != null && _cnicEmbedding != null) ...[
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: Colors.green.shade50,
              borderRadius: BorderRadius.circular(18),
              border: Border.all(color: Colors.green.shade300),
            ),
            child: Row(
              children: [
                if (_cnicCroppedFaceFile != null)
                  ClipRRect(
                    borderRadius: BorderRadius.circular(12),
                    child: Image.file(
                      _cnicCroppedFaceFile!,
                      width: 70,
                      height: 70,
                      fit: BoxFit.cover,
                    ),
                  )
                else
                  const Icon(Icons.check_circle, color: Colors.green, size: 48),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'CNIC Document & Face Verified! ✅',
                        style: TextStyle(
                          fontWeight: FontWeight.bold,
                          color: Colors.green,
                          fontSize: 16,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        _detectedCnic != null
                            ? 'Original Pakistani CNIC ($_detectedCnic) verified via OCR & portrait isolated.'
                            : 'Original Pakistani CNIC verified & portrait isolated.',
                        style: const TextStyle(
                          fontSize: 13,
                          color: Colors.black87,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
        ],

        if (_cnicError != null) ...[
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: Colors.red.shade50,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: Colors.red.shade300),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Icon(Iconsax.warning_2, color: Colors.red, size: 26),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    _cnicError!,
                    style: const TextStyle(
                      color: Colors.red,
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      height: 1.4,
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
        ],

        if (_isAnalyzingCNIC)
          const Center(
            child: Padding(
              padding: EdgeInsets.all(24.0),
              child: Column(
                children: [
                  CircularProgressIndicator(),
                  SizedBox(height: 12),
                  Text('Detecting and analyzing CNIC face...'),
                ],
              ),
            ),
          )
        else ...[
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: () => _pickAndProcessCNIC(ImageSource.camera),
                  icon: const Icon(Iconsax.camera),
                  label: const Text('Camera'),
                  style: OutlinedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 16),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(16),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: () => _pickAndProcessCNIC(ImageSource.gallery),
                  icon: const Icon(Iconsax.gallery),
                  label: const Text('Gallery'),
                  style: OutlinedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 16),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(16),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ],

        const SizedBox(height: 28),

        Row(
          children: [
            OutlinedButton(
              onPressed: () => setState(() => _currentStep = 0),
              style: OutlinedButton.styleFrom(
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(16),
                ),
              ),
              child: const Text('Back'),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: ElevatedButton(
                onPressed: _cnicEmbedding == null
                    ? null
                    : () => setState(() => _currentStep = 2),
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF1D4ED8),
                  foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(16),
                  ),
                ),
                child: const Text('Next: Live Selfie Verification'),
              ),
            ),
          ],
        ),
      ],
    );
  }

  // ─── STEP 3: LIVE SELFIE & LIVENESS ─────────────────────────────────────────
  Widget _buildLiveSelfieVerificationStep() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'Live Selfie Check',
          style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 8),
        Text(
          'Ensure the person signing up matches the CNIC document. You will take a selfie yourself, review it, and then verify it against the CNIC photo.',
          style: TextStyle(fontSize: 14, color: Colors.grey.shade600),
        ),
        const SizedBox(height: 20),

        if (_isIdentityVerified && _selfieImageFile != null) ...[
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: Colors.green.shade50,
              borderRadius: BorderRadius.circular(18),
              border: Border.all(color: Colors.green.shade300),
            ),
            child: Row(
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(12),
                  child: Image.file(
                    _selfieImageFile!,
                    width: 70,
                    height: 70,
                    fit: BoxFit.cover,
                  ),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'Identity Verified! ✅',
                        style: TextStyle(
                          fontWeight: FontWeight.bold,
                          color: Colors.green,
                          fontSize: 16,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        'Match Confidence: ${(_matchSimilarity * 100).toStringAsFixed(1)}% (Threshold: ${(FaceVerificationConfig.matchThreshold * 100).toStringAsFixed(0)}%)',
                        style: const TextStyle(
                          fontSize: 13,
                          color: Colors.black87,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 20),
        ],

        if (_verificationError != null) ...[
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: Colors.red.shade50,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: Colors.red.shade300),
            ),
            child: Row(
              children: [
                const Icon(Iconsax.warning_2, color: Colors.red, size: 28),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    _verificationError!,
                    style: const TextStyle(color: Colors.red, fontSize: 13),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 20),
        ],

        SizedBox(
          width: double.infinity,
          height: 52,
          child: ElevatedButton.icon(
            onPressed: _startLiveSelfieVerification,
            icon: const Icon(Iconsax.scan, color: Colors.white),
            label: Text(
              _isIdentityVerified
                  ? 'Retake Verification Selfie'
                  : 'Take Selfie & Verify',
              style: const TextStyle(color: Colors.white, fontSize: 16),
            ),
            style: ElevatedButton.styleFrom(
              backgroundColor: _isIdentityVerified
                  ? Colors.grey.shade700
                  : const Color(0xFF1D4ED8),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(16),
              ),
            ),
          ),
        ),

        const SizedBox(height: 32),

        // Final Submit Button
        Row(
          children: [
            OutlinedButton(
              onPressed: () => setState(() => _currentStep = 1),
              style: OutlinedButton.styleFrom(
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(16),
                ),
              ),
              child: const Text('Back'),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: ElevatedButton(
                onPressed: (_isIdentityVerified && !_isLoading)
                    ? _signUp
                    : null,
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.green,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(16),
                  ),
                ),
                child: _isLoading
                    ? const SizedBox(
                        height: 22,
                        width: 22,
                        child: CircularProgressIndicator(
                          color: Colors.white,
                          strokeWidth: 2.5,
                        ),
                      )
                    : const Text(
                        'Complete Registration',
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
              ),
            ),
          ],
        ),
      ],
    );
  }
}
