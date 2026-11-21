import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:phone_state/phone_state.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'sos_service.dart';

/// Auto-rejects incoming calls while Emergency SOS is active.
///
/// * Calls from trusted SOS contacts are let through (they may be calling back).
/// * Every other incoming call is ended through the native
///   `com.safetyguardian/call_guard` channel (TelecomManager.endCall, Android 9+)
///   and the caller gets one automated SMS per SOS session.
/// * iOS does not allow apps to reject calls, so the service is a no-op there.
class CallHandlerService {
  static const MethodChannel _callGuard = MethodChannel(
    'com.safetyguardian/call_guard',
  );

  /// SharedPreferences key holding the status sent in auto-reply SMS.
  static const String autoReplyStatusKey = 'auto_reply_status';

  /// SharedPreferences key for the user setting (Settings → Emergency).
  static const String autoRejectEnabledKey = 'auto_reject_calls_enabled';

  StreamSubscription<PhoneState>? _phoneStateSubscription;

  bool _isEmergencyActive = false;
  Set<String> _allowedNumbers = {};
  final Set<String> _repliedThisSession = {};

  /// Called for every rejected call so the UI can show a counter/log.
  void Function(String number)? onCallRejected;

  /// Called when a trusted contact calls back during SOS.
  void Function(String number)? onTrustedCallAllowed;

  static bool get isSupported => !kIsWeb && Platform.isAndroid;

  static Future<bool> isEnabledInSettings() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(autoRejectEnabledKey) ?? true;
  }

  static Future<void> setEnabledInSettings(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(autoRejectEnabledKey, value);
  }

  /// Requests READ_PHONE_STATE / READ_CALL_LOG / ANSWER_PHONE_CALLS (phone group).
  static Future<bool> ensurePermissions() async {
    if (!isSupported) return false;
    final status = await Permission.phone.request();
    return status.isGranted;
  }

  /// Normalises Pakistani numbers so 0300…, +92300… and 92300… compare equal.
  static String normalizeNumber(String raw) {
    var digits = raw.replaceAll(RegExp(r'[^\d]'), '');
    if (digits.startsWith('0092')) digits = digits.substring(4);
    if (digits.startsWith('92') && digits.length > 10)
      digits = digits.substring(2);
    if (digits.startsWith('0')) digits = digits.substring(1);
    return digits;
  }

  /// Starts listening for incoming calls.
  ///
  /// [trustedNumbers] are never rejected.
  Future<void> startListening(
    bool isEmergencyActive, {
    List<String> trustedNumbers = const [],
  }) async {
    _isEmergencyActive = isEmergencyActive;
    _allowedNumbers = trustedNumbers
        .map(normalizeNumber)
        .where((n) => n.isNotEmpty)
        .toSet();
    _repliedThisSession.clear();

    if (!isSupported) {
      debugPrint('[CallHandler] Auto-reject is not available on this platform');
      return;
    }
    if (!await isEnabledInSettings()) {
      debugPrint('[CallHandler] Auto-reject disabled in settings');
      return;
    }

    await ensurePermissions();

    await _phoneStateSubscription?.cancel();
    _phoneStateSubscription = PhoneState.stream.listen((event) async {
      if (event.status != PhoneStateStatus.CALL_INCOMING) return;
      if (!_isEmergencyActive) return;
      await _handleIncomingCall(event.number);
    });
  }

  void stopListening() {
    _phoneStateSubscription?.cancel();
    _phoneStateSubscription = null;
    _isEmergencyActive = false;
  }

  void setEmergencyMode(bool active) {
    _isEmergencyActive = active;
  }

  Future<void> _handleIncomingCall(String? number) async {
    final normalized = number == null ? '' : normalizeNumber(number);

    if (normalized.isNotEmpty && _allowedNumbers.contains(normalized)) {
      debugPrint(
        '[CallHandler] Trusted contact calling back – allowing $number',
      );
      onTrustedCallAllowed?.call(number!);
      return;
    }

    bool rejected = false;
    try {
      rejected = await _callGuard.invokeMethod<bool>('endCall') ?? false;
    } catch (e) {
      debugPrint('[CallHandler] endCall failed: $e');
    }
    debugPrint(
      '[CallHandler] Incoming call from ${number ?? 'unknown'} – rejected: $rejected',
    );
    if (rejected) onCallRejected?.call(number ?? 'Unknown number');

    if (normalized.isNotEmpty && !_repliedThisSession.contains(normalized)) {
      _repliedThisSession.add(normalized);
      await _sendAutoReply(number!);
    }
  }

  Future<void> _sendAutoReply(String number) async {
    // Neutral on purpose: the caller may be the person the user is in danger
    // from, so never reveal that an SOS or "Help Needed" status is active.
    const message = "Sorry, I can't talk right now. I'll call you back.";
    try {
      final sent = await SosService().sendSms(number, message);
      debugPrint('[CallHandler] Auto-reply SMS to $number sent: $sent');
    } catch (e) {
      debugPrint('[CallHandler] Failed to send auto-reply to $number: $e');
    }
  }
}
