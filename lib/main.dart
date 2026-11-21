import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/material.dart';

import 'theme/app_theme.dart';
import 'theme/responsive.dart';
import 'widgets/app_logo.dart';
import 'services/distress_monitor.dart';
import 'services/police_access.dart';
import 'services/admin_access.dart';
import 'screens/admin/admin_portal_screen.dart';
import 'widgets/account_gate.dart';
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
                  // Watched live: approval opens the dashboard at once, and
                  // removal by an admin closes it at once.
                  if (PoliceAccess.hasPoliceEmail(user)) {
                    return StreamBuilder<bool>(
                      stream: PoliceAccess.watchApproval(user),
                      builder: (context, approved) {
                        if (approved.hasError) {
                          return const _PoliceNotApprovedScreen();
                        }
                        if (!approved.hasData) return const BrandSplash();
                        if (approved.data != true) {
                          return const _PoliceNotApprovedScreen();
                        }
                        NotificationService.saveToken();
                        return const PoliceDashboardScreen();
                      },
                    );
                  }

                  // Admins: listed in admins/{email}. Checked once, then cached.
                  final knownAdmin = AdminAccess.cached(user);
                  if (knownAdmin == true) return const AdminPortalScreen();
                  if (knownAdmin == null) {
                    return FutureBuilder<bool>(
                      future: AdminAccess.isAdmin(user),
                      builder: (context, admin) {
                        if (admin.connectionState != ConnectionState.done) {
                          return const BrandSplash();
                        }
                        if (admin.data == true) {
                          return const AdminPortalScreen();
                        }
                        return _citizenHome(user);
                      },
                    );
                  }
                  return _citizenHome(user);
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

/// Citizens must verify their email; a blocked account sees only SOS.
Widget _citizenHome(User user) {
  if (!user.emailVerified) return const VerifyEmailScreen();
  // Fire-and-forget save of FCM token on each auth rebuild.
  NotificationService.saveToken();
  return const AccountGate(child: CitizenHomeScreen());
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
/// The officer can send an approval request that appears in the admin portal.
class _PoliceNotApprovedScreen extends StatefulWidget {
  const _PoliceNotApprovedScreen();

  @override
  State<_PoliceNotApprovedScreen> createState() =>
      _PoliceNotApprovedScreenState();
}

class _PoliceNotApprovedScreenState extends State<_PoliceNotApprovedScreen> {
  final _form = GlobalKey<FormState>();
  final _name = TextEditingController();
  final _station = TextEditingController();
  final _badge = TextEditingController();
  final _phone = TextEditingController();
  bool _sending = false;
  bool _editing = false;

  String get _email =>
      (FirebaseAuth.instance.currentUser?.email ?? '').trim().toLowerCase();

  DocumentReference<Map<String, dynamic>> get _ref =>
      FirebaseFirestore.instance.collection('police_requests').doc(_email);

  @override
  void dispose() {
    _name.dispose();
    _station.dispose();
    _badge.dispose();
    _phone.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    if (!(_form.currentState?.validate() ?? false)) return;
    setState(() => _sending = true);
    try {
      await _ref.set({
        'email': _email,
        'uid': FirebaseAuth.instance.currentUser?.uid,
        'name': _name.text.trim(),
        'station': _station.text.trim(),
        'badgeNumber': _badge.text.trim(),
        'phone': _phone.text.trim(),
        'status': 'pending',
        'requestedAt': FieldValue.serverTimestamp(),
      });
      if (mounted) setState(() => _editing = false);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not send the request: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  /// Re-checks approval: clears the cache and reloads the user so the root
  /// StreamBuilder rebuilds.
  Future<void> _checkAgain() async {
    PoliceAccess.clearCache();
    await FirebaseAuth.instance.currentUser?.reload();
  }

  Widget _formView({String? rejectedReason}) {
    return Form(
      key: _form,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (rejectedReason != null)
            Container(
              padding: const EdgeInsets.all(12),
              margin: const EdgeInsets.only(bottom: 12),
              decoration: BoxDecoration(
                color: AppColors.dangerSoft,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Text(
                'Your last request was rejected: $rejectedReason',
                style: const TextStyle(color: AppColors.danger),
              ),
            ),
          const Text(
            'Request access',
            style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 8),
          TextFormField(
            controller: _name,
            decoration: const InputDecoration(labelText: 'Full name'),
            validator: (v) =>
                (v ?? '').trim().isEmpty ? 'Name is required' : null,
          ),
          TextFormField(
            controller: _station,
            decoration: const InputDecoration(labelText: 'Police station'),
            validator: (v) =>
                (v ?? '').trim().isEmpty ? 'Station is required' : null,
          ),
          TextFormField(
            controller: _badge,
            decoration: const InputDecoration(labelText: 'Badge / belt number'),
            validator: (v) =>
                (v ?? '').trim().isEmpty ? 'Badge number is required' : null,
          ),
          TextFormField(
            controller: _phone,
            keyboardType: TextInputType.phone,
            decoration: const InputDecoration(labelText: 'Phone (optional)'),
          ),
          const SizedBox(height: 16),
          FilledButton.icon(
            onPressed: _sending ? null : _send,
            icon: _sending
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.send),
            label: const Text('Send request to administrator'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(28),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 460),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
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
                    '$_email needs administrator approval before it can open '
                    'the Police Command Center.',
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      color: AppColors.textMuted,
                      height: 1.4,
                    ),
                  ),
                  const SizedBox(height: 24),
                  StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
                    stream: _ref.snapshots(),
                    builder: (context, snap) {
                      if (!snap.hasData) {
                        return const Center(child: CircularProgressIndicator());
                      }
                      final req = snap.data!.data();
                      if (req == null || _editing) return _formView();
                      if (req['status'] == 'rejected') {
                        return _formView(
                          rejectedReason: (req['rejectionReason'] ?? '')
                              .toString(),
                        );
                      }
                      return Container(
                        padding: const EdgeInsets.all(14),
                        decoration: BoxDecoration(
                          color: AppColors.warningSoft,
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Column(
                          children: [
                            const Text(
                              'Request sent. You will get access as soon as an '
                              'administrator approves it.',
                              textAlign: TextAlign.center,
                              style: TextStyle(color: AppColors.warning),
                            ),
                            TextButton(
                              onPressed: () {
                                _name.text = (req['name'] ?? '').toString();
                                _station.text = (req['station'] ?? '')
                                    .toString();
                                _badge.text = (req['badgeNumber'] ?? '')
                                    .toString();
                                _phone.text = (req['phone'] ?? '').toString();
                                setState(() => _editing = true);
                              },
                              child: const Text('Edit request'),
                            ),
                          ],
                        ),
                      );
                    },
                  ),
                  const SizedBox(height: 16),
                  OutlinedButton.icon(
                    onPressed: _checkAgain,
                    icon: const Icon(Icons.refresh),
                    label: const Text('I have been approved, check again'),
                  ),
                  const SizedBox(height: 8),
                  TextButton.icon(
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
      ),
    );
  }
}
