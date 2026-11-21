import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';

import '../../firebase_options.dart';
import '../../services/admin_access.dart';
import '../../services/police_access.dart';
import '../../theme/app_theme.dart';
import 'admin_widgets.dart';

/// Police accounts: approve or reject requests, add, edit and remove officers.
class AdminPolicePage extends StatefulWidget {
  const AdminPolicePage({super.key});

  @override
  State<AdminPolicePage> createState() => _AdminPolicePageState();
}

class _AdminPolicePageState extends State<AdminPolicePage> {
  final _db = FirebaseFirestore.instance;
  String _query = '';

  String get _me =>
      AdminAccess.key(FirebaseAuth.instance.currentUser?.email ?? 'admin');

  // -------------------------------------------------------------------------
  // Actions
  // -------------------------------------------------------------------------

  Future<void> _approve(String email, Map<String, dynamic> req) async {
    final ok = await adminConfirm(
      context,
      title: 'Approve officer',
      message:
          'Give $email access to the Police Command Center?\n\n'
          'Name: ${req['name'] ?? '-'}\nStation: ${req['station'] ?? '-'}\n'
          'Badge / belt no.: ${req['badgeNumber'] ?? '-'}',
      confirmLabel: 'Approve',
    );
    if (!ok) return;
    try {
      final batch = _db.batch();
      batch.set(_db.collection('police_officers').doc(email), {
        'email': email,
        'name': req['name'] ?? '',
        'station': req['station'] ?? '',
        'badgeNumber': req['badgeNumber'] ?? '',
        'phone': req['phone'] ?? '',
        'uid': req['uid'] ?? '',
        'approvedBy': _me,
        'approvedAt': FieldValue.serverTimestamp(),
      });
      batch.delete(_db.collection('police_requests').doc(email));
      await batch.commit();
      await AdminAccess.log('Approved police officer', target: email);
      if (mounted) adminToast(context, '$email approved');
    } catch (e) {
      if (mounted) adminToast(context, adminErrorText(e), error: true);
    }
  }

  Future<void> _reject(String email) async {
    final reason = await adminAskText(
      context,
      title: 'Reject request',
      label: 'Reason (shown to the applicant)',
      confirmLabel: 'Reject',
      danger: true,
    );
    if (reason == null) return;
    try {
      await _db.collection('police_requests').doc(email).update({
        'status': 'rejected',
        'rejectionReason': reason,
        'reviewedBy': _me,
        'reviewedAt': FieldValue.serverTimestamp(),
      });
      await AdminAccess.log(
        'Rejected police request',
        target: email,
        details: reason,
      );
      if (mounted) adminToast(context, 'Request rejected');
    } catch (e) {
      if (mounted) adminToast(context, adminErrorText(e), error: true);
    }
  }

  Future<void> _deleteRequest(String email) async {
    try {
      await _db.collection('police_requests').doc(email).delete();
      await AdminAccess.log('Deleted police request', target: email);
    } catch (e) {
      if (mounted) adminToast(context, adminErrorText(e), error: true);
    }
  }

  Future<void> _remove(String email) async {
    final ok = await adminConfirm(
      context,
      title: 'Remove officer',
      message:
          '$email will lose access to the Command Center immediately. '
          'Their reports and remarks stay in the system.',
      confirmLabel: 'Remove access',
      danger: true,
    );
    if (!ok) return;
    try {
      await _db.collection('police_officers').doc(email).delete();
      await AdminAccess.log('Removed police officer', target: email);
      if (mounted) adminToast(context, 'Access removed for $email');
    } catch (e) {
      if (mounted) adminToast(context, adminErrorText(e), error: true);
    }
  }

  Future<void> _edit(String email, Map<String, dynamic> data) async {
    final result = await showDialog<Map<String, String>>(
      context: context,
      builder: (_) => _OfficerDialog(
        title: 'Edit officer',
        email: email,
        name: (data['name'] ?? '').toString(),
        station: (data['station'] ?? '').toString(),
        badge: (data['badgeNumber'] ?? '').toString(),
        phone: (data['phone'] ?? '').toString(),
        allowCreate: false,
      ),
    );
    if (result == null) return;
    try {
      await _db.collection('police_officers').doc(email).update({
        'name': result['name'],
        'station': result['station'],
        'badgeNumber': result['badge'],
        'phone': result['phone'],
        'updatedBy': _me,
        'updatedAt': FieldValue.serverTimestamp(),
      });
      await AdminAccess.log('Edited police officer', target: email);
      if (mounted) adminToast(context, 'Officer updated');
    } catch (e) {
      if (mounted) adminToast(context, adminErrorText(e), error: true);
    }
  }

