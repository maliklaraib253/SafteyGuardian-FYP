import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';

/// Who counts as police.
///
/// An account is police only when BOTH are true:
///  1. its email ends with "@police.gov.pk", and
///  2. an admin approved it by adding the document
///     `police_officers/{that email}` in the Firebase console.
/// The Firestore rules enforce the same check, so the data stays protected
/// even if someone creates a fake @police.gov.pk account outside the app.
class PoliceAccess {
  PoliceAccess._();

  static const String domain = '@police.gov.pk';
  static final Map<String, bool> _approved = {};

  static bool hasPoliceEmail(User? user) =>
      (user?.email ?? '').toLowerCase().trim().endsWith(domain);

  static Future<bool> isApprovedOfficer(User user) async {
    final email = user.email;
    if (email == null || !hasPoliceEmail(user)) return false;
    final cached = _approved[email];
    if (cached != null) return cached;
    try {
      final doc = await FirebaseFirestore.instance
          .collection('police_officers')
          .doc(email.trim().toLowerCase())
          .get();
      _approved[email] = doc.exists;
      return doc.exists;
    } catch (e) {
      debugPrint('[PoliceAccess] approval check failed: $e');
      return false;
    }
  }

  static void clearCache() => _approved.clear();

  /// Live approval status: emits true/false whenever an admin approves or
  /// removes this officer.
  static Stream<bool> watchApproval(User user) {
    final email = user.email;
    if (email == null || !hasPoliceEmail(user)) return Stream.value(false);
    final key = email.trim().toLowerCase();
    return FirebaseFirestore.instance
        .collection('police_officers')
        .doc(key)
        .snapshots()
        .map((doc) {
          _approved[key] = doc.exists;
          return doc.exists;
        });
  }
}
