import 'dart:convert';
import 'dart:io';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:crypto/crypto.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;
import 'package:path_provider/path_provider.dart';

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
    File? selfieImage,
    File? cnicFaceImage,
  }) async {
    // Small copies of the sign-up selfie and CNIC face, kept in the private
    // identity record. Later selfies (e.g. when reporting) are compared with
    // these, and only faces matching them are blurred in evidence photos.
    final selfieJpeg = await compressFace(selfieImage);
    final cnicJpeg = await compressFace(cnicFaceImage);
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
          if (selfieJpeg != null) 'referenceSelfie': Blob(selfieJpeg),
          if (cnicJpeg != null) 'referenceCnicFace': Blob(cnicJpeg),
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

  /// Resizes a face picture to at most 480 px and JPEG quality 80 (about
  /// 30-60 KB) so it fits comfortably in a Firestore document.
  static Future<Uint8List?> compressFace(File? file) async {
    if (file == null) return null;
    try {
      if (!await file.exists()) return null;
      return await compute(_compressFaceBytes, await file.readAsBytes());
    } catch (e) {
      debugPrint('[AuthService] could not compress face picture: $e');
      return null;
    }
  }

  static Uint8List? _compressFaceBytes(Uint8List bytes) {
    final decoded = img.decodeImage(bytes);
    if (decoded == null) return null;
    final upright = img.bakeOrientation(decoded);
    final longest = upright.width > upright.height
        ? upright.width
        : upright.height;
    final resized = longest > 480
        ? img.copyResize(
            upright,
            width: upright.width >= upright.height ? 480 : null,
            height: upright.height > upright.width ? 480 : null,
          )
        : upright;
    return Uint8List.fromList(img.encodeJpg(resized, quality: 80));
  }

  /// The sign-up selfie and CNIC face saved by [saveUserIdentityReference],
  /// written to temporary files (AWS and the face blur read files).
  Future<({File? selfie, File? cnicFace})> getReferenceFaceFiles(
    String uid,
  ) async {
    try {
      final doc = await _firestore
          .collection('users')
          .doc(uid)
          .collection(FaceVerificationConfig.identitySubcollection)
          .doc(FaceVerificationConfig.identityDocId)
          .get();
      final data = doc.data();
      if (data == null) return (selfie: null, cnicFace: null);
      final dir = await getTemporaryDirectory();
      final stamp = DateTime.now().millisecondsSinceEpoch;
      Future<File?> write(dynamic value, String name) async {
        if (value is! Blob || value.bytes.isEmpty) return null;
        final f = File('${dir.path}/${name}_$stamp.jpg');
        await f.writeAsBytes(value.bytes, flush: true);
        return f;
      }

      return (
        selfie: await write(data['referenceSelfie'], 'ref_selfie'),
        cnicFace: await write(data['referenceCnicFace'], 'ref_cnic'),
      );
    } catch (e) {
      debugPrint('[AuthService] reference faces not loaded: $e');
      return (selfie: null, cnicFace: null);
    }
  }

  /// For accounts created before reference pictures were saved: stores the
  /// selfie the user has just verified with, once.
  Future<void> saveReferenceSelfieIfMissing(String uid, File? selfie) async {
    final bytes = await compressFace(selfie);
    if (bytes == null) return;
    try {
      final ref = _firestore
          .collection('users')
          .doc(uid)
          .collection(FaceVerificationConfig.identitySubcollection)
          .doc(FaceVerificationConfig.identityDocId);
      final doc = await ref.get();
      if (doc.data()?['referenceSelfie'] is Blob) return;
      await ref.set({'referenceSelfie': Blob(bytes)}, SetOptions(merge: true));
    } catch (e) {
      debugPrint('[AuthService] could not save reference selfie: $e');
    }
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
