import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/material.dart';

import 'theme/app_theme.dart';
import 'theme/responsive.dart';
import 'widgets/app_logo.dart';
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
}

class SafetyGuardianApp extends StatelessWidget {
  const SafetyGuardianApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
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
                  final isPolice =
                      user.email?.contains('@police.gov.pk') == true;

                  // Citizens must verify their email; police are exempt (trusted domain).
                  if (!isPolice && !user.emailVerified) {
                    return const VerifyEmailScreen();
                  }

                  // Fire-and-forget save of FCM token on each auth rebuild.
                  NotificationService.saveToken();

                  if (isPolice) {
                    return const PoliceDashboardScreen();
                  } else {
                    return const CitizenHomeScreen();
                  }
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
        '/sos': (context) => const EmergencySOSScreen(),
        '/evidence': (context) => const EvidenceCaptureScreen(),
        // Police/admin only: citizens are sent back to their home screen.
        '/prioritization': (context) {
          final email = FirebaseAuth.instance.currentUser?.email ?? '';
          return email.contains('@police.gov.pk')
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
