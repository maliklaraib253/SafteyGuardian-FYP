import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:iconsax/iconsax.dart';

import '../theme/app_theme.dart';
import '../theme/responsive.dart';
import '../services/distress_monitor.dart';

/// Full-screen "Are you safe?" prompt shown when distress is detected,
/// even if the app was closed. Starts SOS after 60 s with no answer.
class DistressAlertScreen extends StatefulWidget {
  const DistressAlertScreen({super.key});

  @override
  State<DistressAlertScreen> createState() => _DistressAlertScreenState();
}

class _DistressAlertScreenState extends State<DistressAlertScreen> {
  static const int _seconds = DistressMonitor.alertSeconds;
  final DistressMonitor _monitor = DistressMonitor.instance;
  int _left = _seconds;

  @override
  void initState() {
    super.initState();
    HapticFeedback.heavyImpact();
    // The countdown itself runs in DistressMonitor, so it was already going
    // while the app was closed; this screen only shows what is left.
    _left = _monitor.secondsLeft.value ?? _seconds;
    _monitor.secondsLeft.addListener(_onTick);
  }

  void _onTick() {
    final v = _monitor.secondsLeft.value;
    if (!mounted || v == null) return;
    setState(() => _left = v);
    if (v % 5 == 0) HapticFeedback.heavyImpact();
  }

  @override
  void dispose() {
    _monitor.secondsLeft.removeListener(_onTick);
    super.dispose();
  }

  void _safe() => _monitor.respondSafe();

  void _startSos() => _monitor.startSosNow();

  @override
  Widget build(BuildContext context) {
    final reason =
        (ModalRoute.of(context)?.settings.arguments as String?) ??
        'Possible emergency detected';
    return PopScope(
      canPop: false,
      child: Scaffold(
        backgroundColor: AppColors.dangerTint,
        body: SafeArea(
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 480),
              child: FillScroll(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Column(
                    children: [
                      const Spacer(),
                      SizedBox(
                        width: 168,
                        height: 168,
                        child: Stack(
                          alignment: Alignment.center,
                          children: [
                            SizedBox(
                              width: 168,
                              height: 168,
                              child: CircularProgressIndicator(
                                value: _left / _seconds,
                                strokeWidth: 8,
                                color: AppColors.danger,
                                backgroundColor: AppColors.dangerSoft,
                              ),
                            ),
                            Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Text(
                                  '$_left',
                                  style: const TextStyle(
                                    fontSize: 52,
                                    fontWeight: FontWeight.w800,
                                    color: AppColors.dangerDark,
                                  ),
                                ),
                                const Text(
                                  'seconds',
                                  style: TextStyle(color: AppColors.textMuted),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 28),
                      const Text(
                        'Are you safe?',
                        style: TextStyle(
                          fontSize: 28,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        reason,
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                          fontSize: 15,
                          color: AppColors.textMuted,
                        ),
                      ),
                      const SizedBox(height: 6),
                      const Text(
                        'If you don\'t answer, SOS will alert your trusted contacts and police.',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontSize: 13.5,
                          color: AppColors.textMuted,
                        ),
                      ),
                      const Spacer(),
                      SizedBox(
                        width: double.infinity,
                        height: 58,
                        child: FilledButton.icon(
                          key: const Key('distress_alert_safe'),
                          style: FilledButton.styleFrom(
                            backgroundColor: AppColors.success,
                          ),
                          onPressed: _safe,
                          icon: const Icon(Iconsax.tick_circle),
                          label: const Text("I'm safe"),
                        ),
                      ),
                      const SizedBox(height: 12),
                      SizedBox(
                        width: double.infinity,
                        height: 58,
                        child: FilledButton.icon(
                          key: const Key('distress_alert_sos'),
                          style: FilledButton.styleFrom(
                            backgroundColor: AppColors.danger,
                          ),
                          onPressed: _startSos,
                          icon: const Icon(Iconsax.danger),
                          label: const Text('Get help now'),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
