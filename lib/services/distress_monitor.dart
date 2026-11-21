import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:sensors_plus/sensors_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'sos_service.dart';
import 'voice_distress_service.dart';

/// One reading from the accelerometer, for the Distress Detection screen.
class MotionReading {
  final double intensity; // 0..1
  final String activity;
  const MotionReading(this.intensity, this.activity);
}

/// App-wide distress detection.
///
/// Runs for the whole app, not just while the Distress Detection screen is
/// open: it keeps listening (voice + motion) when the user goes to another
/// screen, switches to another app, turns the screen off, or closes the app.
/// A foreground service (the permanent "Safety Guardian is protecting you"
/// notification) keeps the process alive, and the Android activity keeps the
/// Flutter engine running after the app is closed (see SafetyGuardianActivity).
///
/// When distress is detected it wakes the screen, brings the app to the front
/// and shows the "Are you safe?" countdown; if nobody answers, SOS starts.
class DistressMonitor {
  DistressMonitor._();
  static final DistressMonitor instance = DistressMonitor._();

  static const String enabledKey = 'distress_detection_always_on';
  static const String voiceKey = 'distress_voice_enabled';
  static const String _batteryAskedKey = 'distress_battery_exemption_asked';

  /// Used to show the alert from anywhere in the app (set on MaterialApp).
  final GlobalKey<NavigatorState> navigatorKey = GlobalKey<NavigatorState>();

  final VoiceDistressService voice = VoiceDistressService();

  bool _running = false;
  bool _voiceEnabled = true;
  bool _alertOpen = false;
  DateTime _lastTrigger = DateTime.fromMillisecondsSinceEpoch(0);

  StreamSubscription<AccelerometerEvent>? _accelSub;
  StreamSubscription<VoiceDistressResult>? _voiceSub;

  final StreamController<MotionReading> _motion =
      StreamController<MotionReading>.broadcast();
  final StreamController<String> _log = StreamController<String>.broadcast();

  bool get isRunning => _running;
  bool get isVoiceEnabled => _voiceEnabled;
  Stream<MotionReading> get motionStream => _motion.stream;

  /// Human-readable events ("Violent motion detected", ...) for the screen.
  Stream<String> get eventLog => _log.stream;

  // ---------------------------------------------------------------------------
  // On / off
  // ---------------------------------------------------------------------------

