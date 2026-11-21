import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'face_verification_config.dart';

class AuthService {
  final FirebaseAuth _auth = FirebaseAuth.instance;
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;

  // Check if logged-in user is police
  Future<bool> isPolice() async {
    User? user = _auth.currentUser;
    if (user == null) return false;

    // Method 1: Check by email domain
    if (user.email?.contains('@police.gov.pk') == true) {
      return true;
    }

    return false;
  }

  // Get current user role
  Future<String> getUserRole() async {
    User? user = _auth.currentUser;
    if (user == null) return 'none';

    if (user.email?.contains('@police.gov.pk') == true) {
      return 'police';
    }
    return 'citizen';
  }

  // ─── CREDENTIAL PRE-CHECK (EMAIL & CNIC) ────────────────────────────────────

  /// Checks whether the given email or CNIC is already in use by an existing account.
  /// Used in Step 1 of registration to avoid wasted effort before biometric verification.
  Future<CredentialCheckResult> checkCredentialsAvailability({
    required String email,
    required String cnic,
  }) async {
    final cleanEmail = email.trim().toLowerCase();
    final cleanCnic = cnic.trim();
    final rawCnic = cleanCnic.replaceAll(RegExp(r'[^0-9]'), '');

    bool emailInUse = false;
    bool cnicInUse = false;

    // 1. Check email via Firebase Auth
    try {
      // ignore: deprecated_member_use
      final methods = await _auth.fetchSignInMethodsForEmail(cleanEmail);
      if (methods.isNotEmpty) {
        emailInUse = true;
      }
    } on FirebaseAuthException catch (e) {
      if (e.code == 'email-already-in-use') {
        emailInUse = true;
      }
    } catch (_) {
      // Continue to Firestore check
    }

    // 2. Check email via Firestore 'users' collection
    if (!emailInUse) {
      try {
        final emailQuery = await _firestore
            .collection('users')
            .where('email', isEqualTo: cleanEmail)
            .limit(1)
            .get();

        if (emailQuery.docs.isNotEmpty) {
          emailInUse = true;
        } else if (cleanEmail != email.trim()) {
          final originalCaseQuery = await _firestore
              .collection('users')
              .where('email', isEqualTo: email.trim())
              .limit(1)
              .get();
          if (originalCaseQuery.docs.isNotEmpty) {
            emailInUse = true;
          }
        }
      } catch (_) {
        // Non-blocking if offline or permission denied
      }
    }

    // 3. Check CNIC via Firestore 'users' collection
    try {
      final cnicQuery = await _firestore
          .collection('users')
          .where('cnic', isEqualTo: cleanCnic)
          .limit(1)
          .get();

      if (cnicQuery.docs.isNotEmpty) {
        cnicInUse = true;
      } else if (rawCnic.isNotEmpty && rawCnic != cleanCnic) {
        final rawCnicQuery = await _firestore
            .collection('users')
            .where('cnic', isEqualTo: rawCnic)
            .limit(1)
            .get();

        if (rawCnicQuery.docs.isNotEmpty) {
          cnicInUse = true;
        }
      }
    } catch (_) {
      // Non-blocking
    }

    if (emailInUse && cnicInUse) {
      return const CredentialCheckResult(
        isEmailInUse: true,
        isCnicInUse: true,
        errorMessage: 'Email and CNIC are both already registered.',
      );
    } else if (emailInUse) {
      return const CredentialCheckResult(
        isEmailInUse: true,
        errorMessage: 'Email is already used. Please sign in or use a different email.',
      );
    } else if (cnicInUse) {
      return const CredentialCheckResult(
        isCnicInUse: true,
        errorMessage: 'CNIC is already used. Each CNIC can only be linked to one account.',
      );
    }

    return const CredentialCheckResult();
  }

  // ─── IDENTITY VERIFICATION REPOSITORY METHODS ───────────────────────────────

  /// Saves the reference face embedding and verification metadata to the
  /// private subcollection: users/{uid}/identity/reference
  Future<void> saveUserIdentityReference({
    required String uid,
    required List<double> faceEmbedding,
    List<double>? selfieEmbedding,
    List<double>? cnicEmbedding,
    required double similarityScore,
    String? cnicPhotoUrl,
  }) async {
    await _firestore
        .collection('users')
        .doc(uid)
        .collection(FaceVerificationConfig.identitySubcollection)
        .doc(FaceVerificationConfig.identityDocId)
        .set({
          'faceEmbedding': faceEmbedding,
          if (selfieEmbedding != null) 'selfieEmbedding': selfieEmbedding,
          if (cnicEmbedding != null) 'cnicEmbedding': cnicEmbedding,
          'similarityScore': similarityScore,
          'cnicPhotoUrl': cnicPhotoUrl,
          'verifiedAt': FieldValue.serverTimestamp(),
          'status': 'verified',
        });

    await _firestore.collection('users').doc(uid).update({
      'isIdentityVerified': true,
      'identityVerifiedAt': FieldValue.serverTimestamp(),
    });
  }

  /// Retrieves the registered reference face embedding for the given UID.
  /// Prefers the high-quality verified live selfie embedding taken during registration,
  /// falling back to faceEmbedding or cnicEmbedding.
  Future<List<double>?> getUserIdentityEmbedding(String uid) async {
    // 1. Check subcollection users/{uid}/identity/reference
    try {
      final doc = await _firestore
          .collection('users')
          .doc(uid)
          .collection(FaceVerificationConfig.identitySubcollection)
          .doc(FaceVerificationConfig.identityDocId)
          .get();

      if (doc.exists && doc.data() != null) {
        final data = doc.data()!;
        final raw = data['selfieEmbedding'] ?? data['faceEmbedding'] ?? data['cnicEmbedding'];
        if (raw is List<dynamic> && raw.isNotEmpty) {
          return raw.map((e) => (e as num).toDouble()).toList();
        }
      }
    } catch (_) {}

    // 2. Check parent document users/{uid}
    try {
      final userDoc = await _firestore.collection('users').doc(uid).get();
      if (userDoc.exists && userDoc.data() != null) {
        final data = userDoc.data()!;
        final raw = data['selfieEmbedding'] ?? data['faceEmbedding'] ?? data['cnicEmbedding'];
        if (raw is List<dynamic> && raw.isNotEmpty) {
          return raw.map((e) => (e as num).toDouble()).toList();
        }
      }
    } catch (_) {}

    return null;
  }

  /// Checks whether the user has completed identity verification.
  Future<bool> isUserIdentityVerified(String uid) async {
    try {
      final doc = await _firestore.collection('users').doc(uid).get();
      if (!doc.exists || doc.data() == null) return false;
      return doc.data()!['isIdentityVerified'] == true;
    } catch (_) {
      return false;
    }
  }
}

/// Result of checking whether email and/or CNIC are already registered in the system.
class CredentialCheckResult {
  final bool isEmailInUse;
  final bool isCnicInUse;
  final String? errorMessage;

  const CredentialCheckResult({
    this.isEmailInUse = false,
    this.isCnicInUse = false,
    this.errorMessage,
  });

  bool get isAvailable => !isEmailInUse && !isCnicInUse;
}