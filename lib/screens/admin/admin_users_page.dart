import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

import '../../services/admin_access.dart';
import '../../theme/app_theme.dart';
import 'admin_widgets.dart';

/// Citizen accounts: search, view details and block or unblock.
///
/// A blocked citizen can still use Emergency SOS (it works over SMS and calls
/// from their own phone), but cannot submit reports or use cloud features.
class AdminUsersPage extends StatefulWidget {
  const AdminUsersPage({super.key});

  @override
  State<AdminUsersPage> createState() => _AdminUsersPageState();
}

class _AdminUsersPageState extends State<AdminUsersPage> {
  final _db = FirebaseFirestore.instance;
  String _query = '';
  String _filter = 'all'; // all | blocked | verified | unverified

  bool _isBlocked(Map<String, dynamic> d) => d['blocked'] == true;
  bool _isVerified(Map<String, dynamic> d) =>
      d['isIdentityVerified'] == true || d['identityVerified'] == true;

  bool _keep(Map<String, dynamic> d, String uid) {
    switch (_filter) {
      case 'blocked':
        if (!_isBlocked(d)) return false;
        break;
      case 'verified':
        if (!_isVerified(d)) return false;
        break;
      case 'unverified':
        if (_isVerified(d)) return false;
        break;
    }
    if (_query.isEmpty) return true;
    final q = _query.toLowerCase();
    final cnicDigits = (d['cnic'] ?? '').toString().replaceAll(
      RegExp(r'[^0-9]'),
      '',
    );
    return [d['name'], d['email'], d['phone'], uid]
            .map((e) => (e ?? '').toString().toLowerCase())
            .any((s) => s.contains(q)) ||
        (q.length >= 4 && cnicDigits.endsWith(q));
  }

  Future<void> _block(String uid, Map<String, dynamic> d) async {
    final reason = await adminAskText(
      context,
      title: 'Block ${d['name'] ?? 'user'}',
      label: 'Reason (shown to the user)',
      confirmLabel: 'Block account',
      danger: true,
    );
    if (reason == null) return;
    try {
      await _db.collection('users').doc(uid).update({
        'blocked': true,
        'blockedReason': reason,
        'blockedBy': AdminAccess.key(
          FirebaseAuth.instance.currentUser?.email ?? 'admin',
        ),
        'blockedAt': FieldValue.serverTimestamp(),
      });
      await AdminAccess.log(
        'Blocked user',
        target: (d['email'] ?? uid).toString(),
        details: reason,
      );
      if (mounted) adminToast(context, 'Account blocked');
    } catch (e) {
      if (mounted) adminToast(context, adminErrorText(e), error: true);
    }
  }

  Future<void> _unblock(String uid, Map<String, dynamic> d) async {
    final ok = await adminConfirm(
      context,
      title: 'Unblock account',
      message: 'Restore full access for ${d['email'] ?? 'this user'}?',
      confirmLabel: 'Unblock',
    );
    if (!ok) return;
    try {
      // Fields are removed (not set to false) so normal profile saves by the
      // user never touch them.
      await _db.collection('users').doc(uid).update({
        'blocked': FieldValue.delete(),
        'blockedReason': FieldValue.delete(),
        'blockedBy': FieldValue.delete(),
        'blockedAt': FieldValue.delete(),
      });
      await AdminAccess.log(
        'Unblocked user',
        target: (d['email'] ?? uid).toString(),
      );
      if (mounted) adminToast(context, 'Account unblocked');
    } catch (e) {
      if (mounted) adminToast(context, adminErrorText(e), error: true);
    }
  }

  void _details(String uid, Map<String, dynamic> d) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: AppColors.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => _UserDetails(
        uid: uid,
        data: d,
        maskedCnic: adminMaskCnic((d['cnic'] ?? '').toString()),
        onBlock: () {
          Navigator.pop(ctx);
          _block(uid, d);
        },
        onUnblock: () {
          Navigator.pop(ctx);
          _unblock(uid, d);
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
          child: AdminSearchField(
            hint: 'Search by name, email, phone or last 4 CNIC digits',
            onChanged: (v) => setState(() => _query = v.trim()),
          ),
        ),
        SizedBox(
          height: 44,
          child: ListView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 16),
            children: [
              for (final f in const [
                ['all', 'All'],
                ['blocked', 'Blocked'],
                ['verified', 'Identity verified'],
                ['unverified', 'Not verified'],
              ])
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: ChoiceChip(
                    label: Text(f[1]),
                    selected: _filter == f[0],
                    onSelected: (_) => setState(() => _filter = f[0]),
                  ),
                ),
            ],
          ),
        ),
        Expanded(
          child: StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
            stream: _db.collection('users').limit(1000).snapshots(),
            builder: (context, snap) {
              if (snap.hasError) return AdminError(error: snap.error);
              if (!snap.hasData) {
                return const Center(child: CircularProgressIndicator());
              }
              final docs =
                  snap.data!.docs.where((d) => _keep(d.data(), d.id)).toList()
                    ..sort((a, b) {
                      final x = adminToDate(a.data()['createdAt']);
                      final y = adminToDate(b.data()['createdAt']);
                      if (x == null && y == null) return 0;
                      if (x == null) return 1;
                      if (y == null) return -1;
                      return y.compareTo(x);
                    });
              if (docs.isEmpty) {
                return const AdminEmpty(
                  icon: Icons.person_search,
                  title: 'No users match',
                );
              }
              return ListView.builder(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                itemCount: docs.length,
                itemBuilder: (context, i) {
                  final d = docs[i].data();
                  final uid = docs[i].id;
                  final blocked = _isBlocked(d);
                  final name = (d['name'] ?? '').toString();
                  return Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Material(
                      color: AppColors.surface,
                      borderRadius: BorderRadius.circular(14),
                      child: ListTile(
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(14),
                          side: const BorderSide(color: AppColors.border),
                        ),
                        onTap: () => _details(uid, d),
                        leading: CircleAvatar(
                          backgroundColor: blocked
                              ? AppColors.dangerSoft
                              : AppColors.primarySoft,
                          child: Text(
                            name.isEmpty ? '?' : name[0].toUpperCase(),
                            style: TextStyle(
                              color: blocked
                                  ? AppColors.danger
                                  : AppColors.primary,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                        title: Text(name.isEmpty ? '(no name)' : name),
                        subtitle: Text(
                          '${d['email'] ?? '-'}\nJoined '
                          '${adminFormatDate(d['createdAt'], withTime: false)}',
                        ),
                        isThreeLine: true,
                        trailing: Wrap(
                          spacing: 6,
                          direction: Axis.vertical,
                          crossAxisAlignment: WrapCrossAlignment.end,
                          children: [
                            if (blocked)
                              const AdminChip(
                                label: 'Blocked',
                                color: AppColors.danger,
                                icon: Icons.block,
                              ),
                            AdminChip(
                              label: _isVerified(d) ? 'Verified' : 'Unverified',
                              color: _isVerified(d)
                                  ? AppColors.success
                                  : AppColors.textSubtle,
                            ),
                          ],
                        ),
                      ),
                    ),
                  );
                },
              );
            },
          ),
        ),
      ],
    );
  }
}

