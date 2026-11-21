import 'dart:async';

import 'package:flutter/material.dart' show TimeOfDay, DayPeriod;
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show MethodChannel;
import 'package:url_launcher/url_launcher.dart';
import 'package:another_telephony/telephony.dart';
import 'package:geolocator/geolocator.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:direct_caller_sim_choice/direct_caller_sim_choice.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';

import 'dart:convert';
import 'dart:io' show Platform;

class SosService {
  final Telephony telephony = Telephony.instance;
  final DirectCaller directCaller = DirectCaller();

  List<Map<String, String>> trustedContacts = [];

  bool _isSosActive = false;

  /// Helper to get a storage key scoped to the currently logged in user
  String _getStorageKey() {
    final user = FirebaseAuth.instance.currentUser;
    if (user != null && user.uid.isNotEmpty) {
      return 'trusted_contacts_${user.uid}';
    }
    return 'trusted_contacts_guest';
  }

  /// Checks if a contact matches the old hardcoded dummy placeholder contacts
  bool _isDummyContact(Map<String, dynamic> c) {
    final name = (c['name'] ?? '').toString().trim().toLowerCase();
    final rawPhone = (c['phone'] ?? '').toString().replaceAll(
      RegExp(r'[^\d]'),
      '',
    );
    const dummyPhones = {
      '03001234567',
      '03217654321',
      '03459876543',
      '923001234567',
      '923217654321',
      '923459876543',
    };
    if (dummyPhones.contains(rawPhone)) {
      if (name == 'mother' || name == 'father' || name == 'brother') {
        return true;
      }
    }
    return false;
  }

  // Load contacts from storage (scoped by user account)
  Future<void> loadContacts() async {
    final user = FirebaseAuth.instance.currentUser;
    final key = _getStorageKey();
    SharedPreferences prefs = await SharedPreferences.getInstance();

    // Clean up legacy global dummy contacts if previously set
    if (prefs.containsKey('trusted_contacts')) {
      final oldJson = prefs.getString('trusted_contacts');
      if (oldJson != null) {
        try {
          List<dynamic> oldList = jsonDecode(oldJson);
          final filteredOld = oldList
              .where((e) => !_isDummyContact(Map<String, dynamic>.from(e)))
              .toList();
          if (filteredOld.isEmpty) {
            await prefs.remove('trusted_contacts');
          }
        } catch (_) {}
      }
    }

    String? contactsJson = prefs.getString(key);

    if (contactsJson != null) {
      try {
        List<dynamic> decoded = jsonDecode(contactsJson);
        trustedContacts = decoded
            .map((e) => Map<String, String>.from(e))
            .where((c) => !_isDummyContact(c))
            .toList();
      } catch (e) {
        debugPrint('Error decoding contacts: $e');
        trustedContacts = [];
      }
    } else {
      trustedContacts = [];
    }

    // If user is logged in, sync with user document in Firestore
    if (user != null) {
      try {
        final doc = await FirebaseFirestore.instance
            .collection('users')
            .doc(user.uid)
            .get();
        if (doc.exists &&
            doc.data() != null &&
            doc.data()!.containsKey('trustedContacts')) {
          final raw = doc.data()!['trustedContacts'];
          if (raw is List) {
            trustedContacts = raw
                .map(
                  (e) => Map<String, String>.from(
                    Map<String, dynamic>.from(e as Map),
                  ),
                )
                .where((c) => !_isDummyContact(c))
                .toList();
            await prefs.setString(key, jsonEncode(trustedContacts));
          }
        }
      } catch (e) {
        debugPrint('Note: Could not sync contacts from Firestore: $e');
      }
    }
    // New accounts stay empty by default; no dummy contacts are ever added.
  }

  // Save contacts to storage
  Future<void> saveContacts() async {
    final user = FirebaseAuth.instance.currentUser;
    final key = _getStorageKey();
    SharedPreferences prefs = await SharedPreferences.getInstance();
    String contactsJson = jsonEncode(trustedContacts);
    await prefs.setString(key, contactsJson);

    // Sync to Firestore for logged in user
    if (user != null) {
      try {
        await FirebaseFirestore.instance.collection('users').doc(user.uid).set({
          'trustedContacts': trustedContacts,
        }, SetOptions(merge: true));
      } catch (e) {
        debugPrint('Note: Could not sync contacts to Firestore: $e');
      }
    }
  }

