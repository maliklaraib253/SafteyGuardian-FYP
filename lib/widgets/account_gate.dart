import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../theme/app_theme.dart';

/// Shows [child] (the citizen home) unless an administrator has blocked this
/// account. A blocked user still gets Emergency SOS and a direct call to 15,
/// because SOS works from their own phone and must never be taken away.
class AccountGate extends StatelessWidget {
  final Widget child;
  const AccountGate({super.key, required this.child});

  @override
  Widget build(BuildContext context) {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return child;
    return StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
      stream: FirebaseFirestore.instance
          .collection('users')
          .doc(uid)
          .snapshots(),
      builder: (context, snap) {
        final data = snap.data?.data();
        if (data != null && data['blocked'] == true) {
          return BlockedAccountScreen(
            reason: (data['blockedReason'] ?? '').toString(),
          );
        }
        // While loading, or on any error, keep the app usable.
        return child;
      },
    );
  }
}

class BlockedAccountScreen extends StatelessWidget {
  final String reason;
  const BlockedAccountScreen({super.key, required this.reason});

  Future<void> _call15(BuildContext context) async {
    final ok = await launchUrl(Uri(scheme: 'tel', path: '15'));
    if (!ok && context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Could not open the dialer')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(28),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 460),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 72,
                    height: 72,
                    decoration: const BoxDecoration(
                      color: AppColors.dangerSoft,
                      shape: BoxShape.circle,
                    ),
                    child: const Icon(
                      Icons.block,
                      size: 36,
                      color: AppColors.danger,
                    ),
                  ),
                  const SizedBox(height: 16),
                  const Text(
                    'Your account has been suspended',
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    reason.isEmpty
                        ? 'An administrator has suspended this account.'
                        : 'Reason: $reason',
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      color: AppColors.textMuted,
                      height: 1.4,
                    ),
                  ),
                  const SizedBox(height: 6),
                  const Text(
                    'You cannot submit reports while suspended. Contact the '
                    'administrator if you think this is a mistake.',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: AppColors.textSubtle,
                      fontSize: 13,
                      height: 1.4,
                    ),
                  ),
                  const SizedBox(height: 24),
                  const Text(
                    'In an emergency you can still get help:',
                    style: TextStyle(fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 10),
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton.icon(
                      style: FilledButton.styleFrom(
                        backgroundColor: AppColors.danger,
                        padding: const EdgeInsets.symmetric(vertical: 14),
                      ),
                      onPressed: () => Navigator.pushNamed(context, '/sos'),
                      icon: const Icon(Icons.sos),
                      label: const Text('Emergency SOS'),
                    ),
                  ),
                  const SizedBox(height: 10),
                  SizedBox(
                    width: double.infinity,
                    child: OutlinedButton.icon(
                      style: OutlinedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 14),
                      ),
                      onPressed: () => _call15(context),
                      icon: const Icon(Icons.call),
                      label: const Text('Call Police 15'),
                    ),
                  ),
                  const SizedBox(height: 20),
                  TextButton.icon(
                    onPressed: () => FirebaseAuth.instance.signOut(),
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