  /// Adds an officer directly. Optionally creates their sign-in account with a
  /// temporary password and emails them a link to set their own password.
  Future<void> _add() async {
    final result = await showDialog<Map<String, String>>(
      context: context,
      builder: (_) => const _OfficerDialog(title: 'Add police officer'),
    );
    if (result == null) return;
    final email = AdminAccess.key(result['email'] ?? '');
    var accountNote = '';

    if (result['create'] == 'yes') {
      try {
        await _createLogin(email, result['password'] ?? '');
        accountNote = ' A sign-in account was created and a password-setup email was sent.';
      } on FirebaseAuthException catch (e) {
        if (e.code == 'email-already-in-use') {
          accountNote = ' This email already had a sign-in account.';
        } else {
          if (mounted) {
            adminToast(
              context,
              'Could not create the sign-in account: ${e.message ?? e.code}',
              error: true,
            );
          }
          return;
        }
      } catch (e) {
        if (mounted) adminToast(context, adminErrorText(e), error: true);
        return;
      }
    }

    try {
      await _db.collection('police_officers').doc(email).set({
        'email': email,
        'name': result['name'],
        'station': result['station'],
        'badgeNumber': result['badge'],
        'phone': result['phone'],
        'approvedBy': _me,
        'approvedAt': FieldValue.serverTimestamp(),
      });
      // A pending request for the same email is no longer needed.
      await _db
          .collection('police_requests')
          .doc(email)
          .delete()
          .catchError((_) {});
      await AdminAccess.log(
        'Added police officer',
        target: email,
        details: result['create'] == 'yes' ? 'Sign-in account created' : '',
      );
      if (mounted) adminToast(context, '$email added.$accountNote');
    } catch (e) {
      if (mounted) adminToast(context, adminErrorText(e), error: true);
    }
  }

  /// Creating a user with the normal FirebaseAuth instance would sign the
  /// admin out, so a second, temporary Firebase app is used for it.
  Future<void> _createLogin(String email, String password) async {
    FirebaseApp app;
    try {
      app = Firebase.app('adminCreateUser');
    } catch (_) {
      app = await Firebase.initializeApp(
        name: 'adminCreateUser',
        options: DefaultFirebaseOptions.currentPlatform,
      );
    }
    final auth = FirebaseAuth.instanceFor(app: app);
    try {
      await auth.createUserWithEmailAndPassword(
        email: email,
        password: password,
      );
      await auth.sendPasswordResetEmail(email: email);
    } finally {
      await auth.signOut();
    }
  }

  // -------------------------------------------------------------------------
  // UI
  // -------------------------------------------------------------------------

