import 'dart:convert';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:crypto/crypto.dart';
import 'package:firebase_auth/firebase_auth.dart';

import 'police_access.dart';
import 'face_verification_config.dart';

class AuthService {
  final FirebaseAuth _auth = FirebaseAuth.instance;
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;

  // Check if logged-in user is police
  Future<bool> isPolice() async {
    User? user = _auth.currentUser;
    if (user == null) return false;

    // Method 1: Check by email domain
    if (PoliceAccess.hasPoliceEmail(user) &&
        await PoliceAccess.isApprovedOfficer(user)) {
      return true;
    }

    return false;
  }

  // Get current user role
  Future<String> getUserRole() async {
    User? user = _auth.currentUser;
    if (user == null) return 'none';

    if (PoliceAccess.hasPoliceEmail(user) &&
        await PoliceAccess.isApprovedOfficer(user)) {
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

    // 2 + 3. Check the private registry (hashed email / CNIC only; user
    // profiles themselves are no longer readable by other people).
    try {
      if (!emailInUse) emailInUse = await isEmailRegistered(cleanEmail);
    } catch (_) {}
    try {
      cnicInUse = await isCnicRegistered(cleanCnic);
    } catch (_) {}

    if (emailInUse && cnicInUse) {
      return const CredentialCheckResult(
        isEmailInUse: true,
        isCnicInUse: true,
        errorMessage: 'Email and CNIC are both already registered.',
      );
    } else if (emailInUse) {
      return const CredentialCheckResult(
        isEmailInUse: true,
        errorMessage:
            'Email is already used. Please sign in or use a different email.',
      );
    } else if (cnicInUse) {
      return const CredentialCheckResult(
        isCnicInUse: true,
        errorMessage: 'CNIC is already used. Each CNIC can only be linked to one account.',
      );
    }

    return const CredentialCheckResult();
  }

  // ─── PRIVATE REGISTRY (is this email / CNIC already taken?) ─────────────────
  //
  // registry/{key} holds only a one-way hash of an email or CNIC and the
  // owner's uid, so signup can check "already registered?" without being
  // able to read anyone's profile. Rules allow a direct get, never a list.

  static String _hash(String v) => sha256.convert(utf8.encode(v)).toString();
  static String emailKey(String email) =>
      'email_${_hash(email.trim().toLowerCase())}';
  static String cnicKey(String cnic) =>
      'cnic_${_hash(cnic.replaceAll(RegExp(r'[^0-9]'), ''))}';

  Future<bool> isEmailRegistered(String email) async {
    final doc = await _firestore
        .collection('registry')
        .doc(emailKey(email))
        .get();
    return doc.exists && doc.data()?['identityVerified'] == true;
  }

  Future<bool> isCnicRegistered(String cnic) async {
    if (cnic.replaceAll(RegExp(r'[^0-9]'), '').isEmpty) return false;
    final doc = await _firestore
        .collection('registry')
        .doc(cnicKey(cnic))
        .get();
    return doc.exists && doc.data()?['identityVerified'] == true;
  }

  /// Records the signed-in user's email and CNIC in the registry. Safe to
  /// call repeatedly (used after signup and on app start for older accounts).
  Future<void> ensureRegistry({
    required String uid,
    required String email,
    String? cnic,
  }) async {
    final data = {
      'uid': uid,
      'identityVerified': true,
      // Lets signup tell "this CNIC belongs to a different email" without
      // storing the email itself.
      'emailKey': emailKey(email),
      'updatedAt': FieldValue.serverTimestamp(),
    };
    try {
      await _firestore.collection('registry').doc(emailKey(email)).set(data);
    } catch (_) {}
    if (cnic != null && cnic.replaceAll(RegExp(r'[^0-9]'), '').isNotEmpty) {
      try {
        await _firestore.collection('registry').doc(cnicKey(cnic)).set(data);
      } catch (_) {}
    }
  }

  /// For accounts made before the registry existed: copy this user's email
  /// and CNIC into it once.
  Future<void> ensureRegistryForCurrentUser() async {
    final user = _auth.currentUser;
    if (user == null || user.email == null) return;
    try {
      final doc = await _firestore.collection('users').doc(user.uid).get();
      final data = doc.data();
      if (data == null || data['isIdentityVerified'] != true) return;
      await ensureRegistry(
        uid: user.uid,
        email: user.email!,
        cnic: data['cnic']?.toString(),
      );
    } catch (_) {}
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
          'selfieEmbedding': ?selfieEmbedding,
          'cnicEmbedding': ?cnicEmbedding,
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
        final raw =
            data['selfieEmbedding'] ??
            data['faceEmbedding'] ??
            data['cnicEmbedding'];
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
        final raw =
            data['selfieEmbedding'] ??
            data['faceEmbedding'] ??
            data['cnicEmbedding'];
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
