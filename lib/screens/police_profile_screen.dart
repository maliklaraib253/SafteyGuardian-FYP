import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

import '../services/police_access.dart';
import '../theme/app_theme.dart';

/// The signed-in officer's own profile: details approved by the
/// administrator, case statistics, password reset and sign out.
class PoliceProfileScreen extends StatelessWidget {
  /// Follows the Command Center's light/dark choice.
  final bool dark;
  const PoliceProfileScreen({super.key, this.dark = false});

  @override
  Widget build(BuildContext context) {
    final theme = dark
        ? ThemeData(
            useMaterial3: true,
            brightness: Brightness.dark,
            colorSchemeSeed: AppColors.primary,
            scaffoldBackgroundColor: const Color(0xFF0B1220),
          )
        : AppTheme.light;
    return Theme(data: theme, child: const _ProfileBody());
  }
}

class _ProfileBody extends StatelessWidget {
  const _ProfileBody();

  String get _email =>
      (FirebaseAuth.instance.currentUser?.email ?? '').trim().toLowerCase();

  Future<int> _count(Query<Map<String, dynamic>> q) async {
    try {
      return (await q.count().get()).count ?? 0;
    } catch (e) {
      debugPrint('[PoliceProfile] count failed: $e');
      return 0;
    }
  }

  Future<List<int>> _stats() {
    final reports = FirebaseFirestore.instance.collection('reports');
    final mine = reports.where('assignedTo', isEqualTo: _email);
    return Future.wait([
      _count(mine),
      _count(mine.where('status', isEqualTo: 'in progress')),
      _count(mine.where('status', isEqualTo: 'resolved')),
      _count(mine.where('status', isEqualTo: 'rejected')),
    ]);
  }

  Future<void> _resetPassword(BuildContext context) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      await FirebaseAuth.instance.sendPasswordResetEmail(email: _email);
      messenger.showSnackBar(
        SnackBar(content: Text('Password reset link sent to $_email')),
      );
    } catch (e) {
      messenger.showSnackBar(
        SnackBar(content: Text('Could not send the reset email: $e')),
      );
    }
  }

  Future<void> _signOut(BuildContext context) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Log out'),
        content: const Text('Log out of the Command Center?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Log out'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    PoliceAccess.clearCache();
    if (context.mounted) Navigator.of(context).popUntil((r) => r.isFirst);
    await FirebaseAuth.instance.signOut();
  }

  Widget _row(BuildContext context, IconData icon, String label, String value) {
    final muted = Theme.of(context).colorScheme.onSurfaceVariant;
    return ListTile(
      dense: true,
      leading: Icon(icon, size: 20, color: muted),
      title: Text(label, style: TextStyle(fontSize: 12.5, color: muted)),
      subtitle: Text(
        value.isEmpty ? '-' : value,
        style: TextStyle(
          fontSize: 15,
          color: Theme.of(context).colorScheme.onSurface,
        ),
      ),
    );
  }

  Widget _stat(BuildContext context, String label, int? n, Color color) {
    return Expanded(
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 14),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.10),
          borderRadius: BorderRadius.circular(14),
        ),
        child: Column(
          children: [
            Text(
              n == null ? '…' : '$n',
              style: TextStyle(
                fontSize: 22,
                fontWeight: FontWeight.w700,
                color: color,
              ),
            ),
            const SizedBox(height: 2),
            Text(
              label,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 11.5,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _date(dynamic v) {
    if (v is! Timestamp) return '';
    final d = v.toDate();
    const m = [
      'Jan',
      'Feb',
      'Mar',
      'Apr',
      'May',
      'Jun',
      'Jul',
      'Aug',
      'Sep',
      'Oct',
      'Nov',
      'Dec',
    ];
    return '${d.day} ${m[d.month - 1]} ${d.year}';
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('My profile')),
      body: StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
        stream: FirebaseFirestore.instance
            .collection('police_officers')
            .doc(_email)
            .snapshots(),
        builder: (context, snap) {
          final d = snap.data?.data() ?? const <String, dynamic>{};
          final name = (d['name'] ?? '').toString();
          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 560),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      const SizedBox(height: 8),
                      Center(
                        child: CircleAvatar(
                          radius: 38,
                          backgroundColor: AppColors.primary,
                          child: Text(
                            name.isEmpty ? 'P' : name[0].toUpperCase(),
                            style: const TextStyle(
                              fontSize: 30,
                              color: Colors.white,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(height: 12),
                      Text(
                        name.isEmpty ? 'Police officer' : name,
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                          fontSize: 20,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      Text(
                        _email,
                        textAlign: TextAlign.center,
                        style: TextStyle(color: scheme.onSurfaceVariant),
                      ),
                      const SizedBox(height: 6),
                      Center(
                        child: Chip(
                          avatar: const Icon(
                            Icons.verified,
                            size: 16,
                            color: AppColors.success,
                          ),
                          label: const Text('Approved officer'),
                          visualDensity: VisualDensity.compact,
                        ),
                      ),
                      const SizedBox(height: 16),
                      FutureBuilder<List<int>>(
                        future: _stats(),
                        builder: (context, s) {
                          final v = s.data;
                          return Row(
                            children: [
                              _stat(
                                context,
                                'Assigned',
                                v?[0],
                                AppColors.primary,
                              ),
                              const SizedBox(width: 8),
                              _stat(
                                context,
                                'In progress',
                                v?[1],
                                AppColors.warning,
                              ),
                              const SizedBox(width: 8),
                              _stat(
                                context,
                                'Resolved',
                                v?[2],
                                AppColors.success,
                              ),
                              const SizedBox(width: 8),
                              _stat(
                                context,
                                'Rejected',
                                v?[3],
                                AppColors.danger,
                              ),
                            ],
                          );
                        },
                      ),
                      const SizedBox(height: 16),
                      Card(
                        margin: EdgeInsets.zero,
                        child: Column(
                          children: [
                            _row(
                              context,
                              Icons.badge_outlined,
                              'Badge / belt number',
                              (d['badgeNumber'] ?? '').toString(),
                            ),
                            _row(
                              context,
                              Icons.local_police_outlined,
                              'Police station',
                              (d['station'] ?? '').toString(),
                            ),
                            _row(
                              context,
                              Icons.phone_outlined,
                              'Phone',
                              (d['phone'] ?? '').toString(),
                            ),
                            _row(
                              context,
                              Icons.event_available_outlined,
                              'Approved on',
                              _date(d['approvedAt']),
                            ),
                          ],
                        ),
                      ),
                      Padding(
                        padding: const EdgeInsets.fromLTRB(4, 8, 4, 0),
                        child: Text(
                          'These details are managed by the administrator. Ask '
                          'them to update anything that is wrong.',
                          style: TextStyle(
                            fontSize: 12,
                            color: scheme.onSurfaceVariant,
                          ),
                        ),
                      ),
                      const SizedBox(height: 20),
                      OutlinedButton.icon(
                        onPressed: () => _resetPassword(context),
                        icon: const Icon(Icons.lock_reset),
                        label: const Text('Change password'),
                      ),
                      const SizedBox(height: 10),
                      FilledButton.icon(
                        style: FilledButton.styleFrom(
                          backgroundColor: AppColors.danger,
                        ),
                        onPressed: () => _signOut(context),
                        icon: const Icon(Icons.logout),
                        label: const Text('Log out'),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}
