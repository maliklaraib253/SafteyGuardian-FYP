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

  /// Seconds the user has to answer "Are you safe?" (2 minutes).
  static const int alertSeconds = 120;

  /// Seconds left on the "Are you safe?" countdown (null = no alert).
  /// The countdown runs here, not in the alert screen, so it keeps going
  /// while the app is in the background or the screen is locked.
  final ValueNotifier<int?> secondsLeft = ValueNotifier<int?>(null);
  Timer? _alertTimer;
  Timer? _voiceResumeTimer;
  DateTime? _deadline;
  String _alertReason = '';
  String get alertReason => _alertReason;

  static const MethodChannel _appControl = MethodChannel(
    'com.safetyguardian/app_control',
  );

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
    _voiceResumeTimer?.cancel();
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
    final magnitude = sqrt(
      event.x * event.x + event.y * event.y + event.z * event.z,
    );
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
    // Already handling an emergency.
    if (SosService.anySosRunning || SosService.sessionActive) return;
    _lastTrigger = now;
    _alertOpen = true;
    _log.add('⚠️ $reason');
    debugPrint('[DistressMonitor] trigger: $reason');

    // Stop the microphone during the alert: the alert sound must be heard
    // and the recogniser must not keep the phone's sounds muted.
    _voiceResumeTimer?.cancel();
    if (_voiceEnabled) await voice.stopMonitoring();

    // 1. Start the countdown right away, whether or not the app is open.
    // It counts against a fixed deadline on the wall clock, so time that
    // passes while the phone sleeps is still counted, and the native side
    // holds a wake lock (showDistressAlert) so the timer keeps firing with
    // the screen off. No tap on the notification is needed.
    _alertReason = reason;
    _deadline = now.add(const Duration(seconds: alertSeconds));
    secondsLeft.value = alertSeconds;
    _alertTimer?.cancel();
    var lastBucket = alertSeconds ~/ 10;
    _alertTimer = Timer.periodic(const Duration(seconds: 1), (t) {
      final deadline = _deadline;
      if (deadline == null) {
        t.cancel();
        return;
      }
      final left = deadline.difference(DateTime.now()).inSeconds;
      if (left <= 0) {
        t.cancel();
        startSosNow();
        return;
      }
      secondsLeft.value = left;
      final bucket = left ~/ 10;
      if (bucket != lastBucket) {
        lastBucket = bucket;
        _showAlertNotification(left);
      }
    });

    // 2. Get the user's attention: wake the screen, show the alert over the
    // lock screen (full-screen notification) and try to open the app.
    try {
      FlutterForegroundTask.wakeUpScreen();
    } catch (_) {}
    try {
      await _appControl.invokeMethod('setShowOnLockScreen', {'on': true});
    } catch (_) {}
    await _showAlertNotification(alertSeconds);
    try {
      await _appControl.invokeMethod('bringToFront');
    } catch (_) {}

    // 3. The alert screen only shows the countdown and the two buttons.
    navigatorKey.currentState?.pushNamed('/distress-alert', arguments: reason);
  }

  static String _fmt(int s) =>
      '${s ~/ 60}:${(s % 60).toString().padLeft(2, '0')}';

  Future<void> _showAlertNotification(int left) async {
    final text =
        '$_alertReason. SOS starts in ${_fmt(left)} unless you answer.';
    try {
      await _appControl.invokeMethod('showDistressAlert', {
        'title': '🚨 Are you safe?',
        'text': text,
      });
    } catch (_) {}
    try {
      await FlutterForegroundTask.updateService(
        notificationTitle: '🚨 Are you safe?',
        notificationText: text,
      );
    } catch (_) {}
  }

  Future<void> _closeAlert({bool resumeVoice = true}) async {
    _alertTimer?.cancel();
    _alertTimer = null;
    _deadline = null;
    secondsLeft.value = null;
    _alertOpen = false;
    try {
      await _appControl.invokeMethod('cancelDistressAlert');
      await _appControl.invokeMethod('setShowOnLockScreen', {'on': false});
    } catch (_) {}
    navigatorKey.currentState?.popUntil(
      (route) => route.settings.name != '/distress-alert',
    );
    await _restoreNotification();
    if (resumeVoice) {
      await _resumeVoice();
    } else {
      _resumeVoiceAfterSos();
    }
  }

  Future<void> _resumeVoice() async {
    if (_running && _voiceEnabled && !voice.isMonitoring) {
      await voice.startMonitoring();
    }
  }

  /// Keeps the microphone off while an SOS is calling people, then turns
  /// voice detection back on once the SOS has ended.
  void _resumeVoiceAfterSos() {
    _voiceResumeTimer?.cancel();
    _voiceResumeTimer = Timer.periodic(const Duration(seconds: 30), (t) {
      if (!_running) {
        t.cancel();
        return;
      }
      if (!SosService.anySosRunning && !SosService.sessionActive) {
        t.cancel();
        _resumeVoice();
      }
    });
  }

  /// "I'm safe" on the alert screen or its notification.
  Future<void> respondSafe() async {
    if (!_alertOpen) return;
    _log.add('✅ User confirmed they are safe');
    await _closeAlert();
  }

  /// "Get help now", or the countdown ran out: start the SOS.
  Future<void> startSosNow() async {
    if (!_alertOpen) return;
    await _closeAlert(resumeVoice: false);
    _log.add('🚨 No answer - SOS started');
    final resumed =
        WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;
    if (!resumed) {
      // App not on screen: Flutter doesn't build new screens in the
      // background, so start the SOS here. The SOS screen attaches to it
      // when the app is opened.
      unawaited(SosService().startSos());
    }
    navigatorKey.currentState?.pushNamed('/sos', arguments: 'activate');
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
        debugPrint(
          '[DistressMonitor] no mic/location permission: '
          'detection works only while the app is open',
        );
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
