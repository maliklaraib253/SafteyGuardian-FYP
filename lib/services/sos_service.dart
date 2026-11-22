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

  static const String _lastFixKey = 'sos_last_location_fix';
  static const String noLocation = 'Location unavailable';

  /// Remembers a good position so an SOS can still send something useful
  /// when GPS can't get a fix (indoors, GPS just switched on, ...).
  static Future<void> _rememberFix(Position p) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        _lastFixKey,
        jsonEncode({
          'lat': p.latitude,
          'lng': p.longitude,
          'at': DateTime.now().millisecondsSinceEpoch,
        }),
      );
    } catch (_) {}
  }

  static String _mapsLink(double lat, double lng) =>
      'https://maps.google.com/?q=${lat.toStringAsFixed(6)},${lng.toStringAsFixed(6)}';

  static String _clock(DateTime t) {
    final tod = TimeOfDay.fromDateTime(t);
    final hh = tod.hourOfPeriod == 0 ? 12 : tod.hourOfPeriod;
    final mm = tod.minute.toString().padLeft(2, '0');
    return '$hh:$mm ${tod.period == DayPeriod.am ? 'AM' : 'PM'}';
  }

  /// Google Maps link to the user's position, trying in order:
  /// 1. a position Android got in the last 2 minutes (instant),
  /// 2. a precise GPS fix (up to 8 s),
  /// 3. a quick network / Wi-Fi position (up to 6 s; works indoors),
  /// 4. Android's last known position (any age),
  /// 5. the last position this app saved.
  /// An older position is marked with the time it was taken. Returns
  /// [noLocation] only when there is nothing at all.
  Future<String> getCurrentLocationLink() async {
    // Location services off or permission missing: say so in the log.
    try {
      if (!await Geolocator.isLocationServiceEnabled()) {
        debugPrint('📍 Location (GPS) is switched off on the phone');
      }
      final perm = await Geolocator.checkPermission();
      if (perm == LocationPermission.denied ||
          perm == LocationPermission.deniedForever) {
        debugPrint('📍 Location permission not granted');
      }
    } catch (_) {}

    // A fix from the last 2 minutes is good enough and costs no time.
    try {
      final recent = await Geolocator.getLastKnownPosition();
      if (recent != null &&
          DateTime.now().difference(recent.timestamp).inMinutes < 2) {
        return _mapsLink(recent.latitude, recent.longitude);
      }
    } catch (_) {}

    for (final settings in const [
      LocationSettings(
        accuracy: LocationAccuracy.high,
        timeLimit: Duration(seconds: 8),
      ),
      LocationSettings(
        accuracy: LocationAccuracy.low,
        timeLimit: Duration(seconds: 6),
      ),
    ]) {
      try {
        final p = await Geolocator.getCurrentPosition(
          locationSettings: settings,
        );
        await _rememberFix(p);
        return _mapsLink(p.latitude, p.longitude);
      } catch (e) {
        debugPrint('📍 ${settings.accuracy.name} fix failed: $e');
      }
    }

    try {
      final last = await Geolocator.getLastKnownPosition();
      if (last != null) {
        final age = DateTime.now().difference(last.timestamp);
        final link = _mapsLink(last.latitude, last.longitude);
        return age.inMinutes < 3
            ? link
            : '$link (last known at ${_clock(last.timestamp)})';
      }
    } catch (_) {}

    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_lastFixKey);
      if (raw != null) {
        final m = jsonDecode(raw) as Map<String, dynamic>;
        final at = DateTime.fromMillisecondsSinceEpoch(
          (m['at'] as num).toInt(),
        );
        return '${_mapsLink((m['lat'] as num).toDouble(), (m['lng'] as num).toDouble())}'
            ' (last known at ${_clock(at)})';
      }
    } catch (_) {}
    return noLocation;
  }

  /// When the first SOS text had no location, keep trying for 3 minutes and
  /// text the location as soon as the phone gets one.
  void _sendLocationWhenAvailable() {
    if (Platform.isIOS) return;
    unawaited(() async {
      for (var i = 0; i < 9 && _sessionActive; i++) {
        await Future.delayed(const Duration(seconds: 20));
        if (!_sessionActive) return;
        final link = await getCurrentLocationLink();
        if (link != noLocation) {
          await _textAll('SOS - my location now: $link - Safety Guardian');
          return;
        }
      }
    }());
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

    // The SIM itself refused the message (e.g. "code 16 - check SMS
    // balance"): remember it, the network is likely refusing paid traffic.
    if (!error!.contains('permission')) _simRefusals++;

    // Backup route: the telephony plugin's own sender.
    if (!error.contains('permission')) {
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

  // Static: the SOS keeps running when the SOS screen is closed and opened
  // again, and "I'm safe" on any screen must stop the same timers.
  static Timer? _locationTimer;
  static DateTime? _locationUpdatesStartedAt;
  static List<String> _sosPhones = [];

  // ---- No-response repeat ---------------------------------------------------

  /// If the user picks neither "Help needed" nor "I'm safe" for this long
  /// after an SOS round, the whole SOS is sent again (texts + calls).
  static const Duration noResponseRepeat = Duration(minutes: 5);

  /// Upper limit of automatic repeats (6 x 5 min = 30 min).
  static const int maxAutoRepeats = 6;

  static Timer? _repeatTimer;
  static int _autoRepeats = 0;
  static bool _sessionActive = false;
  static bool _cascadeRunning = false;
  static DateTime? _sosStartedAt;
  static List<Map<String, String>> _sessionContacts = [];
  // The service that started the SOS, so repeats report progress to the
  // same SOS screen.
  static SosService? _owner;
  // Police 15 already called in the current round (avoid dialling twice).
  static bool _policeCalledThisRound = false;
  // SMS the SIM itself refused in the current broadcast.
  static int _simRefusals = 0;
  // The SIM refused every SOS text: probably no balance.
  static bool _balanceProblem = false;

  /// True from the start of an SOS until "I'm safe" (also between repeats).
  static bool get sessionActive => _sessionActive;

  /// True while contacts / police are being called.
  static bool get cascadeRunning => _cascadeRunning;

  /// When the current SOS started.
  static DateTime? get startedAt => _sosStartedAt;

  /// When the next automatic repeat will happen (null = none scheduled).
  static final ValueNotifier<DateTime?> nextAutoRepeat = ValueNotifier(null);

  /// Fired when an automatic repeat starts (round number, 1-based).
  static void Function(int round)? onAutoRepeat;

  /// Fired when the app stops waiting for contacts and calls 15 because SMS
  /// or calls are failing (usually no balance or no signal).
  static void Function(String reason)? onPoliceFallback;

  static void _scheduleRepeat() {
    _repeatTimer?.cancel();
    if (!_sessionActive || _autoRepeats >= maxAutoRepeats) {
      nextAutoRepeat.value = null;
      return;
    }
    nextAutoRepeat.value = DateTime.now().add(noResponseRepeat);
    _repeatTimer = Timer(
      noResponseRepeat,
      () => (_owner ?? SosService())._repeatSos(),
    );
  }

  static void _cancelRepeat() {
    _repeatTimer?.cancel();
    _repeatTimer = null;
    nextAutoRepeat.value = null;
  }

  /// The user answered (e.g. "Help needed"): wait a full period again.
  static void userResponded() {
    if (_sessionActive) {
      _autoRepeats = 0;
      _scheduleRepeat();
    }
  }

  Future<void> _repeatSos() async {
    if (!_sessionActive) return;
    if (_cascadeRunning) {
      // Calls still in progress: check again a bit later.
      _repeatTimer = Timer(const Duration(minutes: 1), _repeatSos);
      return;
    }
    _autoRepeats++;
    _policeCalledThisRound = false;
    nextAutoRepeat.value = null;
    onAutoRepeat?.call(_autoRepeats);
    debugPrint('🔁 No response from user - repeating SOS (#$_autoRepeats)');
    _isSosActive = true;
    final link = await getCurrentLocationLink();
    final started = _sosStartedAt;
    final since = started == null
        ? ''
        : ' since ${started.hour.toString().padLeft(2, '0')}:'
              '${started.minute.toString().padLeft(2, '0')}';
    if (!Platform.isIOS && _sosPhones.isNotEmpty) {
      await _textAll(
        'EMERGENCY - NO RESPONSE: I have not confirmed I am safe$since. '
        'I may still be in danger. My location: $link - Safety Guardian',
      );
    }
    if (!isSharingLocation) startLocationUpdates();
    if (!_sessionActive) return;
    if (_sessionContacts.isEmpty) {
      await _escalateToPolice();
    } else {
      await _runSequentialCascade(_sessionContacts);
    }
    _isSosActive = false;
    _scheduleRepeat();
    onAutoRepeatDone?.call();
  }

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

  /// Returns false when another SOS was already running (nothing started).
  Future<bool> startSos({bool sequential = true}) async {
    if (_anySosRunning || _cascadeRunning) {
      debugPrint('SOS already running — ignoring duplicate start');
      return false;
    }
    _anySosRunning = true;
    _sessionActive = true;
    _sosStartedAt = DateTime.now();
    try {
      await _startSos();
    } finally {
      _anySosRunning = false;
    }
    return true;
  }

  /// Fired whenever a round of calls has finished (the first SOS round and
  /// every automatic repeat), so the SOS screen can ask "Are you safe?".
  static void Function()? onAutoRepeatDone;

  Future<void> _startSos() async {
    await loadContacts();

    // Permissions are normally granted on the home screen already; this only
    // asks if they were missed. SOS continues even if location is denied.
    await requestPermissions();

    _isSosActive = true;
    _sessionActive = true;
    _autoRepeats = 0;
    _sosStartedAt = DateTime.now();
    _owner = this;
    _policeCalledThisRound = false;
    _askedContactsToCallPolice = false;
    policeUnreached.value = false;
    _cancelRepeat();

    String locationLink = await getCurrentLocationLink();
    String sosMessage = locationLink == noLocation
        ? 'EMERGENCY! I need help. My location could not be found yet; '
              'I will send it as soon as my phone has it. - Safety Guardian'
        : 'EMERGENCY! I need help. My location: $locationLink - Safety Guardian';

    final validContacts = trustedContacts
        .where((c) => c['phone'] != null && c['phone']!.isNotEmpty)
        .toList();

    if (validContacts.isEmpty) {
      debugPrint(
        'No trusted contacts with phone numbers — calling 15 directly',
      );
      await _escalateToPolice();
      _isSosActive = false;
      _sessionContacts = [];
      _scheduleRepeat();
      onAutoRepeatDone?.call();
      return;
    }
    _sessionContacts = validContacts;

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
      _simRefusals = 0;
      final sent = await _textAll(sosMessage);
      // The SIM refused every SOS text (the backup sender's "sent" can't be
      // trusted then): almost always no balance or no signal.
      _balanceProblem =
          _sosPhones.isNotEmpty && _simRefusals >= _sosPhones.length;
      if (sent == 0 || _balanceProblem) {
        // Police 15 is an emergency number and works without balance, so
        // call it first instead of relying on contact calls that will play
        // an operator message instead of ringing.
        debugPrint('⚠️ SOS SMS refused by the SIM - calling Police 15 first');
        onPoliceFallback?.call(
          'Your SIM is refusing SMS (no balance or no signal). '
          'Calling Police 15 first, then your contacts.',
        );
        await _escalateToPolice();
      }
    }

    // 2. Keep contacts updated with the latest location.
    startLocationUpdates();
    if (locationLink == noLocation) _sendLocationWhenAvailable();

    // 3 + 4. Call every contact in order, then police.
    await _runSequentialCascade(validContacts);
    _isSosActive = false;

    // 5. No "Help needed" / "I'm safe" for a while: repeat the SOS.
    _scheduleRepeat();
    onAutoRepeatDone?.call();
  }

  /// Texts every SOS contact automatically. Returns how many were sent.
  Future<int> _textAll(String message) async {
    var sent = 0;
    for (final phone in _sosPhones) {
      try {
        if (await sendSms(phone, message)) sent++;
      } catch (e) {
        debugPrint('Failed to send SMS to $phone: $e');
      }
      if (_sosPhones.length > 1) {
        await Future.delayed(const Duration(seconds: 2));
      }
    }
    return sent;
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
      if (link == noLocation) return;
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
    _cascadeRunning = true;
    try {
      await _cascade(validContacts);
    } finally {
      _cascadeRunning = false;
    }
  }

  /// A call counts as "failed at once" when it never connected or ended
  /// within this time without talk: what happens with no balance.
  static const int _quickFailSeconds = 10;

  /// Talk time needed before a call counts as answered by a person.
  static const int _minTalkSeconds = 12;

  /// A person needs a few seconds of ringing before picking up. When the
  /// network "answers" at once (talk starts within this many seconds of the
  /// call starting) it is an operator message such as "insufficient
  /// balance" or "number switched off", not the contact.
  static const int _minRingSeconds = 4;

  Future<void> _cascade(List<Map<String, String>> validContacts) async {
    var quickFails = 0;
    for (var i = 0; i < validContacts.length; i++) {
      if (!_isSosActive || !_sessionActive) return;
      final contact = validContacts[i];
      debugPrint('Calling ${contact['name']} - ${contact['phone']}');
      onCalling?.call(i);
      final since = DateTime.now().millisecondsSinceEpoch;
      await makeCall(contact['phone']!);
      final outcome = await _waitForCallOutcome(contact['phone']!, since);
      final answered = outcome.answered && !_balanceProblem;
      onCallResult?.call(i, answered);
      if (!answered &&
          (outcome.operator ||
              (outcome.seconds >= 0 && outcome.seconds < _quickFailSeconds))) {
        quickFails++;
        // Two calls in a row cut off at once (or the only contact): the SIM
        // can't make normal calls, most likely no balance. Call 15 straight
        // away, then still try every remaining contact.
        if ((quickFails >= 2 || validContacts.length == 1) &&
            !_policeCalledThisRound) {
          debugPrint('⚠️ Calls are failing at once (no balance?) - calling 15');
          onPoliceFallback?.call(
            'Calls are not going through (no balance or no signal). '
            'Calling Police 15, then the remaining contacts.',
          );
          await _escalateToPolice();
        }
      } else {
        quickFails = 0;
      }
      if (outcome.answered && _balanceProblem) {
        // With no balance the operator "connects" the call only to play its
        // recorded message, which looks like talk time. Don't trust it: keep
        // calling the other contacts.
        debugPrint(
          '⚠️ ${contact['name']}: talk time seen but balance looks empty - '
          'not counting as answered',
        );
      } else if (answered) {
        // A person now knows about the emergency: stop calling. SOS stays
        // active (location updates keep going) until the user is safe.
        debugPrint('✅ ${contact['name']} answered - stopping call sequence');
        onContactReached?.call(i);
        return;
      }
      if (!_isSosActive) return;
      // Never dial the next contact over a call that is still going on.
      for (var t = 0; t < 60 && await _inCall(); t++) {
        await Future.delayed(const Duration(seconds: 1));
      }
      await Future.delayed(const Duration(seconds: 3));
    }
    if (_isSosActive) {
      await _escalateToPolice();
    }
  }

  Future<bool> _inCall() async {
    try {
      return await _smsChannel.invokeMethod<bool>('isInCall') ?? false;
    } catch (_) {
      return false;
    }
  }

  /// Talk seconds from the call log for the call placed after [since];
  /// -1 while the call is not in the log yet (still ringing or talking) or
  /// when the log can't be read.
  Future<int> _loggedTalk(String phone, int since) async {
    try {
      return await _smsChannel.invokeMethod<int>('lastCallDuration', {
            'phone': phone,
            'since': since,
          }) ??
          -1;
    } catch (_) {
      return -1;
    }
  }

  /// Waits for the call just placed to finish and reports whether the contact
  /// answered and how long the call lasted ([seconds] is -1 when the length
  /// is unknown). The next contact is never dialled while a call is still on.
  Future<({bool answered, int seconds, bool operator, bool placed})>
  _waitForCallOutcome(String phone, int since) async {
    if (Platform.isIOS) {
      // iOS gives apps no call state: keep the old 30 s spacing.
      await Future.delayed(const Duration(seconds: 30));
      return (answered: false, seconds: -1, operator: false, placed: true);
    }

    // 1. Wait up to 15 s for the call to show up as started.
    var started = false;
    for (var t = 0; t < 15; t++) {
      if (await _inCall()) {
        started = true;
        break;
      }
      await Future.delayed(const Duration(seconds: 1));
    }

    if (started) {
      // 2a. Wait until the call ends (rings out, rejected or talk is over).
      final startedAt = DateTime.now();
      while (await _inCall()) {
        if (DateTime.now().difference(startedAt) >
            const Duration(minutes: 30)) {
          break;
        }
        await Future.delayed(const Duration(seconds: 1));
      }
      final callSeconds = DateTime.now().difference(startedAt).inSeconds;
      // The call log is written a moment after the call ends.
      var talk = -1;
      for (var t = 0; t < 5 && talk < 0; t++) {
        await Future.delayed(const Duration(seconds: 1));
        talk = await _loggedTalk(phone, since);
      }
      debugPrint('📞 $phone: call lasted ${callSeconds}s, talk ${talk}s');
      if (talk >= 0) {
        // Pakistani networks often "connect" a call just to play a recorded
        // message (switched off, not answering, busy), which the call log
        // stores as a few seconds of talk. Only a real conversation counts.
        final ring = callSeconds - talk;
        final person = talk >= _minTalkSeconds && ring >= _minRingSeconds;
        if (talk >= _minTalkSeconds && !person) {
          debugPrint(
            '📞 $phone: answered after only ${ring}s of ringing - operator '
            'message (no balance / switched off), not the contact',
          );
        }
        return (
          answered: person,
          seconds: callSeconds,
          operator: talk >= _minTalkSeconds && !person,
          placed: true,
        );
      }
      // No call-log access: a call that lasted over 45 s was almost certainly
      // answered (unanswered calls ring out sooner on Pakistani networks).
      return (
        answered: callSeconds > 45,
        seconds: callSeconds,
        operator: false,
        placed: true,
      );
    }

    // 2b. The phone did not report the call (no phone-state access, or the
    // dialer opened instead). Use the call log: an entry appears only when
    // the call has ended. Wait up to 75 s (a ringing call ends by then).
    debugPrint('📞 $phone: call state unknown - watching the call log');
    for (var t = 0; t < 75; t++) {
      final talk = await _loggedTalk(phone, since);
      if (talk >= 0) {
        debugPrint('📞 $phone: call log says talk ${talk}s');
        return (
          answered: talk >= _minTalkSeconds,
          seconds: -1,
          operator: false,
          placed: true,
        );
      }
      // Call state started working after all: go back to the normal wait.
      if (t > 3 && await _inCall()) {
        while (await _inCall()) {
          await Future.delayed(const Duration(seconds: 1));
        }
      }
      await Future.delayed(const Duration(seconds: 1));
    }
    // Nothing readable at all: keep the old 30 s spacing between calls.
    debugPrint('📞 $phone: no call information - moving on');
    return (answered: false, seconds: -1, operator: false, placed: false);
  }

  /// "Help Needed" after the call sequence: tell every contact again and call
  /// Police 15 straight away.
  Future<void> escalateHelpNeeded() async {
    _isSosActive = true;
    _sessionActive = true;
    // The user answered: start a fresh no-response period after this.
    _cancelRepeat();
    final link = await getCurrentLocationLink();
    if (!Platform.isIOS && _sosPhones.isNotEmpty) {
      await _textAll('I STILL NEED HELP. Calling police. My location: $link');
      if (!isSharingLocation) startLocationUpdates();
    }
    onCalling?.call(-1);
    await makeCall('15');
    userResponded();
  }

  /// Calls Pakistan Police emergency (15) after all trusted contacts have
  /// been tried. 15 is a voice helpline, so no SMS is sent to it.
  Future<void> _escalateToPolice() async {
    if (!_isSosActive || !_sessionActive || _policeCalledThisRound) return;
    _policeCalledThisRound = true;
    debugPrint('⚠️ All contacts tried — calling Police 15');
    onCalling?.call(-1);
    final since = DateTime.now().millisecondsSinceEpoch;
    await makeCall('15');
    if (Platform.isIOS) return;
    // Wait for the police call to end before asking "Are you safe?".
    final outcome = await _waitForCallOutcome('15', since);
    if (outcome.placed) {
      policeUnreached.value = false;
      return;
    }
    // Android only opened the dialer and nobody pressed Call (the user may
    // not be able to). Ask the trusted contacts to call 15 instead.
    debugPrint('⚠️ Police 15 was not called - asking contacts to call 15');
    policeUnreached.value = true;
    onPoliceFallback?.call(
      'Police 15 was not called. Your contacts have been asked to call 15 '
      'for you. Tap "Call 15" if you can.',
    );
    if (_sosPhones.isNotEmpty && !_askedContactsToCallPolice) {
      _askedContactsToCallPolice = true;
      final link = await getCurrentLocationLink();
      await _textAll(
        'I could NOT reach Police 15. Please call 15 for me and tell them '
        'my location: ${link == noLocation ? 'not found yet' : link} '
        '- Safety Guardian',
      );
    }
  }

  /// True while an SOS is on and the app could not get a call through to
  /// Police 15 (the SOS screen then shows a big "Call 15" button).
  static final ValueNotifier<bool> policeUnreached = ValueNotifier(false);

  /// Contacts are asked to call 15 for the user only once per SOS.
  static bool _askedContactsToCallPolice = false;

  /// Lets the SOS screen report that 15 was called by hand.
  static void policeCalledManually() => policeUnreached.value = false;

  void stopSos() {
    _isSosActive = false;
    _anySosRunning = false;
    _sessionActive = false;
    _askedContactsToCallPolice = false;
    policeUnreached.value = false;
    _autoRepeats = 0;
    _sessionContacts = [];
    _owner = null;
    _balanceProblem = false;
    _cancelRepeat();
    stopLocationUpdates();
  }
}
