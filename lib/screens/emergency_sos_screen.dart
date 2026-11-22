import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:iconsax/iconsax.dart';

import 'dart:async';

import '../theme/app_theme.dart';
import '../theme/responsive.dart';
import '../services/sos_service.dart';
import '../services/call_handler_service.dart';

import 'dart:io' show Platform;

import 'package:shared_preferences/shared_preferences.dart';

import 'manage_contacts_screen.dart';

class EmergencySOSScreen extends StatefulWidget {
  const EmergencySOSScreen({super.key});

  @override
  State<EmergencySOSScreen> createState() => _EmergencySOSScreenState();
}

class _EmergencySOSScreenState extends State<EmergencySOSScreen>
    with SingleTickerProviderStateMixin {
  // Animation for SOS button
  late AnimationController _pulseAnimation;

  // State variables - ONLY ONE sosService
  final SosService _sosService = SosService();
  final CallHandlerService _callHandlerService = CallHandlerService();

  bool _isEmergencyActive = false;
  bool _isLocationSharing = false;
  bool _isCalling = false;
  int _rejectedCalls = 0;
  // Contact being called right now (-1 = police 15, null = none yet).
  int? _callingIndex;
  bool _cascadeDone = false;
  // Per-contact call outcome: true = answered, false = no answer.
  final Map<int, bool> _callResults = {};
  int? _reachedIndex;
  Timer? _ticker;
  Duration _elapsed = Duration.zero;
  bool _autoStartChecked = false;
  // Seconds left before a tapped SOS is sent (null = no countdown). Gives
  // the user a chance to cancel an accidental tap.
  int? _countdown;
  Timer? _countdownTimer;
  static const int _countdownSeconds = 5;
  // Contacts for UI display (empty by default for new accounts)
  List<Map<String, dynamic>> _trustedContacts = [];
  String _emergencyStatus = 'Ready';
  // ignore: unused_field
  Color _statusColor = AppColors.success;

  @override
  void initState() {
    super.initState();

    // Setup pulse animation for SOS button
    _pulseAnimation = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1400),
    )..repeat(reverse: true);

    _refreshContactsFromService();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Holding SOS for 3 s on the home screen opens this screen with
    // 'activate' so the alert starts straight away.
    if (_autoStartChecked) return;
    _autoStartChecked = true;
    final arg = ModalRoute.of(context)?.settings.arguments;
    if (arg == 'activate') {
      // Distress countdown already expired: start at once.
      WidgetsBinding.instance.addPostFrameCallback((_) async {
        if (!mounted || _isEmergencyActive) return;
        await _refreshContactsFromService();
        if (mounted && !_isEmergencyActive) _activateEmergency();
      });
    } else if (arg == 'countdown') {
      // Held on the home screen: give 5 seconds to cancel a mistake.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && !_isEmergencyActive) _startCountdown();
      });
    }
  }

  // Pull the real saved trusted contacts (from SharedPreferences via
  // SosService) so the UI mirrors what the SOS cascade will actually call.
  Future<void> _refreshContactsFromService() async {
    await _sosService.loadContacts();
    if (!mounted) return;
    setState(() {
      _trustedContacts = _sosService.trustedContacts
          .map(
            (c) => {
              'name': c['name'] ?? '',
              'phone': c['phone'] ?? '',
              'status': 'waiting',
              'called': false,
            },
          )
          .toList();
    });
  }

  @override
  void dispose() {
    _pulseAnimation.dispose();
    _ticker?.cancel();
    _countdownTimer?.cancel();
    _callHandlerService.stopListening();
    // The SOS may keep running in the background; just stop talking to
    // this (closed) screen.
    SosService.onAutoRepeat = null;
    SosService.onAutoRepeatDone = null;
    SosService.onPoliceFallback = null;
    super.dispose();
  }

  /// Tapping the SOS button starts a short countdown; nothing is sent
  /// until it reaches zero, so an accidental tap can be cancelled.
  void _startCountdown() {
    if (_isEmergencyActive || _countdown != null) return;
    HapticFeedback.heavyImpact();
    setState(() => _countdown = _countdownSeconds);
    _countdownTimer?.cancel();
    _countdownTimer = Timer.periodic(const Duration(seconds: 1), (t) {
      if (!mounted) {
        t.cancel();
        return;
      }
      final left = (_countdown ?? 1) - 1;
      if (left <= 0) {
        t.cancel();
        setState(() => _countdown = null);
        _activateEmergency();
      } else {
        HapticFeedback.selectionClick();
        setState(() => _countdown = left);
      }
    });
  }

  void _cancelCountdown() {
    _countdownTimer?.cancel();
    if (!mounted) return;
    setState(() => _countdown = null);
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('SOS cancelled. Nothing was sent to your contacts.'),
      ),
    );
  }

  void _sendNow() {
    _countdownTimer?.cancel();
    setState(() => _countdown = null);
    _activateEmergency();
  }

  Widget _buildCountdownOverlay() {
    final n = _countdown ?? 0;
    return Positioned.fill(
      child: Material(
        color: AppColors.danger.withValues(alpha: 0.96),
        child: SafeArea(
          child: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(28),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 420),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.sos, color: Colors.white, size: 48),
                    const SizedBox(height: 12),
                    const Text(
                      'Sending SOS in',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: Colors.white, fontSize: 18),
                    ),
                    const SizedBox(height: 8),
                    Container(
                      width: 120,
                      height: 120,
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        border: Border.all(color: Colors.white, width: 4),
                      ),
                      child: Text(
                        '$n',
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 56,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ),
                    const SizedBox(height: 16),
                    const Text(
                      'Your trusted contacts will be texted and called with '
                      'your location. Tapped by mistake? Cancel now.',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: Colors.white, height: 1.4),
                    ),
                    const SizedBox(height: 28),
                    SizedBox(
                      width: double.infinity,
                      height: 58,
                      child: FilledButton(
                        key: const Key('sos_cancel_countdown'),
                        style: FilledButton.styleFrom(
                          backgroundColor: Colors.white,
                          foregroundColor: AppColors.danger,
                          textStyle: const TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        onPressed: _cancelCountdown,
                        child: const Text('Cancel'),
                      ),
                    ),
                    const SizedBox(height: 12),
                    TextButton(
                      key: const Key('sos_send_now'),
                      style: TextButton.styleFrom(
                        foregroundColor: Colors.white,
                      ),
                      onPressed: _sendNow,
                      child: const Text('Send now'),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  // Activate emergency mode
  void _activateEmergency() async {
    if (_isEmergencyActive) return;
    if (SosService.sessionActive || SosService.anySosRunning) {
      // Already running (e.g. started by distress detection): just show it.
      await _attachToRunningSos();
      return;
    }
    _elapsed = Duration.zero;
    _ticker?.cancel();
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() => _elapsed += const Duration(seconds: 1));
    });
    setState(() {
      _isEmergencyActive = true;
      _isLocationSharing = true;
      _isCalling = true;
      _emergencyStatus = 'EMERGENCY ACTIVE';
      _statusColor = AppColors.danger;
    });

    // Start auto-reject handler (trusted contacts are allowed to call back)
    _rejectedCalls = 0;
    _callHandlerService.onCallRejected = (number) {
      if (!mounted) return;
      setState(() => _rejectedCalls++);
    };
    await _callHandlerService.startListening(
      true,
      trustedNumbers: _trustedContacts
          .map((c) => (c['phone'] ?? '').toString())
          .where((p) => p.isNotEmpty)
          .toList(),
    );

    // Start REAL SOS (calls and SMS) - Trusted contacts first, Police last
    _callingIndex = null;
    _cascadeDone = false;
    _callResults.clear();
    _safeMessageSent = false;
    _reachedIndex = null;
    _sosService.onCallResult = (i, answered) {
      if (mounted) setState(() => _callResults[i] = answered);
    };
    _sosService.onContactReached = (i) {
      if (mounted) setState(() => _reachedIndex = i);
    };
    _sosService.onSmsResult = (phone, sent, error) {
      // Only while SOS is on, and only the latest warning (no queue of bars
      // that keeps showing after SOS has been stopped).
      if (sent || !mounted || !_isEmergencyActive) return;
      ScaffoldMessenger.of(context).hideCurrentSnackBar();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          backgroundColor: AppColors.danger,
          duration: const Duration(seconds: 6),
          content: Text('SMS to $phone not sent: $error'),
        ),
      );
    };
    _wireSosCallbacks();
    _sosService.onCalling = (i) {
      if (!mounted) return;
      if (i == -1) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            duration: Duration(seconds: 8),
            content: Text(
              'Android only lets the phone dialer call 15. Tap Call in the dialer to reach the police.',
            ),
          ),
        );
      }
      setState(() {
        _callingIndex = i;
        _isCalling = false;
      });
    };
    var started = false;
    try {
      started = await _sosService.startSos();
    } finally {
      if (mounted) {
        setState(() {
          _isCalling = false;
          _cascadeDone = true;
          _isLocationSharing = _sosService.isSharingLocation;
        });
      }
    }
    if (!mounted) return;
    if (!started) {
      // Another SOS is still calling contacts: don't ask yet.
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('An SOS is already in progress. Please wait.'),
        ),
      );
      return;
    }

    // Every contact (and police, if nobody answered) has been called:
    // now ask how the user is.
    _showResponseOptions();
  }

  /// Listens to the shared SOS (repeats, police fallback, end of a round).
  void _wireSosCallbacks() {
    SosService.onPoliceFallback = (reason) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).hideCurrentSnackBar();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          backgroundColor: AppColors.danger,
          duration: const Duration(seconds: 8),
          content: Text(reason),
        ),
      );
    };
    SosService.onAutoRepeatDone = () {
      if (!mounted) return;
      setState(() => _cascadeDone = true);
      _showResponseOptions();
    };
    SosService.onAutoRepeat = (round) {
      if (!mounted) return;
      // Close the old question while everyone is called again; it comes
      // back when the calls are over.
      if (_responseDialogOpen) {
        Navigator.of(context, rootNavigator: true).pop();
      }
      setState(() {
        _cascadeDone = false;
        _callResults.clear();
        _reachedIndex = null;
        _callingIndex = null;
        _emergencyStatus = 'NO RESPONSE - SOS REPEATED';
        _statusColor = AppColors.danger;
      });
      ScaffoldMessenger.of(context).hideCurrentSnackBar();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          backgroundColor: AppColors.danger,
          duration: const Duration(seconds: 8),
          content: Text(
            'No answer from you for ${SosService.noResponseRepeat.inMinutes} '
            'minutes: SOS sent again (repeat $round of '
            '${SosService.maxAutoRepeats}).',
          ),
        ),
      );
    };
  }

  /// Distress detection may have started the SOS while the app was in the
  /// background. Show that running SOS instead of starting a second one.
  Future<void> _attachToRunningSos() async {
    if (_isEmergencyActive) return;
    final started = SosService.startedAt ?? DateTime.now();
    _elapsed = DateTime.now().difference(started);
    _ticker?.cancel();
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() => _elapsed += const Duration(seconds: 1));
    });
    setState(() {
      _isEmergencyActive = true;
      _isCalling = SosService.cascadeRunning;
      _cascadeDone = !SosService.cascadeRunning;
      _isLocationSharing = _sosService.isSharingLocation;
      _emergencyStatus = 'EMERGENCY ACTIVE';
      _statusColor = AppColors.danger;
    });
    _wireSosCallbacks();
    _rejectedCalls = 0;
    _callHandlerService.onCallRejected = (number) {
      if (!mounted) return;
      setState(() => _rejectedCalls++);
    };
    await _callHandlerService.startListening(
      true,
      trustedNumbers: _trustedContacts
          .map((c) => (c['phone'] ?? '').toString())
          .where((p) => p.isNotEmpty)
          .toList(),
    );
    if (mounted && !SosService.cascadeRunning) _showResponseOptions();
  }

  bool _responseDialogOpen = false;

  // Show response options after emergency
  void _showResponseOptions() {
    if (_responseDialogOpen || !_isEmergencyActive) return;
    _responseDialogOpen = true;
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: const Text(
          'Are you safe?',
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              'Let your contacts know your status',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 14, color: Colors.grey),
            ),
            const SizedBox(height: 8),
            // If neither button is pressed, the SOS repeats by itself.
            StreamBuilder<int>(
              stream: Stream.periodic(const Duration(seconds: 1), (i) => i),
              builder: (_, _) {
                final at = SosService.nextAutoRepeat.value;
                if (at == null) return const SizedBox.shrink();
                final left = at.difference(DateTime.now());
                if (left.isNegative) return const SizedBox.shrink();
                final m = left.inMinutes;
                final s = (left.inSeconds % 60).toString().padLeft(2, '0');
                return Text(
                  'No answer? SOS will be sent again in $m:$s',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: Colors.red.shade700,
                  ),
                );
              },
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: GestureDetector(
                    onTap: () async {
                      Navigator.pop(context);
                      if (await _confirmSafe()) {
                        _updateEmergencyStatus('safe');
                      } else if (mounted) {
                        _showResponseOptions();
                      }
                    },
                    child: Container(
                      padding: const EdgeInsets.all(20),
                      decoration: BoxDecoration(
                        color: Colors.green.shade50,
                        borderRadius: BorderRadius.circular(15),
                        border: Border.all(color: Colors.green.shade200),
                      ),
                      child: Column(
                        children: [
                          Icon(
                            Icons.check_circle,
                            color: Colors.green.shade600,
                            size: 40,
                          ),
                          const SizedBox(height: 10),
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
                      Navigator.pop(context);
                      _updateEmergencyStatus('help');
                    },
                    child: Container(
                      padding: const EdgeInsets.all(20),
                      decoration: BoxDecoration(
                        color: Colors.red.shade50,
                        borderRadius: BorderRadius.circular(15),
                        border: Border.all(color: Colors.red.shade200),
                      ),
                      child: Column(
                        children: [
                          Icon(
                            Icons.warning,
                            color: Colors.red.shade600,
                            size: 40,
                          ),
                          const SizedBox(height: 10),
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
          ],
        ),
      ),
    ).then((_) => _responseDialogOpen = false);
  }

  // Update emergency status based on user response
  void _updateEmergencyStatus(String status) {
    // Status used by the auto-reply SMS sent to rejected callers.
    SharedPreferences.getInstance().then(
      (prefs) => prefs.setString(
        CallHandlerService.autoReplyStatusKey,
        status == 'safe' ? "I'm Safe" : 'Help Needed',
      ),
    );
    if (status == 'safe') {
      // Clear any SOS warnings still on screen or waiting in the queue.
      ScaffoldMessenger.of(context).clearSnackBars();
      _notifyContactsSafe();
      _callHandlerService.stopListening();
    }
    setState(() {
      if (status == 'safe') {
        _emergencyStatus = 'You are safe';
        _statusColor = AppColors.success;
        _ticker?.cancel();
        _isEmergencyActive = false;
        _isLocationSharing = false;
        _callHandlerService.setEmergencyMode(false);
        _sosService.stopSos();
      } else {
        _emergencyStatus = 'HELP REQUIRED';
        _statusColor = AppColors.danger;
        _isEmergencyActive = true;
        _isLocationSharing = true; // live location texts every 2 min
        _callHandlerService.setEmergencyMode(true);
      }
    });
    if (status != 'safe') {
      // Still in danger: text everyone again and call Police 15 now.
      _cascadeDone = false;
      _sosService.escalateHelpNeeded().whenComplete(() {
        if (mounted) {
          setState(() {
            _cascadeDone = true;
            _isLocationSharing = _sosService.isSharingLocation;
          });
        }
      });
    }

    // "I'm safe" shows its own green summary once the texts have gone out.
    if (status != 'safe') {
      ScaffoldMessenger.of(context).hideCurrentSnackBar();
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          backgroundColor: AppColors.danger,
          content: Text(
            'Contacts alerted again. Opening dialer for Police 15.',
          ),
        ),
      );
    }
  }

  bool _safeMessageSent = false;

  /// Second step before "I'm safe" goes out, so a stray tap (for example
  /// when coming back from a call) can never message every contact.
  Future<bool> _confirmSafe() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Are you really safe?'),
        content: const Text(
          "This stops SOS and texts all your trusted contacts that you're safe.",
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('No, keep SOS on'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: AppColors.success),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text("Yes, I'm safe"),
          ),
        ],
      ),
    );
    return ok == true;
  }

  /// Lets every trusted contact know the user is safe now.
  Future<void> _notifyContactsSafe() async {
    // Only once per SOS, and only after the user confirmed.
    if (_safeMessageSent) return;
    _safeMessageSent = true;
    debugPrint('[SOS] Sending "I\'m safe" to contacts (user confirmed)');
    var sent = 0;
    var total = 0;
    for (final contact in _trustedContacts) {
      final phone = (contact['phone'] ?? '').toString();
      if (phone.isEmpty) continue;
      total++;
      try {
        if (await _sosService.sendSms(
          phone,
          "I'm safe now. Please ignore my previous SOS alert. - Safety Guardian",
        )) {
          sent++;
        }
      } catch (_) {}
      await Future.delayed(const Duration(seconds: 2));
    }
    if (!mounted || total == 0) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        backgroundColor: sent == total ? AppColors.success : AppColors.danger,
        content: Text(
          sent == total
              ? '"I\'m safe" message sent to all $total contacts'
              : '"I\'m safe" sent to $sent of $total contacts',
        ),
      ),
    );
  }

  // Toggle location sharing
  void _toggleLocationSharing() {
    if (_isLocationSharing) {
      _sosService.stopLocationUpdates();
    } else {
      _sosService.startLocationUpdates();
    }
    setState(() {
      _isLocationSharing = _sosService.isSharingLocation;
    });
    if (Platform.isIOS) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'On iPhone your location is sent once, in the SOS message',
          ),
        ),
      );
      return;
    }

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          _isLocationSharing
              ? 'Live location sharing activated'
              : 'Location sharing stopped',
        ),
        backgroundColor: _isLocationSharing ? Colors.green : Colors.orange,
      ),
    );
  }

  // Add new trusted contact

  // ---------------------------------------------------------------------------
  // UI — "Calm Shield"
  // ---------------------------------------------------------------------------

  String get _elapsedLabel {
    final m = (_elapsed.inMinutes).toString().padLeft(2, '0');
    final s = (_elapsed.inSeconds % 60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  @override
  Widget build(BuildContext context) {
    final active = _isEmergencyActive;
    final pad = Responsive.pagePadding(context);

    return PopScope(
      // Back always works. During the countdown it cancels the SOS; while
      // SOS is active the user can leave this screen and SOS keeps running
      // in the background (the red bar on the home screen brings them back).
      canPop: _countdown == null,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) {
          // Back during the countdown = cancel it.
          if (_countdown != null) _cancelCountdown();
          return;
        }
        if (active) {
          ScaffoldMessenger.maybeOf(context)?.showSnackBar(
            const SnackBar(
              content: Text(
                "SOS is still running. Open it again and tap \"I'm safe\" to stop it.",
              ),
            ),
          );
        }
      },
      child: Scaffold(
        backgroundColor: active ? AppColors.dangerTint : AppColors.background,
        appBar: AppBar(
          title: const Text('Emergency SOS'),
          backgroundColor: active ? AppColors.dangerTint : AppColors.surface,
          shape: active ? const Border() : null,
        ),
        body: Stack(
          children: [
            SafeArea(
              top: false,
              child: ContentWidth(
                maxWidth: 560,
                child: ListView(
                  padding: EdgeInsets.fromLTRB(pad, 16, pad, 28),
                  children: [
                    _buildStatusHeader(),
                    if (active) _buildPoliceUnreachedBanner(),
                    const SizedBox(height: 20),
                    Center(
                      child: active ? _buildActiveRings() : _buildSosButton(),
                    ),
                    const SizedBox(height: 20),
                    Text(
                      active
                          ? 'Help is on the way'
                          : _emergencyStatus == 'You are safe'
                          ? 'Glad you are safe'
                          : 'Tap SOS in an emergency',
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        fontSize: 22,
                        fontWeight: FontWeight.w700,
                        letterSpacing: -0.3,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      active
                          ? 'Your live location is being shared with your trusted contacts and police.'
                          : 'We will call and text your trusted contacts first, then police (15), with your live location.',
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        fontSize: 14,
                        color: AppColors.textMuted,
                        height: 1.45,
                      ),
                    ),
                    const SizedBox(height: 24),
                    _buildContactsCard(),
                    const SizedBox(height: 12),
                    _buildCallBlockRow(),
                    const SizedBox(height: 12),
                    if (active) _buildLocationRow() else _buildFeaturesCard(),
                    const SizedBox(height: 20),
                    if (active)
                      ..._buildActiveButtons()
                    else
                      _buildCallPoliceButton(),
                  ],
                ),
              ),
            ),
            if (_isCalling)
              Container(
                color: AppColors.text.withValues(alpha: 0.45),
                child: Center(
                  child: Container(
                    margin: const EdgeInsets.all(32),
                    padding: const EdgeInsets.all(24),
                    decoration: BoxDecoration(
                      color: AppColors.surface,
                      borderRadius: BorderRadius.circular(AppRadius.lg),
                    ),
                    child: const Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        CircularProgressIndicator(color: AppColors.danger),
                        SizedBox(height: 16),
                        Text(
                          'Activating emergency…',
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        SizedBox(height: 4),
                        Text(
                          'Alerting your contacts, then police (15)',
                          style: TextStyle(
                            fontSize: 13,
                            color: AppColors.textMuted,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            if (_countdown != null) _buildCountdownOverlay(),
          ],
        ),
      ),
    );
  }

  Widget _buildStatusHeader() {
    final active = _isEmergencyActive;
    final safe = _emergencyStatus == 'You are safe';
    final bg = active
        ? AppColors.danger
        : (safe ? AppColors.successSoft : AppColors.surface);
    final fg = active
        ? Colors.white
        : (safe ? AppColors.success : AppColors.textMuted);
    final label = active
        ? (_emergencyStatus == 'HELP REQUIRED' ? 'HELP REQUIRED' : 'SOS ACTIVE')
        : (safe ? 'YOU ARE SAFE' : 'READY');
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          decoration: BoxDecoration(
            color: bg,
            borderRadius: BorderRadius.circular(999),
            border: active || safe ? null : Border.all(color: AppColors.border),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 8,
                height: 8,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: active
                      ? Colors.white
                      : (safe ? AppColors.success : AppColors.success),
                ),
              ),
              const SizedBox(width: 8),
              Text(
                label,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.8,
                  color: fg,
                ),
              ),
            ],
          ),
        ),
        if (active) ...[
          const SizedBox(width: 10),
          Text(
            _elapsedLabel,
            style: const TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.w700,
              color: AppColors.dangerDark,
              fontFeatures: [FontFeature.tabularFigures()],
            ),
          ),
        ],
        if (_isLocationSharing) ...[
          const SizedBox(width: 10),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            decoration: BoxDecoration(
              color: AppColors.successSoft,
              borderRadius: BorderRadius.circular(999),
            ),
            child: const Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Iconsax.location, size: 13, color: AppColors.success),
                SizedBox(width: 4),
                Text(
                  'LIVE',
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                    color: AppColors.success,
                  ),
                ),
              ],
            ),
          ),
        ],
      ],
    );
  }

  /// Idle state: big red button with a soft pulse. One tap activates.
  Widget _buildSosButton() {
    return AnimatedBuilder(
      animation: _pulseAnimation,
      builder: (context, _) {
        final t = _pulseAnimation.value;
        return Semantics(
          button: true,
          label: 'Activate SOS',
          child: GestureDetector(
            key: const Key('sos_activate_button'),
            onTap: _startCountdown,
            child: SizedBox(
              width: 200,
              height: 200,
              child: Stack(
                alignment: Alignment.center,
                children: [
                  Container(
                    width: 176 + 24 * t,
                    height: 176 + 24 * t,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: AppColors.dangerSoft.withValues(
                        alpha: 1 - t * 0.6,
                      ),
                    ),
                  ),
                  Container(
                    width: 156,
                    height: 156,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: AppColors.danger,
                      boxShadow: [
                        BoxShadow(
                          color: AppColors.danger.withValues(alpha: 0.3),
                          blurRadius: 24,
                          offset: const Offset(0, 10),
                        ),
                      ],
                    ),
                    child: const Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Text(
                          'SOS',
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 38,
                            fontWeight: FontWeight.w800,
                            letterSpacing: 1.5,
                          ),
                        ),
                        Text(
                          'Tap to alert',
                          style: TextStyle(color: Colors.white, fontSize: 13),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  /// Active state: concentric rings (188 / 140 / 96) around a shield.
  Widget _buildActiveRings() {
    return AnimatedBuilder(
      animation: _pulseAnimation,
      builder: (context, _) {
        final t = _pulseAnimation.value;
        return SizedBox(
          width: 200,
          height: 200,
          child: Stack(
            alignment: Alignment.center,
            children: [
              Container(
                width: 188 + 8 * t,
                height: 188 + 8 * t,
                decoration: const BoxDecoration(
                  shape: BoxShape.circle,
                  color: AppColors.dangerSoft,
                ),
              ),
              Container(
                width: 140,
                height: 140,
                decoration: const BoxDecoration(
                  shape: BoxShape.circle,
                  color: Color(0xFFFECACA),
                ),
              ),
              Container(
                width: 96,
                height: 96,
                decoration: const BoxDecoration(
                  shape: BoxShape.circle,
                  color: AppColors.danger,
                ),
                child: const Icon(
                  Iconsax.shield_tick,
                  color: Colors.white,
                  size: 40,
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _card({required Widget child, EdgeInsets? padding}) {
    return Container(
      padding: padding ?? const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(AppRadius.lg),
        border: Border.all(color: AppColors.border),
      ),
      child: child,
    );
  }

  Widget _buildContactsCard() {
    return _card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Expanded(
                child: Text(
                  'Trusted contacts',
                  style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
                ),
              ),
              TextButton.icon(
                onPressed: () async {
                  await Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => const ManageContactsScreen(),
                    ),
                  );
                  await _refreshContactsFromService();
                },
                icon: const Icon(Iconsax.setting_2, size: 16),
                label: const Text('Manage'),
              ),
            ],
          ),
          const SizedBox(height: 4),
          if (_trustedContacts.isEmpty)
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(vertical: 18, horizontal: 16),
              decoration: BoxDecoration(
                color: AppColors.background,
                borderRadius: BorderRadius.circular(AppRadius.md),
              ),
              child: const Column(
                children: [
                  Icon(Iconsax.user_add, color: AppColors.textSubtle, size: 30),
                  SizedBox(height: 8),
                  Text(
                    'No trusted contacts yet',
                    style: TextStyle(
                      fontWeight: FontWeight.w600,
                      fontSize: 14.5,
                    ),
                  ),
                  SizedBox(height: 4),
                  Text(
                    'Tap "Manage" to add family or friends who should be alerted.',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 12.5,
                      color: AppColors.textMuted,
                    ),
                  ),
                ],
              ),
            )
          else
            for (var i = 0; i < _trustedContacts.length; i++) ...[
              if (i > 0) const Divider(height: 20),
              _buildContactRow(_trustedContacts[i], i),
            ],
          if (_isEmergencyActive) ...[
            const Divider(height: 20),
            Row(
              children: [
                const CircleAvatar(
                  radius: 18,
                  backgroundColor: AppColors.dangerSoft,
                  child: Icon(
                    Iconsax.shield_tick,
                    size: 18,
                    color: AppColors.danger,
                  ),
                ),
                const SizedBox(width: 12),
                const Expanded(
                  child: Text(
                    'Police · 15',
                    style: TextStyle(
                      fontSize: 14.5,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                Flexible(
                  child: Text(
                    _callingIndex == -1
                        ? (_cascadeDone ? 'Dialer opened' : 'Opening dialer…')
                        : (_reachedIndex != null ? 'Not needed' : 'Last'),
                    style: TextStyle(
                      fontSize: 12.5,
                      fontWeight: FontWeight.w600,
                      color: _callingIndex == -1
                          ? AppColors.danger
                          : AppColors.textSubtle,
                    ),
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildContactRow(Map<String, dynamic> contact, int index) {
    final name = (contact['name'] ?? '').toString();
    final phone = (contact['phone'] ?? '').toString();
    final active = _isEmergencyActive;

    // The SOS cascade calls the first contact and texts everyone.
    final calling = _callingIndex;
    final result = _callResults[index];
    final String status;
    final Color statusColor;
    if (!active) {
      status = 'Call #${index + 1}';
      statusColor = AppColors.textSubtle;
    } else if (_reachedIndex == index || result == true) {
      status = 'Answered';
      statusColor = AppColors.success;
    } else if (calling == index && result == null) {
      status = 'Calling…';
      statusColor = AppColors.danger;
    } else if (result == false) {
      status = 'No answer';
      statusColor = AppColors.warning;
    } else if (_reachedIndex != null) {
      status = 'SMS sent';
      statusColor = AppColors.textMuted;
    } else if (calling == null) {
      status = 'Sending SMS…';
      statusColor = AppColors.textSubtle;
    } else {
      status = 'SMS sent · next';
      statusColor = AppColors.textMuted;
    }

    return Row(
      children: [
        CircleAvatar(
          radius: 18,
          backgroundColor: AppColors.primarySoft,
          child: Text(
            name.isNotEmpty ? name[0].toUpperCase() : '?',
            style: const TextStyle(
              color: AppColors.primary,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                name,
                style: const TextStyle(
                  fontSize: 14.5,
                  fontWeight: FontWeight.w600,
                ),
              ),
              Text(
                phone,
                style: const TextStyle(
                  fontSize: 12,
                  color: AppColors.textMuted,
                ),
              ),
            ],
          ),
        ),
        Flexible(
          child: Text(
            status,
            style: TextStyle(
              fontSize: 12.5,
              fontWeight: FontWeight.w600,
              color: statusColor,
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildCallBlockRow() {
    final String subtitle;
    if (!Platform.isAndroid) {
      subtitle = 'Not supported on iPhone (iOS does not allow call rejection)';
    } else if (_isEmergencyActive) {
      subtitle = 'Trusted contacts can still call you';
    } else {
      subtitle = 'Turns on during SOS · trusted contacts still get through';
    }
    return _card(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      child: Row(
        children: [
          _iconBox(Iconsax.call_slash, AppColors.danger, AppColors.dangerSoft),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Unknown calls blocked',
                  style: TextStyle(fontSize: 14.5, fontWeight: FontWeight.w600),
                ),
                Text(
                  subtitle,
                  style: const TextStyle(
                    fontSize: 12,
                    color: AppColors.textMuted,
                  ),
                ),
              ],
            ),
          ),
          if (_isEmergencyActive && Platform.isAndroid)
            Text(
              '$_rejectedCalls',
              style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w700),
            ),
        ],
      ),
    );
  }

  Widget _buildLocationRow() {
    return _card(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      child: Row(
        children: [
          _iconBox(Iconsax.location, AppColors.success, AppColors.successSoft),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Live location',
                  style: TextStyle(fontSize: 14.5, fontWeight: FontWeight.w600),
                ),
                Text(
                  Platform.isIOS
                      ? 'Sent once in the SOS message'
                      : _isLocationSharing
                      ? 'Texting contacts every 2 min'
                      : 'Updates paused',
                  style: const TextStyle(
                    fontSize: 12,
                    color: AppColors.textMuted,
                  ),
                ),
              ],
            ),
          ),
          Switch(
            value: _isLocationSharing,
            onChanged: (_) => _toggleLocationSharing(),
          ),
        ],
      ),
    );
  }

  Widget _buildFeaturesCard() {
    return _card(
      child: Column(
        children: [
          _featureRow(
            Iconsax.call,
            'Texts all contacts, then calls each one',
            'Stops when someone answers, else Police 15',
          ),
          const Divider(height: 22),
          _featureRow(
            Iconsax.location,
            'Location updates',
            'Fresh location texted every 2 minutes',
          ),
          const Divider(height: 22),
          _featureRow(
            Iconsax.message_text,
            'Automatic replies',
            "Callers get “I'm Safe” or “Help Needed”",
          ),
          const Divider(height: 22),
          _featureRow(
            Iconsax.wallet_minus,
            'Works without balance',
            'Emergency numbers only',
          ),
        ],
      ),
    );
  }

  Widget _featureRow(IconData icon, String title, String subtitle) {
    return Row(
      children: [
        _iconBox(icon, AppColors.primary, AppColors.primarySoft),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: const TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                ),
              ),
              Text(
                subtitle,
                style: const TextStyle(
                  fontSize: 12,
                  color: AppColors.textMuted,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _iconBox(IconData icon, Color fg, Color bg) {
    return Container(
      width: 36,
      height: 36,
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Icon(icon, size: 19, color: fg),
    );
  }

  List<Widget> _buildActiveButtons() {
    return [
      SizedBox(
        height: 56,
        child: FilledButton.icon(
          key: const Key('sos_safe_button'),
          style: FilledButton.styleFrom(backgroundColor: AppColors.text),
          onPressed: () async {
            if (await _confirmSafe()) _updateEmergencyStatus('safe');
          },
          icon: const Icon(Iconsax.tick_circle),
          label: const Text("I'm safe now"),
        ),
      ),
      const SizedBox(height: 10),
      _buildCallPoliceButton(),
    ];
  }

  /// Shown while the app could not get a call through to Police 15 (Android
  /// only opened the dialer). One big button to try again.
  Widget _buildPoliceUnreachedBanner() {
    return ValueListenableBuilder<bool>(
      valueListenable: SosService.policeUnreached,
      builder: (context, unreached, _) {
        if (!unreached) return const SizedBox.shrink();
        return Container(
          margin: const EdgeInsets.only(top: 12),
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: AppColors.surface,
            borderRadius: BorderRadius.circular(AppRadius.lg),
            border: Border.all(color: AppColors.danger, width: 2),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text(
                'Police 15 was NOT called',
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w800,
                  color: AppColors.danger,
                ),
              ),
              const SizedBox(height: 4),
              const Text(
                'Your contacts were asked to call 15 for you. '
                'If you can, call now.',
                style: TextStyle(fontSize: 13, color: AppColors.textMuted),
              ),
              const SizedBox(height: 10),
              SizedBox(
                height: 56,
                child: FilledButton.icon(
                  key: const Key('sos_police_unreached_call'),
                  style: FilledButton.styleFrom(
                    backgroundColor: AppColors.danger,
                  ),
                  onPressed: () {
                    SosService.policeCalledManually();
                    _sosService.makeCall('15');
                  },
                  icon: const Icon(Iconsax.call),
                  label: const FittedBox(
                    fit: BoxFit.scaleDown,
                    child: Text(
                      'Call 15 now',
                      style: TextStyle(
                        fontSize: 17,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildCallPoliceButton() {
    return SizedBox(
      height: 56,
      child: OutlinedButton.icon(
        key: const Key('sos_call_police_button'),
        style: OutlinedButton.styleFrom(
          foregroundColor: AppColors.danger,
          side: const BorderSide(color: AppColors.danger, width: 1.5),
          backgroundColor: AppColors.surface,
        ),
        onPressed: () => _sosService.makeCall('15'),
        icon: const Icon(Iconsax.call),
        label: const Text('Call police · 15'),
      ),
    );
  }
}