  // Clear contacts for current account
  Future<void> clearContacts() async {
    final user = FirebaseAuth.instance.currentUser;
    final key = _getStorageKey();
    SharedPreferences prefs = await SharedPreferences.getInstance();
    trustedContacts.clear();
    await prefs.remove(key);

    if (user != null) {
      try {
        await FirebaseFirestore.instance.collection('users').doc(user.uid).set({
          'trustedContacts': [],
        }, SetOptions(merge: true));
      } catch (e) {
        debugPrint('Note: Could not clear contacts from Firestore: $e');
      }
    }
  }

  // Add new contact
  Future<void> addContact(String name, String phone) async {
    trustedContacts.add({'name': name, 'phone': phone});
    await saveContacts();
  }

  // Remove contact
  Future<void> removeContact(int index) async {
    trustedContacts.removeAt(index);
    await saveContacts();
  }

  // Update contact
  Future<void> updateContact(int index, String name, String phone) async {
    trustedContacts[index] = {'name': name, 'phone': phone};
    await saveContacts();
  }

  // Reorder contacts (drag and drop)
  Future<void> reorderContacts(int oldIndex, int newIndex) async {
    if (oldIndex < newIndex) {
      newIndex -= 1;
    }
    final item = trustedContacts.removeAt(oldIndex);
    trustedContacts.insert(newIndex, item);
    await saveContacts();
  }

  Future<bool> requestPermissions() async {
    // iOS has no phone/SMS runtime permissions (calls and SMS go through the
    // system dialer / Messages app), so only location is required there.
    if (Platform.isIOS) {
      await Permission.locationWhenInUse.request();
      return true;
    }
    await Permission.phone.request();
    await Permission.sms.request();
    await Permission.location.request();

    return await Permission.phone.isGranted &&
        await Permission.sms.isGranted &&
        await Permission.location.isGranted;
  }

