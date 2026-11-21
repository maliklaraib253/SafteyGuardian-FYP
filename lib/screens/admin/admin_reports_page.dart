import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

import '../../services/admin_access.dart';
import '../../theme/app_theme.dart';
import 'admin_widgets.dart';

/// Report moderation: reassign cases, flag fake or spam reports, delete
/// abusive content and (for anonymous reports, with a logged reason) look up
/// who sent a report.
class AdminReportsPage extends StatefulWidget {
  const AdminReportsPage({super.key});

  @override
  State<AdminReportsPage> createState() => _AdminReportsPageState();
}

class _AdminReportsPageState extends State<AdminReportsPage> {
  final _db = FirebaseFirestore.instance;
  int _limit = 300;
  String _query = '';
  String _filter = 'all';

  static const _filters = [
    ['all', 'All'],
    ['open', 'Open'],
    ['critical', 'Critical'],
    ['unassigned', 'Unassigned'],
    ['flagged', 'Flagged'],
    ['anonymous', 'Anonymous'],
  ];

  bool _keep(Map<String, dynamic> r) {
    final s = adminStatusOf(r);
    final open = s != 'resolved' && s != 'rejected';
    switch (_filter) {
      case 'open':
        if (!open) return false;
        break;
      case 'critical':
        if (adminPriorityOf(r) != 'CRITICAL') return false;
        break;
      case 'unassigned':
        if (!open || (r['assignedTo'] ?? '').toString().isNotEmpty) {
          return false;
        }
        break;
      case 'flagged':
        if ((r['moderation'] ?? '').toString().isEmpty) return false;
        break;
      case 'anonymous':
        if (r['isAnonymous'] != true) return false;
        break;
    }
    if (_query.isEmpty) return true;
    final q = _query.toLowerCase();
    return [
      r['title'],
      r['description'],
      r['category'],
      r['address'],
      r['userEmail'],
      r['assignedTo'],
    ].map((e) => (e ?? '').toString().toLowerCase()).any((s) => s.contains(q));
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
          child: AdminSearchField(
            hint: 'Search title, description, area, reporter or officer',
            onChanged: (v) => setState(() => _query = v.trim()),
          ),
        ),
        SizedBox(
          height: 44,
          child: ListView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 16),
            children: [
              for (final f in _filters)
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
            stream: _db
                .collection('reports')
                .orderBy('timestamp', descending: true)
                .limit(_limit)
                .snapshots(),
            builder: (context, snap) {
              if (snap.hasError) return AdminError(error: snap.error);
              if (!snap.hasData) {
                return const Center(child: CircularProgressIndicator());
              }
              final all = snap.data!.docs;
              final docs = all.where((d) => _keep(d.data())).toList();
              final more = all.length >= _limit;
              if (docs.isEmpty && !more) {
                return const AdminEmpty(
                  icon: Icons.assignment_turned_in,
                  title: 'No reports match',
                );
              }
              return ListView.builder(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                itemCount: docs.length + (more ? 1 : 0),
                itemBuilder: (context, i) {
                  if (i == docs.length) {
                    return Center(
                      child: TextButton.icon(
                        onPressed: () => setState(() => _limit += 300),
                        icon: const Icon(Icons.expand_more),
                        label: const Text('Load older reports'),
                      ),
                    );
                  }
                  return _ReportTile(id: docs[i].id, r: docs[i].data());
                },
              );
            },
          ),
        ),
      ],
    );
  }
}

class _ReportTile extends StatelessWidget {
  final String id;
  final Map<String, dynamic> r;
  const _ReportTile({required this.id, required this.r});

