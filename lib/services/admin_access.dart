import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';

/// Who counts as an administrator.
///
/// An account is an admin when a document `admins/{email}` exists (email in
/// lower case). The first admin is added once in the Firebase console; the
/// Firestore rules use the same check, so the admin portal's data is protected
/// even if someone opens the screen some other way.
class AdminAccess {
  AdminAccess._();

  static final Map<String, bool> _cache = {};

  /// Emails confirmed as admins. The app shell listens to this to give the
  /// admin portal a wide layout on tablets and the web.
  static final ValueNotifier<Set<String>> knownAdmins =
      ValueNotifier<Set<String>>(<String>{});

  static String key(String email) => email.trim().toLowerCase();

  /// Result of an earlier check for [user], or null if not checked yet.
  static bool? cached(User? user) {
    final email = user?.email;
    if (email == null) return false;
    return _cache[key(email)];
  }

  static bool isKnownAdmin(String? email) =>
      email != null && knownAdmins.value.contains(key(email));

  static Future<bool> isAdmin(User? user) async {
    final email = user?.email;
    if (email == null) return false;
    final k = key(email);
    final hit = _cache[k];
    if (hit != null) return hit;
    try {
      final doc = await FirebaseFirestore.instance
          .collection('admins')
          .doc(k)
          .get();
      _cache[k] = doc.exists;
      if (doc.exists) {
        knownAdmins.value = {...knownAdmins.value, k};
      }
      return doc.exists;
    } catch (e) {
      // Not cached: a network error should not lock an admin out for good.
      debugPrint('[AdminAccess] admin check failed: $e');
      return false;
    }
  }

  static void clearCache() {
    _cache.clear();
    knownAdmins.value = <String>{};
  }

  /// Records an admin action in `admin_logs` (who did what, to what, when).
  static Future<void> log(
    String action, {
    String? target,
    String? details,
  }) async {
    final by = FirebaseAuth.instance.currentUser?.email ?? 'admin';
    try {
      await FirebaseFirestore.instance.collection('admin_logs').add({
        'action': action,
        'target': target ?? '',
        'details': details ?? '',
        'by': key(by),
        'at': FieldValue.serverTimestamp(),
      });
    } catch (e) {
      debugPrint('[AdminAccess] log failed: $e');
    }
  }
}