  /// Google Maps link to the current position. Never blocks SOS for long:
  /// waits at most 8 s for a fresh fix, then uses the last known position.
  Future<String> getCurrentLocationLink() async {
    String link(Position p) =>
        'https://maps.google.com/?q=${p.latitude.toStringAsFixed(6)},${p.longitude.toStringAsFixed(6)}';
    try {
      final p = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high,
          timeLimit: Duration(seconds: 8),
        ),
      );
      return link(p);
    } catch (e) {
      debugPrint('Fresh location failed ($e) - using last known position');
    }
    try {
      final last = await Geolocator.getLastKnownPosition();
      if (last != null) return link(last);
    } catch (_) {}
    return 'Location unavailable';
  }

  Future<void> makeCall(String phoneNumber) async {
    if (phoneNumber.isEmpty) {
      debugPrint('No phone number provided');
      return;
    }
    // Try a direct auto-dial first (works on most devices for normal numbers
    // and on some Samsung builds for emergency numbers like 15). If Android
    // blocks the direct call (typical for emergency numbers on stock builds),
    // fall back to opening the dialer with the number pre-filled.
    // iOS never allows silent auto-dialing: open the call prompt instead.
    if (Platform.isIOS) {
      final telUri = Uri(
        scheme: 'tel',
        path: phoneNumber.replaceAll(RegExp(r'[^\d+]'), ''),
      );
      await launchUrl(telUri, mode: LaunchMode.externalApplication);
      return;
    }
    // 1. Native call through the SIM Android actually uses (dual-SIM aware).
    try {
      final error = await _smsChannel.invokeMethod<String?>('call', {
        'phone': phoneNumber,
      });
      if (error == null) {
        debugPrint('📞 Calling $phoneNumber');
        return;
      }
      debugPrint('❌ Native call failed for $phoneNumber: $error');
    } catch (e) {
      debugPrint('❌ Native call error for $phoneNumber: $e');
    }
    // 2. Fallback: open the dialer with the number filled in.
    // (The old direct_caller plugin is not used: it dials a fixed SIM slot,
    // which fails with "can't connect to mobile network" when the only SIM
    // is in the other slot.)
    final telUri = Uri(scheme: 'tel', path: phoneNumber);
    if (await canLaunchUrl(telUri)) {
      await launchUrl(telUri);
    }
  }

  static const MethodChannel _smsChannel = MethodChannel(
    'com.safetyguardian/sms',
  );

  /// Called after each SMS attempt: phone, whether it was sent, error text.
  /// The SOS screen uses this to show which texts failed and why.
  void Function(String phone, bool sent, String? error)? onSmsResult;

  /// Sends an SMS automatically. Returns true if it went out.
  ///
  /// Android: sent directly through the SIM with no user interaction. The
  /// native side tries the default SMS SIM, then the other SIM; if both fail
  /// it waits 5 s and tries once more (signal often comes back).
  /// iOS: Apple does not allow apps to send SMS silently, so Messages opens
  /// with the text ready.
  Future<bool> sendSms(String phoneNumber, String message) async {
    final cleanPhone = phoneNumber.replaceAll(RegExp(r'[^\d+]'), '');
    if (cleanPhone.isEmpty) {
      debugPrint('❌ Empty phone number provided for SMS');
      return false;
    }

    if (Platform.isIOS) {
      final uri = Uri.parse(
        'sms:$cleanPhone&body=${Uri.encodeComponent(message)}',
      );
      return launchUrl(uri, mode: LaunchMode.externalApplication);
    }

    String? error;
    for (var attempt = 1; attempt <= 2; attempt++) {
      try {
        final res = await _smsChannel.invokeMapMethod<String, dynamic>(
          'sendSms',
          {'phone': cleanPhone, 'message': message},
        );
        if (res?['ok'] == true) {
          debugPrint('✅ SMS sent to $cleanPhone');
          onSmsResult?.call(cleanPhone, true, null);
          return true;
        }
        error = (res?['error'] ?? 'unknown error').toString();
      } catch (e) {
        error = e.toString();
      }
      debugPrint('❌ SMS to $cleanPhone failed (attempt $attempt): $error');
      if (error.contains('permission')) break; // retrying won't help
      if (attempt == 1) await Future.delayed(const Duration(seconds: 5));
    }

    // Backup route: the telephony plugin's own sender.
    if (!error!.contains('permission')) {
      final viaPlugin = await _sendViaPlugin(cleanPhone, message);
      if (viaPlugin) {
        debugPrint('✅ SMS sent to $cleanPhone (backup sender)');
        onSmsResult?.call(cleanPhone, true, null);
        return true;
      }
    }
    onSmsResult?.call(cleanPhone, false, error);
    return false;
  }

  /// Sends through the another_telephony plugin and waits up to 15 s for the
  /// network's "sent" report.
  Future<bool> _sendViaPlugin(String phone, String message) async {
    final done = Completer<bool>();
    try {
      await telephony.sendSms(
        to: phone,
        message: message,
        isMultipart: message.length > 160,
        statusListener: (status) {
          debugPrint('Backup SMS status for $phone: $status');
          if (done.isCompleted) return;
          if (status == SendStatus.SENT || status == SendStatus.DELIVERED) {
            done.complete(true);
          }
        },
      );
    } catch (e) {
      debugPrint('Backup SMS sender failed for $phone: $e');
      return false;
    }
    return done.future.timeout(
      const Duration(seconds: 15),
      onTimeout: () => false,
    );
  }

  /// Index of the contact currently being called (0-based), or -1 while
  /// calling police 15. Lets the SOS screen show live call progress.
  void Function(int index)? onCalling;

  /// Result of each contact call: [answered] is true when the call log shows
  /// talk time (the contact picked up). index -1 = police.
  void Function(int index, bool answered)? onCallResult;

  /// Fired once a trusted contact has answered; calling stops there.
  void Function(int index)? onContactReached;

  /// How often an updated location is texted to contacts during SOS.
  static const Duration locationUpdateInterval = Duration(minutes: 2);

  /// Location updates stop on their own after this long (safety cap in case
  /// the user never taps "I'm safe").
  static const Duration locationUpdateMaxDuration = Duration(minutes: 30);

  Timer? _locationTimer;
  DateTime? _locationUpdatesStartedAt;
  List<String> _sosPhones = [];

  bool get isSharingLocation => _locationTimer != null;

  /// Starts the SOS flow (same for the SOS button, distress detection and
  /// companion mode):
  /// 1. texts the SOS + live location to ALL trusted contacts,
  /// 2. starts texting an updated location every 2 minutes,
  /// 3. calls every trusted contact in saved order, 30 s each,
  /// 4. calls Police 15 if SOS is still active after the last contact.
  ///
  /// [sequential] is kept for existing callers; every SOS is sequential now.
  /// True while any SOS is running (shared by every SosService instance),
  /// so the SOS button, distress detection and companion mode can never run
  /// two SOS flows at the same time and double-text contacts.
  static bool _anySosRunning = false;

  /// True while an SOS is in progress anywhere in the app.
  static bool get anySosRunning => _anySosRunning;

  Future<void> startSos({bool sequential = true}) async {
    if (_anySosRunning) {
      debugPrint('SOS already running — ignoring duplicate start');
      return;
    }
    _anySosRunning = true;
    try {
      await _startSos();
    } finally {
      _anySosRunning = false;
    }
  }

  Future<void> _startSos() async {
    await loadContacts();

    // Permissions are normally granted on the home screen already; this only
    // asks if they were missed. SOS continues even if location is denied.
    await requestPermissions();

    _isSosActive = true;

    String locationLink = await getCurrentLocationLink();
    String sosMessage =
        'EMERGENCY! I need help. My location: $locationLink - Safety Guardian';

    final validContacts = trustedContacts
        .where((c) => c['phone'] != null && c['phone']!.isNotEmpty)
        .toList();

    if (validContacts.isEmpty) {
      debugPrint(
        'No trusted contacts with phone numbers — calling 15 directly',
      );
      await _escalateToPolice();
      _isSosActive = false;
      return;
    }

    _sosPhones = validContacts
        .map((c) => c['phone']!.replaceAll(RegExp(r'[^\d+]'), ''))
        .where((p) => p.isNotEmpty)
        .toList();

    // 1. Immediately broadcast SOS SMS to ALL trusted contacts.
    if (Platform.isIOS) {
      // One group message (iOS can only open Messages, not send silently).
      try {
        await launchUrl(
          Uri.parse(
            'sms:/open?addresses=${_sosPhones.join(',')}&body=${Uri.encodeComponent(sosMessage)}',
          ),
          mode: LaunchMode.externalApplication,
        );
      } catch (e) {
        debugPrint('iOS group SMS failed: $e');
      }
    } else {
      debugPrint(
        '🚨 Broadcasting SOS SMS to ALL ${_sosPhones.length} trusted contact(s)...',
      );
      await _textAll(sosMessage);
    }

    // 2. Keep contacts updated with the latest location.
    startLocationUpdates();

    // 3 + 4. Call every contact in order, then police.
    await _runSequentialCascade(validContacts);
    _isSosActive = false;
  }

  /// Texts every SOS contact automatically.
  Future<void> _textAll(String message) async {
    for (final phone in _sosPhones) {
      try {
        await sendSms(phone, message);
      } catch (e) {
        debugPrint('Failed to send SMS to $phone: $e');
      }
      if (_sosPhones.length > 1) {
        await Future.delayed(const Duration(seconds: 2));
      }
    }
  }

  /// Texts the current location to every SOS contact every 2 minutes.
  /// Android only: iOS cannot send SMS in the background, and opening
  /// Messages every 2 minutes would get in the user's way.
  void startLocationUpdates() {
    if (Platform.isIOS || _sosPhones.isEmpty) return;
    _locationTimer?.cancel();
    _locationUpdatesStartedAt = DateTime.now();
    _locationTimer = Timer.periodic(locationUpdateInterval, (_) async {
      final started = _locationUpdatesStartedAt;
      if (started != null &&
          DateTime.now().difference(started) > locationUpdateMaxDuration) {
        stopLocationUpdates();
        return;
      }
      final link = await getCurrentLocationLink();
      if (link == 'Location unavailable') return;
      final time = TimeOfDay.fromDateTime(DateTime.now());
      final hh = time.hourOfPeriod == 0 ? 12 : time.hourOfPeriod;
      final mm = time.minute.toString().padLeft(2, '0');
      final ampm = time.period == DayPeriod.am ? 'AM' : 'PM';
      await _textAll('SOS location update $hh:$mm $ampm: $link');
    });
  }

  void stopLocationUpdates() {
    _locationTimer?.cancel();
    _locationTimer = null;
    _locationUpdatesStartedAt = null;
  }

  Future<void> _runSequentialCascade(
    List<Map<String, String>> validContacts,
  ) async {
    for (var i = 0; i < validContacts.length; i++) {
      if (!_isSosActive) return;
      final contact = validContacts[i];
      debugPrint('Calling ${contact['name']} - ${contact['phone']}');
      onCalling?.call(i);
      final since = DateTime.now().millisecondsSinceEpoch;
      await makeCall(contact['phone']!);
      final answered = await _waitForCallOutcome(contact['phone']!, since);
      onCallResult?.call(i, answered);
      if (answered) {
        // A person now knows about the emergency: stop calling. SOS stays
        // active (location updates keep going) until the user is safe.
        debugPrint('✅ ${contact['name']} answered - stopping call sequence');
        onContactReached?.call(i);
        return;
      }
      if (!_isSosActive) return;
      await Future.delayed(const Duration(seconds: 3));
    }
    if (_isSosActive) {
      await _escalateToPolice();
    }
  }

  /// Waits for the call just placed to finish and reports whether the contact
  /// answered. Never cuts a call short: if the contact picks up, the user can
  /// talk for as long as needed before the next step.
  Future<bool> _waitForCallOutcome(String phone, int since) async {
    if (Platform.isIOS) {
      // iOS gives apps no call state: keep the old 30 s spacing.
      await Future.delayed(const Duration(seconds: 30));
      return false;
    }
    Future<bool> inCall() async {
      try {
        return await _smsChannel.invokeMethod<bool>('isInCall') ?? false;
      } catch (_) {
        return false;
      }
    }

    // 1. Wait up to 15 s for the call to actually start.
    var started = false;
    for (var t = 0; t < 15; t++) {
      if (await inCall()) {
        started = true;
        break;
      }
      await Future.delayed(const Duration(seconds: 1));
    }
    if (!started) {
      // Dialer fallback or call blocked: give the user time to tap Call.
      await Future.delayed(const Duration(seconds: 15));
      if (!await inCall()) return false;
    }

    // 2. Wait until the call ends (rings out, rejected, or conversation over).
    final startedAt = DateTime.now();
    while (await inCall()) {
      if (DateTime.now().difference(startedAt) > const Duration(minutes: 30)) {
        break;
      }
      await Future.delayed(const Duration(seconds: 1));
    }
    final callSeconds = DateTime.now().difference(startedAt).inSeconds;

    // 3. Ask the call log whether there was talk time.
    await Future.delayed(const Duration(seconds: 2)); // log is written late
    try {
      final talk = await _smsChannel.invokeMethod<int>('lastCallDuration', {
        'phone': phone,
        'since': since,
      });
      if (talk != null && talk >= 0) return talk > 0;
    } catch (_) {}
    // No call-log access: a call that lasted over 45 s was almost certainly
    // answered (unanswered calls ring out sooner on Pakistani networks).
    return callSeconds > 45;
  }

  /// "Help Needed" after the call sequence: tell every contact again and call
  /// Police 15 straight away.
  Future<void> escalateHelpNeeded() async {
    _isSosActive = true;
    final link = await getCurrentLocationLink();
    if (!Platform.isIOS && _sosPhones.isNotEmpty) {
      await _textAll('I STILL NEED HELP. Calling police. My location: $link');
      if (!isSharingLocation) startLocationUpdates();
    }
    onCalling?.call(-1);
    await makeCall('15');
  }

  /// Calls Pakistan Police emergency (15) after all trusted contacts have
  /// been tried. 15 is a voice helpline, so no SMS is sent to it.
  Future<void> _escalateToPolice() async {
    if (!_isSosActive) return;
    debugPrint('⚠️ All contacts tried — calling Police 15');
    onCalling?.call(-1);
    await makeCall('15');
  }

  void stopSos() {
    _isSosActive = false;
    _anySosRunning = false;
    stopLocationUpdates();
  }
}