  bool _matches(Map<String, dynamic> d, String id) {
    if (_query.isEmpty) return true;
    final q = _query.toLowerCase();
    return [
      id,
      d['name'],
      d['station'],
      d['badgeNumber'],
    ].map((e) => (e ?? '').toString().toLowerCase()).any((s) => s.contains(q));
  }

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Row(
          children: [
            Expanded(
              child: AdminSearchField(
                hint: 'Search by email, name, station or badge',
                onChanged: (v) => setState(() => _query = v.trim()),
              ),
            ),
            const SizedBox(width: 12),
            FilledButton.icon(
              onPressed: _add,
              icon: const Icon(Icons.person_add_alt_1, size: 18),
              label: const Text('Add officer'),
            ),
          ],
        ),
        const SizedBox(height: 20),
        _sectionTitle('Approval requests', Icons.how_to_reg),
        StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
          stream: _db.collection('police_requests').snapshots(),
          builder: (context, snap) {
            if (snap.hasError) return AdminError(error: snap.error);
            if (!snap.hasData) return const LinearProgressIndicator();
            final docs =
                snap.data!.docs.where((d) => _matches(d.data(), d.id)).toList()
                  ..sort((a, b) {
                    final x = adminToDate(a.data()['requestedAt']);
                    final y = adminToDate(b.data()['requestedAt']);
                    if (x == null || y == null) return 0;
                    return y.compareTo(x);
                  });
            if (docs.isEmpty) {
              return const AdminCard(
                child: Text(
                  'No pending requests. Officers who sign in with an '
                  'unapproved @police.gov.pk account can request access.',
                  style: TextStyle(color: AppColors.textMuted),
                ),
              );
            }
            return Column(
              children: [for (final d in docs) _requestTile(d.id, d.data())],
            );
          },
        ),
        const SizedBox(height: 24),
        _sectionTitle('Approved officers', Icons.local_police),
        StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
          stream: _db.collection('police_officers').snapshots(),
          builder: (context, snap) {
            if (snap.hasError) return AdminError(error: snap.error);
            if (!snap.hasData) return const LinearProgressIndicator();
            final docs =
                snap.data!.docs.where((d) => _matches(d.data(), d.id)).toList()
                  ..sort((a, b) => a.id.compareTo(b.id));
            if (docs.isEmpty) {
              return const AdminCard(
                child: Text(
                  'No officers yet. Use "Add officer" or approve a request.',
                  style: TextStyle(color: AppColors.textMuted),
                ),
              );
            }
            return Column(
              children: [for (final d in docs) _officerTile(d.id, d.data())],
            );
          },
        ),
      ],
    );
  }

  Widget _sectionTitle(String text, IconData icon) => Padding(
    padding: const EdgeInsets.only(bottom: 10),
    child: Row(
      children: [
        Icon(icon, size: 18, color: AppColors.primary),
        const SizedBox(width: 8),
        Text(
          text,
          style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
        ),
      ],
    ),
  );

  Widget _requestTile(String email, Map<String, dynamic> d) {
    final rejected = d['status'] == 'rejected';
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: AdminCard(
        child: Wrap(
          spacing: 12,
          runSpacing: 10,
          crossAxisAlignment: WrapCrossAlignment.center,
          alignment: WrapAlignment.spaceBetween,
          children: [
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 520),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Flexible(
                        child: Text(
                          (d['name'] ?? email).toString(),
                          style: const TextStyle(
                            fontWeight: FontWeight.w700,
                            fontSize: 15,
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      AdminChip(
                        label: rejected ? 'Rejected' : 'Pending',
                        color: rejected ? AppColors.danger : AppColors.warning,
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Text(
                    email,
                    style: const TextStyle(color: AppColors.textMuted),
                  ),
                  Text(
                    'Station: ${d['station'] ?? '-'} · Badge: ${d['badgeNumber'] ?? '-'}'
                    ' · Phone: ${d['phone'] ?? '-'}',
                    style: const TextStyle(fontSize: 12.5),
                  ),
                  Text(
                    'Requested ${adminFormatDate(d['requestedAt'])}',
                    style: const TextStyle(
                      fontSize: 12,
                      color: AppColors.textSubtle,
                    ),
                  ),
                  if (rejected && (d['rejectionReason'] ?? '') != '')
                    Text(
                      'Reason: ${d['rejectionReason']}',
                      style: const TextStyle(
                        fontSize: 12,
                        color: AppColors.danger,
                      ),
                    ),
                ],
              ),
            ),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (!rejected)
                  OutlinedButton(
                    onPressed: () => _reject(email),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: AppColors.danger,
                    ),
                    child: const Text('Reject'),
                  )
                else
                  TextButton(
                    onPressed: () => _deleteRequest(email),
                    child: const Text('Delete'),
                  ),
                const SizedBox(width: 8),
                FilledButton(
                  onPressed: () => _approve(email, d),
                  child: const Text('Approve'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _officerTile(String email, Map<String, dynamic> d) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: AdminCard(
        padding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
        child: Row(
          children: [
            const CircleAvatar(
              backgroundColor: AppColors.primarySoft,
              child: Icon(Icons.local_police, color: AppColors.primary),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    (d['name'] ?? '').toString().isEmpty
                        ? email
                        : d['name'].toString(),
                    style: const TextStyle(fontWeight: FontWeight.w700),
                  ),
                  Text(
                    email,
                    style: const TextStyle(
                      fontSize: 12.5,
                      color: AppColors.textMuted,
                    ),
                  ),
                  Text(
                    'Station: ${(d['station'] ?? '').toString().isEmpty ? '-' : d['station']}'
                    ' · Approved ${adminFormatDate(d['approvedAt'], withTime: false)}',
                    style: const TextStyle(
                      fontSize: 12,
                      color: AppColors.textSubtle,
                    ),
                  ),
                  _CaseCount(email: email),
                ],
              ),
            ),
            PopupMenuButton<String>(
              onSelected: (v) {
                if (v == 'edit') _edit(email, d);
                if (v == 'remove') _remove(email);
              },
              itemBuilder: (_) => const [
                PopupMenuItem(value: 'edit', child: Text('Edit details')),
                PopupMenuItem(
                  value: 'remove',
                  child: Text(
                    'Remove access',
                    style: TextStyle(color: AppColors.danger),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// Number of reports currently assigned to an officer.
class _CaseCount extends StatelessWidget {
  final String email;
  const _CaseCount({required this.email});

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<AggregateQuerySnapshot>(
      future: FirebaseFirestore.instance
          .collection('reports')
          .where('assignedTo', isEqualTo: email)
          .count()
          .get(),
      builder: (context, snap) {
        final n = snap.data?.count;
        if (n == null) return const SizedBox.shrink();
        return Text(
          '$n assigned case${n == 1 ? '' : 's'}',
          style: const TextStyle(fontSize: 12, color: AppColors.primary),
        );
      },
    );
  }
}

/// Form for adding or editing an officer. Returns the entered values.
class _OfficerDialog extends StatefulWidget {
  final String title;
  final String? email;
  final String name;
  final String station;
  final String badge;
  final String phone;
  final bool allowCreate;
  const _OfficerDialog({
    required this.title,
    this.email,
    this.name = '',
    this.station = '',
    this.badge = '',
    this.phone = '',
    this.allowCreate = true,
  });

  @override
  State<_OfficerDialog> createState() => _OfficerDialogState();
}

class _OfficerDialogState extends State<_OfficerDialog> {
  final _form = GlobalKey<FormState>();
  late final _email = TextEditingController(text: widget.email ?? '');
  late final _name = TextEditingController(text: widget.name);
  late final _station = TextEditingController(text: widget.station);
  late final _badge = TextEditingController(text: widget.badge);
  late final _phone = TextEditingController(text: widget.phone);
  final _password = TextEditingController();
  bool _create = false;

  @override
  Widget build(BuildContext context) {
    final editing = widget.email != null;
    return AlertDialog(
      title: Text(widget.title),
      content: SizedBox(
        width: 440,
        child: Form(
          key: _form,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextFormField(
                  controller: _email,
                  enabled: !editing,
                  keyboardType: TextInputType.emailAddress,
                  decoration: const InputDecoration(
                    labelText: 'Official email',
                    hintText: 'name${PoliceAccess.domain}',
                  ),
                  validator: (v) {
                    final s = (v ?? '').trim().toLowerCase();
                    if (s.isEmpty) return 'Email is required';
                    if (!s.endsWith(PoliceAccess.domain)) {
                      return 'Must end with ${PoliceAccess.domain}';
                    }
                    return null;
                  },
                ),
                TextFormField(
                  controller: _name,
                  decoration: const InputDecoration(labelText: 'Full name'),
                  validator: (v) =>
                      (v ?? '').trim().isEmpty ? 'Name is required' : null,
                ),
                TextFormField(
                  controller: _station,
                  decoration: const InputDecoration(
                    labelText: 'Police station',
                  ),
                ),
                TextFormField(
                  controller: _badge,
                  decoration: const InputDecoration(
                    labelText: 'Badge / belt number',
                  ),
                ),
                TextFormField(
                  controller: _phone,
                  keyboardType: TextInputType.phone,
                  decoration: const InputDecoration(labelText: 'Phone'),
                ),
                if (widget.allowCreate) ...[
                  const SizedBox(height: 8),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    value: _create,
                    onChanged: (v) => setState(() => _create = v),
                    title: const Text('Also create a sign-in account'),
                    subtitle: const Text(
                      'The officer gets an email to set their own password.',
                    ),
                  ),
                  if (_create)
                    TextFormField(
                      controller: _password,
                      obscureText: true,
                      decoration: const InputDecoration(
                        labelText: 'Temporary password (min. 8 characters)',
                      ),
                      validator: (v) => _create && (v ?? '').length < 8
                          ? 'At least 8 characters'
                          : null,
                    ),
                ],
              ],
            ),
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () {
            if (!(_form.currentState?.validate() ?? false)) return;
            Navigator.pop(context, {
              'email': _email.text.trim().toLowerCase(),
              'name': _name.text.trim(),
              'station': _station.text.trim(),
              'badge': _badge.text.trim(),
              'phone': _phone.text.trim(),
              'create': _create ? 'yes' : 'no',
              'password': _password.text,
            });
          },
          child: Text(editing ? 'Save' : 'Add officer'),
        ),
      ],
    );
  }
}
