import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/material.dart';

import 'theme/app_theme.dart';
import 'theme/responsive.dart';
import 'widgets/app_logo.dart';
import 'services/distress_monitor.dart';
import 'services/police_access.dart';
import 'screens/distress_alert_screen.dart';
import 'firebase_options.dart';
import 'services/notification_service.dart';
import 'screens/login_screen.dart';
import 'screens/signup_screen.dart';
import 'screens/forgot_password_screen.dart';
import 'screens/incident_report_screen.dart';
import 'screens/emergency_sos_screen.dart';
import 'screens/companion_mode_screen.dart';
import 'screens/distress_detection_screen.dart';
import 'screens/evidence_capture_screen.dart';
import 'screens/report_prioritization_screen.dart';
import 'screens/legal_resource_hub_screen.dart';
import 'screens/citizen_home_screen.dart';
import 'screens/police_dashboard_screen.dart';
import 'screens/verify_email_screen.dart';
import 'screens/settings_screen.dart';
import 'screens/profile_screen.dart';
import 'screens/my_reports_screen.dart';
import 'screens/manage_contacts_screen.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);
  FirebaseMessaging.onBackgroundMessage(firebaseMessagingBackgroundHandler);
  await NotificationService.init();
  runApp(const SafetyGuardianApp());
  // Resume distress detection if the user turned it on (works app-wide,
  // even after the app is closed).
  DistressMonitor.instance.restoreOnLaunch();
}

class SafetyGuardianApp extends StatelessWidget {
  const SafetyGuardianApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      navigatorKey: DistressMonitor.instance.navigatorKey,
      title: 'Safety Guardian',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light,
      builder: (context, child) =>
          ResponsiveAppShell(child: child ?? const SizedBox.shrink()),
      initialRoute: '/',
      routes: {
        '/': (context) => _SplashDelay(
          child: StreamBuilder<User?>(
            stream: FirebaseAuth.instance.userChanges(),
            builder: (context, snapshot) {
              if (snapshot.connectionState == ConnectionState.active) {
                if (snapshot.hasData) {
                  final user = snapshot.data!;

                  // Police: a @police.gov.pk email that an admin approved
                  // (police_officers/{email} in Firestore). No other check.
                  if (PoliceAccess.hasPoliceEmail(user)) {
                    return FutureBuilder<bool>(
                      future: PoliceAccess.isApprovedOfficer(user),
                      builder: (context, approved) {
                        if (approved.connectionState != ConnectionState.done) {
                          return const BrandSplash();
                        }
                        if (approved.data != true) {
                          return const _PoliceNotApprovedScreen();
                        }
                        NotificationService.saveToken();
                        return const PoliceDashboardScreen();
                      },
                    );
                  }

                  // Citizens must verify their email.
                  if (!user.emailVerified) {
                    return const VerifyEmailScreen();
                  }

                  // Fire-and-forget save of FCM token on each auth rebuild.
                  NotificationService.saveToken();
                  return const CitizenHomeScreen();
                }
                return const LoginScreen();
              }
              return const BrandSplash();
            },
          ),
        ),
        '/signup': (context) => const SignUpScreen(),
        '/report': (context) => const IncidentReportScreen(),
        '/forgot-password': (context) => const ForgotPasswordScreen(),
        '/companion': (context) => const CompanionModeScreen(),
        '/distress': (context) => const DistressDetectionScreen(),
        '/distress-alert': (context) => const DistressAlertScreen(),
        '/sos': (context) => const EmergencySOSScreen(),
        '/evidence': (context) => const EvidenceCaptureScreen(),
        // Police/admin only: citizens are sent back to their home screen.
        '/prioritization': (context) {
          // The Firestore rules also block non-approved accounts from the data.
          return PoliceAccess.hasPoliceEmail(FirebaseAuth.instance.currentUser)
              ? const ReportPrioritizationScreen()
              : const CitizenHomeScreen();
        },
        '/legal': (context) => const LegalResourceHubScreen(),
        '/settings': (context) => const SettingsScreen(),
        '/profile': (context) => const ProfileScreen(),
        '/my-reports': (context) => const MyReportsScreen(),
        '/contacts': (context) => const ManageContactsScreen(),
      },
    );
  }
}

/// Keeps the branded splash on screen for a short moment on cold start so it
/// doesn't just flash, then shows the real first screen.
class _SplashDelay extends StatefulWidget {
  final Widget child;
  const _SplashDelay({required this.child});

  @override
  State<_SplashDelay> createState() => _SplashDelayState();
}

class _SplashDelayState extends State<_SplashDelay> {
  static bool _shown = false;
  bool _ready = _shown;

  @override
  void initState() {
    super.initState();
    if (!_ready) {
      Future.delayed(const Duration(milliseconds: 1400), () {
        _shown = true;
        if (mounted) setState(() => _ready = true);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 350),
      child: _ready ? widget.child : const BrandSplash(),
    );
  }
}

/// Shown to a @police.gov.pk account that an admin hasn't approved yet.
class _PoliceNotApprovedScreen extends StatelessWidget {
  const _PoliceNotApprovedScreen();

  @override
  Widget build(BuildContext context) {
    final email = FirebaseAuth.instance.currentUser?.email ?? '';
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(28),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(
                  Icons.admin_panel_settings_outlined,
                  size: 56,
                  color: AppColors.warning,
                ),
                const SizedBox(height: 16),
                const Text(
                  'Police account not approved yet',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 8),
                Text(
                  '$email has not been approved as a police officer. '
                  'Ask your administrator to approve this account, then sign in again.',
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    color: AppColors.textMuted,
                    height: 1.4,
                  ),
                ),
                const SizedBox(height: 24),
                OutlinedButton.icon(
                  onPressed: () {
                    PoliceAccess.clearCache();
                    FirebaseAuth.instance.signOut();
                  },
                  icon: const Icon(Icons.logout),
                  label: const Text('Sign out'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