class _UserDetails extends StatelessWidget {
  final String uid;
  final Map<String, dynamic> data;
  final String maskedCnic;
  final VoidCallback onBlock;
  final VoidCallback onUnblock;
  const _UserDetails({
    required this.uid,
    required this.data,
    required this.maskedCnic,
    required this.onBlock,
    required this.onUnblock,
  });

  Widget _row(String label, String value) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 4),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 130,
          child: Text(
            label,
            style: const TextStyle(color: AppColors.textMuted),
          ),
        ),
        Expanded(child: Text(value)),
      ],
    ),
  );

  @override
  Widget build(BuildContext context) {
    final blocked = data['blocked'] == true;
    final contacts = data['trustedContacts'] is List
        ? (data['trustedContacts'] as List).length
        : 0;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Center(
                child: Container(
                  width: 40,
                  height: 4,
                  decoration: BoxDecoration(
                    color: AppColors.border,
                    borderRadius: BorderRadius.circular(4),
                  ),
                ),
              ),
              const SizedBox(height: 14),
              Text(
                (data['name'] ?? '(no name)').toString(),
                style: const TextStyle(
                  fontSize: 19,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 10),
              _row('Email', (data['email'] ?? '-').toString()),
              _row('Phone', (data['phone'] ?? '-').toString()),
              _row('CNIC', maskedCnic),
              _row(
                'Identity',
                data['isIdentityVerified'] == true
                    ? 'Verified by face match'
                    : 'Not verified',
              ),
              _row('Joined', adminFormatDate(data['createdAt'])),
              _row('Trusted contacts', '$contacts'),
              _row('User ID', uid),
              if (blocked) ...[
                _row('Blocked', adminFormatDate(data['blockedAt'])),
                _row('Reason', (data['blockedReason'] ?? '-').toString()),
                _row('Blocked by', (data['blockedBy'] ?? '-').toString()),
              ],
              const SizedBox(height: 12),
              const Text(
                'Reports',
                style: TextStyle(fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 6),
              FutureBuilder<QuerySnapshot<Map<String, dynamic>>>(
                future: FirebaseFirestore.instance
                    .collection('reports')
                    .where('userId', isEqualTo: uid)
                    .get(),
                builder: (context, snap) {
                  if (!snap.hasData) {
                    return const LinearProgressIndicator();
                  }
                  final reports = snap.data!.docs.map((d) => d.data()).toList();
                  final flagged = reports
                      .where((r) => (r['moderation'] ?? '') != '')
                      .length;
                  final resolved = reports
                      .where((r) => adminStatusOf(r) == 'resolved')
                      .length;
                  return Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      AdminChip(
                        label: '${reports.length} submitted',
                        color: AppColors.primary,
                      ),
                      AdminChip(
                        label: '$resolved resolved',
                        color: AppColors.success,
                      ),
                      AdminChip(
                        label: '$flagged flagged fake/spam',
                        color: flagged > 0
                            ? AppColors.danger
                            : AppColors.textSubtle,
                      ),
                    ],
                  );
                },
              ),
              const SizedBox(height: 20),
              SizedBox(
                width: double.infinity,
                child: blocked
                    ? FilledButton.icon(
                        onPressed: onUnblock,
                        icon: const Icon(Icons.lock_open),
                        label: const Text('Unblock account'),
                      )
                    : FilledButton.icon(
                        style: FilledButton.styleFrom(
                          backgroundColor: AppColors.danger,
                        ),
                        onPressed: onBlock,
                        icon: const Icon(Icons.block),
                        label: const Text('Block account'),
                      ),
              ),
              const SizedBox(height: 8),
              const Text(
                'Blocked users keep Emergency SOS but cannot submit reports '
                'or start Companion Mode.',
                style: TextStyle(fontSize: 12, color: AppColors.textSubtle),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