  @override
  Widget build(BuildContext context) {
    final status = adminStatusOf(r);
    final priority = adminPriorityOf(r);
    final flagged = (r['moderation'] ?? '').toString();
    final title = (r['title'] ?? '').toString().trim();
    final reporter = r['isAnonymous'] == true
        ? 'Anonymous'
        : (r['userEmail'] ?? 'Unknown').toString();
    final assigned = (r['assignedTo'] ?? '').toString();
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Material(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(14),
        child: InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: () => showModalBottomSheet(
            context: context,
            isScrollControlled: true,
            backgroundColor: AppColors.surface,
            shape: const RoundedRectangleBorder(
              borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
            ),
            builder: (_) => DraggableScrollableSheet(
              expand: false,
              initialChildSize: 0.85,
              maxChildSize: 0.95,
              builder: (ctx, scroll) => _ReportDetails(id: id, scroll: scroll),
            ),
          ),
          child: Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(14),
              border: Border.all(
                color: flagged.isNotEmpty
                    ? AppColors.danger.withValues(alpha: 0.5)
                    : AppColors.border,
              ),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    AdminChip(
                      label: priority,
                      color: adminPriorityColor(priority),
                    ),
                    AdminChip(
                      label: adminTitleCase(status),
                      color: adminStatusColor(status),
                    ),
                    AdminChip(
                      label: (r['category'] ?? 'Other').toString(),
                      color: AppColors.textMuted,
                    ),
                    if (flagged.isNotEmpty)
                      AdminChip(
                        label: 'Flagged: $flagged',
                        color: AppColors.danger,
                        icon: Icons.flag,
                      ),
                  ],
                ),
                const SizedBox(height: 8),
                Text(
                  title.isEmpty
                      ? (r['category'] ?? 'Report').toString()
                      : title,
                  style: const TextStyle(
                    fontWeight: FontWeight.w700,
                    fontSize: 15,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  (r['description'] ?? '').toString(),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: AppColors.textMuted),
                ),
                const SizedBox(height: 6),
                Text(
                  '$reporter · ${adminFormatDate(r['timestamp'])}'
                  '${assigned.isEmpty ? ' · Unassigned' : ' · $assigned'}',
                  style: const TextStyle(
                    fontSize: 12,
                    color: AppColors.textSubtle,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Full report with admin actions. Listens to the document so changes show
/// immediately.
class _ReportDetails extends StatefulWidget {
  final String id;
  final ScrollController scroll;
  const _ReportDetails({required this.id, required this.scroll});

  @override
  State<_ReportDetails> createState() => _ReportDetailsState();
}

class _ReportDetailsState extends State<_ReportDetails> {
  final _db = FirebaseFirestore.instance;
  String? _revealed;

  String get _me =>
      AdminAccess.key(FirebaseAuth.instance.currentUser?.email ?? 'admin');

  DocumentReference<Map<String, dynamic>> get _ref =>
      _db.collection('reports').doc(widget.id);

  Future<void> _reassign(Map<String, dynamic> r) async {
    final officers = await _db.collection('police_officers').get();
    if (!mounted) return;
    final emails = officers.docs.map((d) => d.id).toList()..sort();
    final current = (r['assignedTo'] ?? '').toString();
    final picked = await showDialog<String>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: const Text('Assign to officer'),
        children: [
          if (emails.isEmpty)
            const Padding(
              padding: EdgeInsets.all(16),
              child: Text('No approved officers yet.'),
            ),
          for (final e in emails)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(ctx, e),
              child: Row(
                children: [
                  Icon(
                    e == current
                        ? Icons.radio_button_checked
                        : Icons.radio_button_off,
                    size: 18,
                    color: AppColors.primary,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      '${officers.docs.firstWhere((d) => d.id == e).data()['name'] ?? ''}'
                      '\n$e',
                    ),
                  ),
                ],
              ),
            ),
          if (current.isNotEmpty)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(ctx, ''),
              child: const Text(
                'Remove assignment',
                style: TextStyle(color: AppColors.danger),
              ),
            ),
        ],
      ),
    );
    if (picked == null || picked == current) return;
    try {
      await _ref.update({
        'assignedTo': picked.isEmpty ? FieldValue.delete() : picked,
        'assignedAt': picked.isEmpty
            ? FieldValue.delete()
            : FieldValue.serverTimestamp(),
        'updatedAt': FieldValue.serverTimestamp(),
      });
      await AdminAccess.log(
        picked.isEmpty ? 'Unassigned report' : 'Reassigned report',
        target: widget.id,
        details: picked.isEmpty ? 'from $current' : 'to $picked',
      );
      if (mounted) adminToast(context, 'Assignment updated');
    } catch (e) {
      if (mounted) adminToast(context, adminErrorText(e), error: true);
    }
  }

  Future<void> _flag(String kind) async {
    final reason = await adminAskText(
      context,
      title: kind == 'fake' ? 'Mark as fake report' : 'Mark as spam / abusive',
      label: 'Reason (the reporter will see this)',
      confirmLabel: 'Flag and reject',
      danger: true,
    );
    if (reason == null) return;
    try {
      await _ref.update({
        'moderation': kind,
        'moderationReason': reason,
        'moderatedBy': _me,
        'moderatedAt': FieldValue.serverTimestamp(),
        'status': 'rejected',
        'policeRemarks': 'Rejected by administrator: $reason',
        'remarksBy': 'Administrator',
        'remarksAt': FieldValue.serverTimestamp(),
        'updatedAt': FieldValue.serverTimestamp(),
        'statusHistory': FieldValue.arrayUnion([
          {
            'status': 'rejected',
            'remarks': 'Flagged as $kind by administrator: $reason',
            'by': 'Administrator',
            'at': Timestamp.now(),
          },
        ]),
      });
      await AdminAccess.log(
        'Flagged report as $kind',
        target: widget.id,
        details: reason,
      );
      if (mounted) adminToast(context, 'Report flagged and rejected');
    } catch (e) {
      if (mounted) adminToast(context, adminErrorText(e), error: true);
    }
  }

  Future<void> _clearFlag() async {
    final ok = await adminConfirm(
      context,
      title: 'Clear flag',
      message:
          'Remove the fake/spam flag? The status stays "Rejected" until a '
          'police officer changes it.',
      confirmLabel: 'Clear flag',
    );
    if (!ok) return;
    try {
      await _ref.update({
        'moderation': FieldValue.delete(),
        'moderationReason': FieldValue.delete(),
        'moderatedBy': FieldValue.delete(),
        'moderatedAt': FieldValue.delete(),
      });
      await AdminAccess.log('Cleared report flag', target: widget.id);
    } catch (e) {
      if (mounted) adminToast(context, adminErrorText(e), error: true);
    }
  }

  Future<void> _delete() async {
    final ok = await adminConfirm(
      context,
      title: 'Delete report',
      message:
          'Permanently delete this report? This cannot be undone. Use it only '
          'for abusive or illegal content; for false reports prefer '
          '"Mark as fake".',
      confirmLabel: 'Delete permanently',
      danger: true,
    );
    if (!ok) return;
    try {
      await _ref.delete();
      try {
        await _db.collection('report_identity').doc(widget.id).delete();
      } catch (_) {}
      await AdminAccess.log('Deleted report', target: widget.id);
      if (mounted) {
        final messenger = ScaffoldMessenger.of(context);
        Navigator.pop(context);
        messenger.showSnackBar(
          const SnackBar(
            backgroundColor: AppColors.success,
            content: Text('Report deleted'),
          ),
        );
      }
    } catch (e) {
      if (mounted) adminToast(context, adminErrorText(e), error: true);
    }
  }

  /// Anonymous reports keep the sender in report_identity. Looking it up is
  /// allowed only with a recorded reason (e.g. a malicious fake report).
  Future<void> _reveal() async {
    final reason = await adminAskText(
      context,
      title: 'Reveal anonymous reporter',
      label: 'Reason (recorded in the activity log)',
      confirmLabel: 'Reveal',
      danger: true,
    );
    if (reason == null) return;
    try {
      final doc = await _db.collection('report_identity').doc(widget.id).get();
      final email = doc.data()?['userEmail']?.toString();
      await AdminAccess.log(
        'Revealed anonymous reporter',
        target: widget.id,
        details: reason,
      );
      if (!mounted) return;
      setState(
        () => _revealed = email ?? 'No identity record found for this report',
      );
    } catch (e) {
      if (mounted) adminToast(context, adminErrorText(e), error: true);
    }
  }

  Future<void> _blockReporter(Map<String, dynamic> r) async {
    final uid = (r['userId'] ?? '').toString();
    if (uid.isEmpty) return;
    final reason = await adminAskText(
      context,
      title: 'Block the reporter',
      label: 'Reason (shown to the user)',
      confirmLabel: 'Block account',
      danger: true,
    );
    if (reason == null) return;
    try {
      await _db.collection('users').doc(uid).update({
        'blocked': true,
        'blockedReason': reason,
        'blockedBy': _me,
        'blockedAt': FieldValue.serverTimestamp(),
      });
      await AdminAccess.log(
        'Blocked user',
        target: r['isAnonymous'] == true
            ? 'reporter of ${widget.id}'
            : (r['userEmail'] ?? uid).toString(),
        details: reason,
      );
      if (mounted) adminToast(context, 'Reporter blocked');
    } catch (e) {
      if (mounted) adminToast(context, adminErrorText(e), error: true);
    }
  }

  Widget _row(String label, String value) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 3),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 120,
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
    return StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
      stream: _ref.snapshots(),
      builder: (context, snap) {
        if (snap.hasError) return AdminError(error: snap.error);
        if (!snap.hasData) {
          return const Center(child: CircularProgressIndicator());
        }
        final r = snap.data!.data();
        if (r == null) {
          return const AdminEmpty(
            icon: Icons.delete_outline,
            title: 'This report was deleted',
          );
        }
        final status = adminStatusOf(r);
        final priority = adminPriorityOf(r);
        final flagged = (r['moderation'] ?? '').toString();
        final anonymous = r['isAnonymous'] == true;
        final images = (r['images'] is List)
            ? (r['images'] as List).map((e) => e.toString()).toList()
            : <String>[];
        final history = (r['statusHistory'] is List)
            ? (r['statusHistory'] as List)
                  .whereType<Map>()
                  .map((e) => Map<String, dynamic>.from(e))
                  .toList()
            : <Map<String, dynamic>>[];

        return ListView(
          controller: widget.scroll,
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 28),
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
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                AdminChip(label: priority, color: adminPriorityColor(priority)),
                AdminChip(
                  label: adminTitleCase(status),
                  color: adminStatusColor(status),
                ),
                if (anonymous)
                  const AdminChip(
                    label: 'Anonymous',
                    color: AppColors.textMuted,
                    icon: Icons.visibility_off,
                  ),
                if (flagged.isNotEmpty)
                  AdminChip(
                    label: 'Flagged: $flagged',
                    color: AppColors.danger,
                    icon: Icons.flag,
                  ),
              ],
            ),
            const SizedBox(height: 10),
            Text(
              (r['title'] ?? r['category'] ?? 'Report').toString(),
              style: const TextStyle(fontSize: 19, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 6),
            Text((r['description'] ?? '').toString()),
            const SizedBox(height: 12),
            _row('Category', (r['category'] ?? '-').toString()),
            _row('Location', (r['address'] ?? '-').toString()),
            _row('Submitted', adminFormatDate(r['timestamp'])),
            _row(
              'Reporter',
              anonymous
                  ? (_revealed ?? 'Hidden (anonymous)')
                  : (r['userEmail'] ?? '-').toString(),
            ),
            _row(
              'Assigned to',
              (r['assignedTo'] ?? '').toString().isEmpty
                  ? 'Unassigned'
                  : r['assignedTo'].toString(),
            ),
            if ((r['reason'] ?? '').toString().isNotEmpty)
              _row('AI assessment', r['reason'].toString()),
            if (flagged.isNotEmpty) ...[
              _row('Flag reason', (r['moderationReason'] ?? '-').toString()),
              _row('Flagged by', (r['moderatedBy'] ?? '-').toString()),
            ],
            if (images.isNotEmpty) ...[
              const SizedBox(height: 12),
              const Text(
                'Evidence',
                style: TextStyle(fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 8),
              SizedBox(
                height: 110,
                child: ListView.separated(
                  scrollDirection: Axis.horizontal,
                  itemCount: images.length,
                  separatorBuilder: (_, _) => const SizedBox(width: 8),
                  itemBuilder: (_, i) => ClipRRect(
                    borderRadius: BorderRadius.circular(10),
                    child: Image.network(
                      images[i],
                      width: 140,
                      height: 110,
                      fit: BoxFit.cover,
                      errorBuilder: (_, _, _) => Container(
                        width: 140,
                        color: AppColors.divider,
                        child: const Icon(Icons.broken_image),
                      ),
                    ),
                  ),
                ),
              ),
            ],
            if (history.isNotEmpty) ...[
              const SizedBox(height: 14),
              const Text(
                'History',
                style: TextStyle(fontWeight: FontWeight.w700),
              ),
              for (final h in history.reversed)
                ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(
                    Icons.circle,
                    size: 10,
                    color: adminStatusColor(
                      (h['status'] ?? '').toString().replaceAll('_', ' '),
                    ),
                  ),
                  title: Text(
                    '${adminTitleCase((h['status'] ?? '').toString().replaceAll('_', ' '))}'
                    ' · ${h['by'] ?? ''}',
                  ),
                  subtitle: Text(
                    '${h['remarks'] ?? ''}\n${adminFormatDate(h['at'])}',
                  ),
                ),
            ],
            const SizedBox(height: 18),
            const Text(
              'Admin actions',
              style: TextStyle(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                OutlinedButton.icon(
                  onPressed: () => _reassign(r),
                  icon: const Icon(Icons.swap_horiz, size: 18),
                  label: const Text('Assign / reassign'),
                ),
                if (flagged.isEmpty) ...[
                  OutlinedButton.icon(
                    onPressed: () => _flag('fake'),
                    icon: const Icon(Icons.flag_outlined, size: 18),
                    label: const Text('Mark as fake'),
                  ),
                  OutlinedButton.icon(
                    onPressed: () => _flag('spam'),
                    icon: const Icon(Icons.report_gmailerrorred, size: 18),
                    label: const Text('Mark as spam'),
                  ),
                ] else
                  OutlinedButton.icon(
                    onPressed: _clearFlag,
                    icon: const Icon(Icons.outlined_flag, size: 18),
                    label: const Text('Clear flag'),
                  ),
                if (anonymous && _revealed == null)
                  OutlinedButton.icon(
                    onPressed: _reveal,
                    icon: const Icon(Icons.visibility, size: 18),
                    label: const Text('Reveal reporter'),
                  ),
                OutlinedButton.icon(
                  onPressed: () => _blockReporter(r),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: AppColors.danger,
                  ),
                  icon: const Icon(Icons.block, size: 18),
                  label: const Text('Block reporter'),
                ),
                FilledButton.icon(
                  onPressed: _delete,
                  style: FilledButton.styleFrom(
                    backgroundColor: AppColors.danger,
                  ),
                  icon: const Icon(Icons.delete_outline, size: 18),
                  label: const Text('Delete'),
                ),
              ],
            ),
          ],
        );
      },
    );
  }
}
