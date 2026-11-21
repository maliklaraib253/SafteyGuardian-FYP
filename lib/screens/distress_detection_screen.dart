import 'dart:async';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:iconsax/iconsax.dart';
import 'package:sensors_plus/sensors_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:permission_handler/permission_handler.dart';
import '../services/voice_distress_service.dart';

class DistressDetectionScreen extends StatefulWidget {
  const DistressDetectionScreen({super.key});

  @override
  State<DistressDetectionScreen> createState() =>
      _DistressDetectionScreenState();
}

class _DistressDetectionScreenState extends State<DistressDetectionScreen>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  // Animation for detection
  late AnimationController _pulseAnimation;
  late Animation<double> _pulseScale;

  // State variables - Default to Active & Monitoring (Always On)
  bool _isDetectionActive = true;
  bool _isLocationTracking = true;
  bool _isVoiceMonitoringActive = true;
  String _detectionStatus = 'Active - Monitoring';
  Color _statusColor = Colors.green;

  // Sensor readings (live)
  double _soundLevel = 0.0;
  double _movementIntensity = 0.0;
  String _currentActivity = 'Stationary';
  final List<String> _recentAlerts = [];

  // Voice Distress Service & State
  final VoiceDistressService _voiceService = VoiceDistressService();
  StreamSubscription<double>? _soundLevelSub;
  StreamSubscription<VoiceDistressResult>? _voiceDistressSub;
  StreamSubscription<String>? _transcriptionSub;
  String _latestTranscript = '';
  String _lastDetectedDistress = 'Normal';

  // Countdown timer for Auto-SOS: 1 minute (60 seconds)
  static const int _autoSosCountdownDuration = 60;
  Timer? _countdownTimer;
  int _countdownSeconds = _autoSosCountdownDuration;

  // Real accelerometer stream + state to prevent dialog spam
  StreamSubscription<AccelerometerEvent>? _accelSub;
  bool _dialogShowing = false;
  DateTime _lastTriggerAt = DateTime.fromMillisecondsSinceEpoch(0);

  // Distress patterns (for demo)
  final List<Map<String, dynamic>> _distressEvents = [
    {
      'type': 'Loud Noise',
      'time': '2 min ago',
      'level': 0.85,
      'detected': true,
    },
    {
      'type': 'Sudden Movement',
      'time': '5 min ago',
      'level': 0.92,
      'detected': true,
    },
    {'type': 'Running', 'time': '10 min ago', 'level': 0.78, 'detected': false},
    {'type': 'Shouting', 'time': '15 min ago', 'level': 0.95, 'detected': true},
  ];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);

    // Setup pulse animation for active state
    _pulseAnimation = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1500),
    )..repeat(reverse: true);

    _pulseScale = Tween<double>(begin: 1.0, end: 1.1).animate(
      CurvedAnimation(parent: _pulseAnimation, curve: Curves.easeInOut),
    );

    _initializeMonitoringState();
    _checkOverlayPermission();
  }

  // Request display over other apps so the emergency prompt can appear over any app
  Future<void> _checkOverlayPermission() async {
    try {
      if (!await Permission.systemAlertWindow.isGranted) {
        await Permission.systemAlertWindow.request();
      }
    } catch (_) {}
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused || state == AppLifecycleState.inactive) {
      if (_isDetectionActive) {
        _startBackgroundSentinel();
      }
    }
  }

  // Starts foreground service so Android keeps sensor monitoring alive when app is minimized
  Future<void> _startBackgroundSentinel() async {
    try {
      FlutterForegroundTask.init(
        androidNotificationOptions: AndroidNotificationOptions(
          channelId: 'distress_sentinel_channel',
          channelName: 'SafetyGuardian Distress Sentinel',
          channelDescription: 'Monitors violent motion, falls, and emergencies in background',
          channelImportance: NotificationChannelImportance.MAX,
          priority: NotificationPriority.MAX,
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

      if (await FlutterForegroundTask.isRunningService) return;

      await FlutterForegroundTask.startService(
        notificationTitle: 'SafetyGuardian — Background Distress Sentinel',
        notificationText: 'Monitoring active in background. Tap if emergency.',
      );
    } catch (e) {
      debugPrint('[DistressSentinel] startService error: $e');
    }
  }

  Future<void> _stopBackgroundSentinel() async {
    try {
      if (await FlutterForegroundTask.isRunningService) {
        await FlutterForegroundTask.stopService();
      }
    } catch (_) {}
  }

  // Load saved state or default to always on, starting sensors automatically
  Future<void> _initializeMonitoringState() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final enabled = prefs.getBool('distress_detection_always_on') ?? true;
      if (!mounted) return;
      setState(() {
        _isDetectionActive = enabled;
        if (enabled) {
          _detectionStatus = 'Active - Monitoring';
          _statusColor = Colors.green;
          _isLocationTracking = true;
        } else {
          _detectionStatus = 'Inactive';
          _statusColor = Colors.grey;
          _isLocationTracking = false;
        }
      });
      if (enabled) {
        _startSensorMonitoring();
        _startVoiceMonitoring();
        _startBackgroundSentinel();
      }
    } catch (_) {
      if (mounted && _isDetectionActive) {
        _startSensorMonitoring();
        _startVoiceMonitoring();
        _startBackgroundSentinel();
      }
    }
  }

  // Subscribe to real accelerometer events. Magnitude of acceleration is used
  // as a proxy for "how violently the phone is moving." At rest the magnitude
  // is ~9.8 m/s^2 (gravity); shaking/running pushes it well above that.
  void _startSensorMonitoring() {
    _accelSub?.cancel();
    _accelSub = accelerometerEventStream().listen((event) {
      if (!mounted || !_isDetectionActive) return;

      final magnitude = sqrt(
        event.x * event.x + event.y * event.y + event.z * event.z,
      );
      final excess = (magnitude - 9.8).abs();
      final normalized = (excess / 20).clamp(0.0, 1.0);

      String activity;
      if (normalized > 0.7) {
        activity = 'Violent Movement';
      } else if (normalized > 0.4) {
        activity = 'Running';
      } else if (normalized > 0.15) {
        activity = 'Walking';
      } else {
        activity = 'Stationary';
      }

      setState(() {
        _movementIntensity = normalized;
        _currentActivity = activity;
      });

      // Trigger the "Are you safe?" prompt if movement is violent AND we
      // haven't already shown it recently (10-second cooldown).
      final now = DateTime.now();
      if (normalized > 0.7 &&
          !_dialogShowing &&
          now.difference(_lastTriggerAt).inSeconds > 10) {
        _lastTriggerAt = now;
        _showDistressDialog(
          reason: 'Violent motion or hard impact detected',
        );
      }
    });
  }

  void _stopSensorMonitoring() {
    _accelSub?.cancel();
    _accelSub = null;
  }

  void _startVoiceMonitoring() async {
    _soundLevelSub?.cancel();
    _voiceDistressSub?.cancel();
    _transcriptionSub?.cancel();

    _soundLevelSub = _voiceService.soundLevelStream.listen((level) {
      if (!mounted) return;
      setState(() {
        _soundLevel = level;
      });
    });

    _transcriptionSub = _voiceService.liveTranscriptionStream.listen((transcript) {
      if (!mounted) return;
      setState(() {
        _latestTranscript = transcript;
      });
    });

    _voiceDistressSub = _voiceService.distressEventStream.listen((event) {
      if (!mounted || !_isDetectionActive) return;
      setState(() {
        _lastDetectedDistress = event.description;
      });
      final now = DateTime.now();
      if (!_dialogShowing && now.difference(_lastTriggerAt).inSeconds > 5) {
        _lastTriggerAt = now;
        _showDistressDialog(reason: event.description);
      }
    });

    final ok = await _voiceService.startMonitoring();
    if (!ok && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Microphone access required for voice & scream detection',
          ),
          backgroundColor: Colors.orange,
        ),
      );
    }
  }

  void _stopVoiceMonitoring() {
    _soundLevelSub?.cancel();
    _voiceDistressSub?.cancel();
    _transcriptionSub?.cancel();
    _voiceService.stopMonitoring();
  }

  void _showDistressDialog({
    String reason = 'Unusual activity: Sudden movement or high noise',
  }) {
    if (_dialogShowing) return;
    _dialogShowing = true;
    _countdownSeconds = _autoSosCountdownDuration;
    _countdownTimer?.cancel();

    // 1. Instantly bring app to front over whatever other app user is using!
    try {
      const MethodChannel('com.safetyguardian/app_control').invokeMethod('bringToFront');
    } catch (_) {}
    try {
      FlutterForegroundTask.launchApp('/distress');
    } catch (_) {}

    // 2. Update Foreground Service notification with urgent alert
    try {
      FlutterForegroundTask.updateService(
        notificationTitle: '🚨 EMERGENCY ALERT: Are you safe?',
        notificationText: 'Distress detected! Tap to respond or Auto-SOS calls in 60s.',
      );
    } catch (_) {}

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (dialogCtx) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            _countdownTimer ??= Timer.periodic(const Duration(seconds: 1), (timer) {
              if (!mounted) {
                timer.cancel();
                return;
              }
              if (_countdownSeconds <= 1) {
                timer.cancel();
                _countdownTimer = null;
                if (_dialogShowing && Navigator.canPop(dialogCtx)) {
                  Navigator.pop(dialogCtx);
                  _dialogShowing = false;
                  _addAlert('🚨 AUTO-SOS DISPATCHED (Incapacitated - 60s Timeout)');
                  _activateEmergency();
                }
              } else {
                setDialogState(() {
                  _countdownSeconds--;
                });
              }
            });

            return AlertDialog(
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(24),
              ),
              title: Column(
                children: [
                  Container(
                    width: 72,
                    height: 72,
                    decoration: BoxDecoration(
                      color: Colors.red.shade50,
                      shape: BoxShape.circle,
                      border: Border.all(color: Colors.red.shade300, width: 2.5),
                    ),
                    child: Center(
                      child: Text(
                        '$_countdownSeconds',
                        style: TextStyle(
                          fontSize: 28,
                          fontWeight: FontWeight.bold,
                          color: Colors.red.shade700,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  const Text(
                    'Are you safe?',
                    style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold),
                  ),
                ],
              ),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 8,
                    ),
                    decoration: BoxDecoration(
                      color: Colors.red.shade50,
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(color: Colors.red.shade200),
                    ),
                    child: Row(
                      children: [
                        const Icon(
                          Icons.warning_amber_rounded,
                          color: Colors.red,
                          size: 22,
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            reason,
                            style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                              color: Colors.red.shade800,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 12),
                  Text(
                    'Auto-SOS will be sent in $_countdownSeconds seconds if not cancelled.',
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 13, color: Colors.grey.shade700),
                  ),
                  const SizedBox(height: 20),
                  Row(
                    children: [
                      Expanded(
                        child: GestureDetector(
                          onTap: () {
                            _countdownTimer?.cancel();
                            _countdownTimer = null;
                            Navigator.pop(dialogCtx);
                            _dialogShowing = false;
                            _addAlert('User confirmed SAFE');
                            try {
                              FlutterForegroundTask.updateService(
                                notificationTitle: 'SafetyGuardian — Background Distress Sentinel',
                                notificationText: 'Monitoring active in background. Tap if emergency.',
                              );
                            } catch (_) {}
                          },
                          child: Container(
                            padding: const EdgeInsets.symmetric(vertical: 14),
                            decoration: BoxDecoration(
                              color: Colors.green.shade50,
                              borderRadius: BorderRadius.circular(14),
                              border: Border.all(color: Colors.green.shade300),
                            ),
                            child: Column(
                              children: [
                                Icon(
                                  Icons.check_circle,
                                  color: Colors.green.shade600,
                                  size: 28,
                                ),
                                const SizedBox(height: 4),
                                Text(
                                  "I'm Safe",
                                  style: TextStyle(
                                    color: Colors.green.shade700,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: GestureDetector(
                          onTap: () {
                            _countdownTimer?.cancel();
                            _countdownTimer = null;
                            Navigator.pop(dialogCtx);
                            _dialogShowing = false;
                            _activateEmergency();
                          },
                          child: Container(
                            padding: const EdgeInsets.symmetric(vertical: 14),
                            decoration: BoxDecoration(
                              color: Colors.red.shade50,
                              borderRadius: BorderRadius.circular(14),
                              border: Border.all(color: Colors.red.shade300),
                            ),
                            child: Column(
                              children: [
                                Icon(
                                  Icons.warning,
                                  color: Colors.red.shade600,
                                  size: 28,
                                ),
                                const SizedBox(height: 4),
                                Text(
                                  "Help Needed",
                                  style: TextStyle(
                                    color: Colors.red.shade700,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  TextButton(
                    onPressed: () {
                      _countdownTimer?.cancel();
                      _countdownTimer = null;
                      Navigator.pop(dialogCtx);
                      _dialogShowing = false;
                      _addAlert('False alarm - dismissed');
                      try {
                        FlutterForegroundTask.updateService(
                          notificationTitle: 'SafetyGuardian — Background Distress Sentinel',
                          notificationText: 'Monitoring active in background. Tap if emergency.',
                        );
                      } catch (_) {}
                    },
                    child: const Text('False Alarm'),
                  ),
                ],
              ),
            );
          },
        );
      },
    ).then((_) {
      _countdownTimer?.cancel();
      _countdownTimer = null;
      _dialogShowing = false;
    });
  }

  void _activateEmergency() {
    _addAlert('🚨 EMERGENCY ACTIVATED');
    // Open the SOS screen and start SOS there, so an automatic SOS behaves
    // exactly like the SOS button: live call progress, call blocking, and
    // "I'm safe now" to stop it.
    if (!mounted) return;
    Navigator.pushNamed(context, '/sos', arguments: 'activate');
  }

  void _addAlert(String message) {
    setState(() {
      _recentAlerts.insert(
        0,
        '$message - ${DateTime.now().hour}:${DateTime.now().minute}',
      );
      if (_recentAlerts.length > 5) {
        _recentAlerts.removeLast();
      }
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _countdownTimer?.cancel();
    _pulseAnimation.dispose();
    _accelSub?.cancel();
    _stopVoiceMonitoring();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Distress Detection'),
        actions: [
          IconButton(
            icon: const Icon(Iconsax.info_circle),
            onPressed: _showInfoDialog,
          ),
        ],
      ),
      body: Stack(
        children: [
          // Background gradient
          Container(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  const Color(0xFF1D4ED8).withValues(alpha: 0.1),
                  Colors.white,
                ],
              ),
            ),
          ),

          // Main content
          SingleChildScrollView(
            padding: const EdgeInsets.all(20),
            child: Column(
              children: [
                // Status Card
                Card(
                  elevation: 4,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.all(20),
                    child: Column(
                      children: [
                        Row(
                          children: [
                            AnimatedBuilder(
                              animation: _pulseAnimation,
                              builder: (context, child) {
                                return Transform.scale(
                                  scale: _isDetectionActive
                                      ? _pulseScale.value
                                      : 1.0,
                                  child: Container(
                                    padding: const EdgeInsets.all(12),
                                    decoration: BoxDecoration(
                                      color: _isDetectionActive
                                          ? Colors.red.withValues(alpha: 0.2)
                                          : Colors.grey.withValues(alpha: 0.2),
                                      shape: BoxShape.circle,
                                    ),
                                    child: Icon(
                                      _isDetectionActive
                                          ? Iconsax.radar1
                                          : Iconsax.radar,
                                      color: _isDetectionActive
                                          ? Colors.red
                                          : Colors.grey,
                                      size: 30,
                                    ),
                                  ),
                                );
                              },
                            ),
                            const SizedBox(width: 15),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    'Detection Status',
                                    style: TextStyle(
                                      fontSize: 12,
                                      color: Colors.grey.shade600,
                                    ),
                                  ),
                                  Text(
                                    _detectionStatus,
                                    style: TextStyle(
                                      fontSize: 18,
                                      fontWeight: FontWeight.bold,
                                      color: _statusColor,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            Switch(
                              value: _isDetectionActive,
                              onChanged: (value) async {
                                setState(() {
                                  _isDetectionActive = value;
                                  if (value) {
                                    _detectionStatus = 'Active - Monitoring';
                                    _statusColor = Colors.green;
                                    _isLocationTracking = true;
                                  } else {
                                    _detectionStatus = 'Inactive';
                                    _statusColor = Colors.grey;
                                    _isLocationTracking = false;
                                    _movementIntensity = 0.0;
                                    _currentActivity = 'Stationary';
                                  }
                                });
                                try {
                                  final prefs = await SharedPreferences.getInstance();
                                  await prefs.setBool('distress_detection_always_on', value);
                                } catch (_) {}
                                if (value) {
                                  _startSensorMonitoring();
                                  _startVoiceMonitoring();
                                  _startBackgroundSentinel();
                                } else {
                                  _stopSensorMonitoring();
                                  _stopVoiceMonitoring();
                                  _stopBackgroundSentinel();
                                }
                              },
                              activeThumbColor: Colors.green,
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),

                const SizedBox(height: 20),

                // Sensor Readings Card
                Card(
                  elevation: 4,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.all(20),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'Live Sensor Readings',
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        const SizedBox(height: 15),

                        // Microphone sensor with independent toggle
                        _buildSensorRow(
                          icon: Iconsax.microphone,
                          title: 'Microphone',
                          value: _soundLevel,
                          color: Colors.blue,
                          subtitle: !_isVoiceMonitoringActive
                              ? 'Voice monitoring off'
                              : _soundLevel > 0.7
                                  ? 'Loud noise detected (${(_soundLevel * 100).toInt()}%)'
                                  : 'Active - Normal (${(_soundLevel * 100).toInt()}%)',
                          trailingSwitch: Switch(
                            value: _isVoiceMonitoringActive,
                            onChanged: (val) {
                              setState(() {
                                _isVoiceMonitoringActive = val;
                                if (!val) {
                                  _soundLevel = 0.0;
                                  _latestTranscript = '';
                                }
                              });
                              if (val) {
                                _startVoiceMonitoring();
                              } else {
                                _stopVoiceMonitoring();
                              }
                            },
                            activeThumbColor: Colors.blue,
                          ),
                        ),

                        const SizedBox(height: 15),

                        // Accelerometer sensor
                        _buildSensorRow(
                          icon: Iconsax.activity,
                          title: 'Motion Sensor',
                          value: _movementIntensity,
                          color: Colors.orange,
                          subtitle: _currentActivity,
                        ),

                        const SizedBox(height: 15),

                        // Location sensor
                        Container(
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: Colors.green.shade50,
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: Row(
                            children: [
                              Container(
                                padding: const EdgeInsets.all(8),
                                decoration: BoxDecoration(
                                  color: Colors.green.shade100,
                                  borderRadius: BorderRadius.circular(8),
                                ),
                                child: Icon(
                                  Iconsax.location,
                                  color: Colors.green.shade700,
                                  size: 20,
                                ),
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    const Text(
                                      'Location Services',
                                      style: TextStyle(
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                    Text(
                                      _isLocationTracking
                                          ? 'Tracking active - 31.5204° N, 74.3587° E'
                                          : 'Location tracking off',
                                      style: TextStyle(
                                        fontSize: 12,
                                        color: _isLocationTracking
                                            ? Colors.green.shade700
                                            : Colors.grey,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              Switch(
                                value: _isLocationTracking,
                                onChanged: (value) {
                                  setState(() {
                                    _isLocationTracking = value;
                                  });
                                },
                                activeThumbColor: Colors.green,
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),

                const SizedBox(height: 20),

                // Distress Patterns Card
                Card(
                  elevation: 4,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.all(20),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'AI Distress Detection',
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        const SizedBox(height: 15),

                        // Pattern 1: Shouting & Screaming
                        _buildPatternRow(
                          icon: Iconsax.volume_high,
                          pattern: 'Shouting & Screaming',
                          status: _soundLevel > 0.75 ? 'DETECTED' : 'Normal',
                          color: _soundLevel > 0.75 ? Colors.red : Colors.green,
                        ),

                        const SizedBox(height: 10),

                        // Pattern 2: Life Threat & Robbery Demand
                        _buildPatternRow(
                          icon: Iconsax.danger,
                          pattern: 'Threat & Aggression (Dhamki)',
                          status: _lastDetectedDistress.contains('Threat')
                              ? 'DETECTED'
                              : 'Normal',
                          color: _lastDetectedDistress.contains('Threat')
                              ? Colors.red
                              : Colors.green,
                        ),

                        const SizedBox(height: 10),

                        // Pattern 3: Verbal Abuse & Harassment (Galian)
                        _buildPatternRow(
                          icon: Iconsax.warning_2,
                          pattern: 'Verbal Abuse & Harassment',
                          status: _lastDetectedDistress.contains('Abuse')
                              ? 'DETECTED'
                              : 'Normal',
                          color: _lastDetectedDistress.contains('Abuse')
                              ? Colors.red
                              : Colors.green,
                        ),

                        const SizedBox(height: 10),

                        // Pattern 4: Fall / Sudden Violent Movement
                        _buildPatternRow(
                          icon: Iconsax.activity,
                          pattern: 'Sudden Movement & Fall',
                          status: _movementIntensity > 0.7
                              ? 'DETECTED'
                              : 'Normal',
                          color: _movementIntensity > 0.7
                              ? Colors.red
                              : Colors.green,
                        ),

                        const SizedBox(height: 15),

                        // Live Speech Recognition Status
                        if (_isDetectionActive) ...[
                          Container(
                            width: double.infinity,
                            padding: const EdgeInsets.all(12),
                            decoration: BoxDecoration(
                              color: Colors.blue.shade50,
                              borderRadius: BorderRadius.circular(10),
                              border: Border.all(color: Colors.blue.shade200),
                            ),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(
                                  children: [
                                    Icon(
                                      Iconsax.voice_cricle,
                                      size: 16,
                                      color: Colors.blue.shade700,
                                    ),
                                    const SizedBox(width: 8),
                                    Text(
                                      'Live Mic Listening (Urdu / English)',
                                      style: TextStyle(
                                        fontSize: 12,
                                        fontWeight: FontWeight.bold,
                                        color: Colors.blue.shade900,
                                      ),
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 6),
                                Text(
                                  _latestTranscript.isEmpty
                                      ? 'Listening for threat/abuse words (e.g. "Bachao", "Maar dunga", abuse slurs)...'
                                      : '"$_latestTranscript"',
                                  style: TextStyle(
                                    fontSize: 12,
                                    fontStyle: _latestTranscript.isEmpty
                                        ? FontStyle.italic
                                        : FontStyle.normal,
                                    color: _latestTranscript.isEmpty
                                        ? Colors.grey.shade600
                                        : Colors.black87,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(height: 12),
                        ],

                        // Info text
                        Container(
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: Colors.blue.shade50,
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: Row(
                            children: [
                              Icon(
                                Iconsax.info_circle,
                                color: Colors.blue.shade700,
                                size: 16,
                              ),
                              const SizedBox(width: 8),
                              const Expanded(
                                child: Text(
                                  'AI analyzes sensor data to detect distress patterns like shouting, running, or sudden movements',
                                  style: TextStyle(fontSize: 12),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),

                const SizedBox(height: 20),

                // Recent Events Card
                Card(
                  elevation: 4,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.all(20),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'Recent Detections',
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        const SizedBox(height: 10),

                        // Events list
                        ..._distressEvents.map(
                          (event) => Padding(
                            padding: const EdgeInsets.only(bottom: 8),
                            child: Container(
                              padding: const EdgeInsets.all(12),
                              decoration: BoxDecoration(
                                color: event['detected']
                                    ? Colors.orange.shade50
                                    : Colors.grey.shade50,
                                borderRadius: BorderRadius.circular(12),
                                border: Border.all(
                                  color: event['detected']
                                      ? Colors.orange.shade200
                                      : Colors.grey.shade200,
                                ),
                              ),
                              child: Row(
                                children: [
                                  Container(
                                    padding: const EdgeInsets.all(8),
                                    decoration: BoxDecoration(
                                      color: event['detected']
                                          ? Colors.orange.shade100
                                          : Colors.grey.shade200,
                                      shape: BoxShape.circle,
                                    ),
                                    child: Icon(
                                      event['type'] == 'Loud Noise'
                                          ? Iconsax.volume_high
                                          : event['type'] == 'Sudden Movement'
                                          ? Iconsax.flash
                                          : event['type'] == 'Running'
                                          ? Iconsax.activity
                                          : Iconsax.volume_high,
                                      color: event['detected']
                                          ? Colors.orange
                                          : Colors.grey,
                                      size: 16,
                                    ),
                                  ),
                                  const SizedBox(width: 10),
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Text(
                                          event['type'],
                                          style: TextStyle(
                                            fontWeight: FontWeight.w600,
                                            color: event['detected']
                                                ? Colors.orange.shade700
                                                : Colors.grey.shade700,
                                          ),
                                        ),
                                        Text(
                                          event['time'],
                                          style: TextStyle(
                                            fontSize: 10,
                                            color: Colors.grey.shade500,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                  Container(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 8,
                                      vertical: 4,
                                    ),
                                    decoration: BoxDecoration(
                                      color: event['detected']
                                          ? Colors.orange.shade100
                                          : Colors.grey.shade200,
                                      borderRadius: BorderRadius.circular(10),
                                    ),
                                    child: Text(
                                      '${(event['level'] * 100).toInt()}%',
                                      style: TextStyle(
                                        fontSize: 10,
                                        fontWeight: FontWeight.bold,
                                        color: event['detected']
                                            ? Colors.orange.shade700
                                            : Colors.grey.shade700,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),

                const SizedBox(height: 20),

                // Recent Alerts Card
                if (_recentAlerts.isNotEmpty)
                  Card(
                    elevation: 4,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: Padding(
                      padding: const EdgeInsets.all(20),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text(
                            'Alert History',
                            style: TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          const SizedBox(height: 10),
                          ..._recentAlerts.map(
                            (alert) => Padding(
                              padding: const EdgeInsets.only(bottom: 8),
                              child: Container(
                                padding: const EdgeInsets.all(8),
                                decoration: BoxDecoration(
                                  color: alert.contains('EMERGENCY')
                                      ? Colors.red.shade50
                                      : alert.contains('SAFE')
                                      ? Colors.green.shade50
                                      : Colors.grey.shade50,
                                  borderRadius: BorderRadius.circular(8),
                                ),
                                child: Row(
                                  children: [
                                    Icon(
                                      alert.contains('EMERGENCY')
                                          ? Icons.warning
                                          : alert.contains('SAFE')
                                          ? Icons.check_circle
                                          : Icons.info,
                                      color: alert.contains('EMERGENCY')
                                          ? Colors.red
                                          : alert.contains('SAFE')
                                          ? Colors.green
                                          : Colors.grey,
                                      size: 16,
                                    ),
                                    const SizedBox(width: 8),
                                    Expanded(
                                      child: Text(
                                        alert,
                                        style: TextStyle(
                                          fontSize: 12,
                                          color: alert.contains('EMERGENCY')
                                              ? Colors.red.shade700
                                              : alert.contains('SAFE')
                                              ? Colors.green.shade700
                                              : Colors.grey.shade700,
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),

                const SizedBox(height: 20),

                // Test buttons for Simulation & Safety Verification
                if (_isDetectionActive) ...[
                  Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      'Safety Test & Simulation (Urdu / English)',
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.bold,
                        color: Colors.grey.shade700,
                      ),
                    ),
                  ),
                  const SizedBox(height: 10),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      ActionChip(
                        avatar: const Icon(
                          Icons.mic,
                          size: 16,
                          color: Colors.green,
                        ),
                        label: const Text('Speak to Test (Real Mic)'),
                        backgroundColor: Colors.green.shade50,
                        side: BorderSide(color: Colors.green.shade200),
                        onPressed: () async {
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(
                              content: Text('🎤 Listening for 6s... say "Bachao", "Maar dunga", etc.'),
                              duration: Duration(seconds: 3),
                            ),
                          );
                          await _voiceService.listenOnce();
                        },
                      ),
                      ActionChip(
                        avatar: const Icon(
                          Icons.record_voice_over,
                          size: 16,
                          color: Colors.red,
                        ),
                        label: const Text('Test Threat: "Maar dunga"'),
                        backgroundColor: Colors.red.shade50,
                        side: BorderSide(color: Colors.red.shade200),
                        onPressed: () {
                          _voiceService.simulateSpokenPhrase(
                            'Tujhe jaan se maar dunga',
                          );
                        },
                      ),
                      ActionChip(
                        avatar: const Icon(
                          Icons.warning_amber_rounded,
                          size: 16,
                          color: Colors.orange,
                        ),
                        label: const Text('Test Abuse: "Kutta Kamina"'),
                        backgroundColor: Colors.orange.shade50,
                        side: BorderSide(color: Colors.orange.shade200),
                        onPressed: () {
                          _voiceService.simulateSpokenPhrase(
                            'Kutta kamina insan',
                          );
                        },
                      ),
                      ActionChip(
                        avatar: const Icon(
                          Icons.volume_up,
                          size: 16,
                          color: Colors.blue,
                        ),
                        label: const Text('Test Cry: "Bachao Mujhe"'),
                        backgroundColor: Colors.blue.shade50,
                        side: BorderSide(color: Colors.blue.shade200),
                        onPressed: () {
                          _voiceService.simulateSpokenPhrase(
                            'Bachao mujhe please koi',
                          );
                        },
                      ),
                      ActionChip(
                        avatar: const Icon(
                          Icons.directions_run,
                          size: 16,
                          color: Colors.purple,
                        ),
                        label: const Text('Test Fall / Impact'),
                        backgroundColor: Colors.purple.shade50,
                        side: BorderSide(color: Colors.purple.shade200),
                        onPressed: () {
                          setState(() {
                            _movementIntensity = 0.95;
                            _currentActivity = 'Violent Movement / Fall';
                          });
                          _showDistressDialog(
                            reason: 'Severe impact and sudden fall detected',
                          );
                        },
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                ],

                const SizedBox(height: 20),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSensorRow({
    required IconData icon,
    required String title,
    required double value,
    required Color color,
    required String subtitle,
    Widget? trailingSwitch,
  }) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: color.withValues(alpha: 0.2),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Icon(icon, color: color, size: 20),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                    Text(
                      subtitle,
                      style: TextStyle(
                        fontSize: 12,
                        color: value > 0.7 ? Colors.red : Colors.grey.shade600,
                      ),
                    ),
                  ],
                ),
              ),
              if (trailingSwitch != null)
                trailingSwitch
              else
                Text(
                  '${(value * 100).toInt()}%',
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                    color: value > 0.7 ? Colors.red : color,
                  ),
                ),
            ],
          ),
          const SizedBox(height: 8),
          LinearProgressIndicator(
            value: value,
            backgroundColor: color.withValues(alpha: 0.2),
            valueColor: AlwaysStoppedAnimation<Color>(
              value > 0.7 ? Colors.red : color,
            ),
            minHeight: 6,
            borderRadius: BorderRadius.circular(3),
          ),
        ],
      ),
    );
  }

  Widget _buildPatternRow({
    required IconData icon,
    required String pattern,
    required String status,
    required Color color,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 12),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        children: [
          Icon(icon, color: color, size: 18),
          const SizedBox(width: 10),
          Expanded(child: Text(pattern, style: const TextStyle(fontSize: 14))),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.2),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Text(
              status,
              style: TextStyle(
                fontSize: 10,
                fontWeight: FontWeight.bold,
                color: color,
              ),
            ),
          ),
        ],
      ),
    );
  }

  void _showInfoDialog() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: const Text(
          'Distress Detection',
          style: TextStyle(fontWeight: FontWeight.bold),
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _buildInfoRow(
              icon: Iconsax.microphone,
              title: 'Microphone',
              description: 'Detects shouting, screaming, or loud noises',
            ),
            const Divider(),
            _buildInfoRow(
              icon: Iconsax.activity,
              title: 'Accelerometer',
              description: 'Detects running, sudden movements, or falls',
            ),
            const Divider(),
            _buildInfoRow(
              icon: Iconsax.location,
              title: 'Location Services',
              description: 'Tracks location during potential emergencies',
            ),
            const Divider(),
            _buildInfoRow(
              icon: Iconsax.radar1,
              title: 'AI Analysis',
              description: 'Combines sensor data to detect distress patterns',
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Got it'),
          ),
        ],
      ),
    );
  }

  Widget _buildInfoRow({
    required IconData icon,
    required String title,
    required String description,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: const Color(0xFF1D4ED8).withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(icon, color: const Color(0xFF1D4ED8)),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
                Text(
                  description,
                  style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