  /// Called once at app start: resumes detection if the user turned it on.
  Future<void> restoreOnLaunch() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      _voiceEnabled = prefs.getBool(voiceKey) ?? true;
      if (prefs.getBool(enabledKey) == true) await start();
    } catch (e) {
      debugPrint('[DistressMonitor] restore failed: $e');
    }
  }

  Future<void> setEnabled(bool enabled) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(enabledKey, enabled);
    } catch (_) {}
    if (enabled) {
      await start();
    } else {
      await stop();
    }
  }

  Future<void> setVoiceEnabled(bool enabled) async {
    _voiceEnabled = enabled;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(voiceKey, enabled);
    } catch (_) {}
    if (!_running) return;
    if (enabled) {
      await voice.startMonitoring();
    } else {
      await voice.stopMonitoring();
    }
  }

  Future<void> start() async {
    if (_running) return;
    _running = true;
    debugPrint('[DistressMonitor] started');

    _accelSub = accelerometerEventStream().listen(_onAccel);
    _voiceSub = voice.distressEventStream.listen((e) => trigger(e.description));
    if (_voiceEnabled) {
      final ok = await voice.startMonitoring();
      if (!ok) debugPrint('[DistressMonitor] microphone not available');
    }

    await _startForegroundService();
    await _askBatteryExemptionOnce();
  }

  Future<void> stop() async {
    if (!_running) return;
    _running = false;
    debugPrint('[DistressMonitor] stopped');
    await _accelSub?.cancel();
    await _voiceSub?.cancel();
    _accelSub = null;
    _voiceSub = null;
    await voice.stopMonitoring();
    _motion.add(const MotionReading(0, 'Stationary'));
    try {
      if (await FlutterForegroundTask.isRunningService) {
        await FlutterForegroundTask.stopService();
      }
    } catch (_) {}
  }

  // ---------------------------------------------------------------------------
  // Detection
  // ---------------------------------------------------------------------------

  void _onAccel(AccelerometerEvent event) {
    final magnitude =
        sqrt(event.x * event.x + event.y * event.y + event.z * event.z);
    final normalized = ((magnitude - 9.8).abs() / 20).clamp(0.0, 1.0);

    final String activity;
    if (normalized > 0.7) {
      activity = 'Violent Movement';
    } else if (normalized > 0.4) {
      activity = 'Running';
    } else if (normalized > 0.15) {
      activity = 'Walking';
    } else {
      activity = 'Stationary';
    }
    _motion.add(MotionReading(normalized, activity));

    if (normalized > 0.7) {
      trigger('Violent motion or hard impact detected');
    }
  }

  /// Shows the "Are you safe?" countdown over whatever the user is doing.
  Future<void> trigger(String reason) async {
    final now = DateTime.now();
    if (_alertOpen) return;
    if (now.difference(_lastTrigger) < const Duration(seconds: 15)) return;
    if (SosService.anySosRunning) return; // already handling an emergency
    _lastTrigger = now;
    _alertOpen = true;
    _log.add('⚠️ $reason');
    debugPrint('[DistressMonitor] trigger: $reason');

    try {
      FlutterForegroundTask.wakeUpScreen();
    } catch (_) {}
    try {
      await const MethodChannel('com.safetyguardian/app_control')
          .invokeMethod('bringToFront');
    } catch (_) {}
    try {
      await FlutterForegroundTask.updateService(
        notificationTitle: '🚨 Are you safe?',
        notificationText: '$reason. SOS starts in 60 s unless you respond.',
      );
    } catch (_) {}

    final nav = navigatorKey.currentState;
    if (nav == null) {
      _alertOpen = false;
      return;
    }
    await nav.pushNamed('/distress-alert', arguments: reason);
    _alertOpen = false;
    await _restoreNotification();
  }

  // ---------------------------------------------------------------------------
  // Foreground service (shared with evidence recording & companion mode)
  // ---------------------------------------------------------------------------

  static const String _title = 'Safety Guardian is protecting you';
  static const String _text =
      'Distress detection is on: listening for screams, calls for help and falls.';

  Future<void> _startForegroundService() async {
    try {
      FlutterForegroundTask.init(
        androidNotificationOptions: AndroidNotificationOptions(
          channelId: 'distress_monitor_channel',
          channelName: 'Distress Detection',
          channelDescription:
              'Keeps distress detection running when the app is closed',
          channelImportance: NotificationChannelImportance.LOW,
          priority: NotificationPriority.LOW,
        ),
        iosNotificationOptions: const IOSNotificationOptions(),
        foregroundTaskOptions: ForegroundTaskOptions(
          eventAction: ForegroundTaskEventAction.nothing(),
          autoRunOnBoot: false,
          autoRunOnMyPackageReplaced: false,
          allowWakeLock: true,
          allowWifiLock: false,
        ),
      );
      if (await FlutterForegroundTask.isRunningService) {
        await _restoreNotification();
        return;
      }

      // Android 14+: each service type needs its permission granted first.
      final types = <ForegroundServiceTypes>[];
      if (await Permission.microphone.isGranted) {
        types.add(ForegroundServiceTypes.microphone);
      }
      if (await Permission.location.isGranted) {
        types.add(ForegroundServiceTypes.location);
      }
      if (types.isEmpty) {
        debugPrint('[DistressMonitor] no mic/location permission: '
            'detection works only while the app is open');
        return;
      }

      await FlutterForegroundTask.startService(
        serviceTypes: types,
        notificationTitle: _title,
        notificationText: _text,
        notificationInitialRoute: '/distress',
      );
    } catch (e) {
      debugPrint('[DistressMonitor] foreground service error: $e');
    }
  }

  Future<void> _restoreNotification() async {
    if (!_running) return;
    try {
      await FlutterForegroundTask.updateService(
        notificationTitle: _title,
        notificationText: _text,
      );
    } catch (_) {}
  }

  /// Evidence recording and companion mode call this instead of stopping the
  /// shared service, so finishing them never switches distress detection off.
  Future<void> releaseForegroundService() async {
    try {
      if (_running) {
        await _restoreNotification();
      } else if (await FlutterForegroundTask.isRunningService) {
        await FlutterForegroundTask.stopService();
      }
    } catch (_) {}
  }

  /// Xiaomi / OPPO / Vivo kill background apps aggressively; ask once to be
  /// excluded from battery optimisation so detection survives.
  Future<void> _askBatteryExemptionOnce() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (prefs.getBool(_batteryAskedKey) == true) return;
      await prefs.setBool(_batteryAskedKey, true);
      if (!await FlutterForegroundTask.isIgnoringBatteryOptimizations) {
        await FlutterForegroundTask.requestIgnoreBatteryOptimization();
      }
    } catch (_) {}
  }
}
