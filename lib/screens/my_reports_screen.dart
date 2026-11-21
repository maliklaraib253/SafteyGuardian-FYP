import 'package:cloud_firestore/cloud_firestore.dart';

import '../theme/responsive.dart';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

import '../services/routing_service.dart';

/// Lists the signed-in citizen's own incident reports with live status updates.
class MyReportsScreen extends StatefulWidget {
  const MyReportsScreen({super.key});

  @override
  State<MyReportsScreen> createState() => _MyReportsScreenState();
}

class _MyReportsScreenState extends State<MyReportsScreen> {
  static const _primary = Color(0xFF1D4ED8);
  static const _filters = ['all', 'pending', 'in progress', 'resolved'];

  String _filter = 'all';
  String _search = '';

  static DateTime? _date(Map<String, dynamic> r) {
    for (final key in ['timestamp', 'createdAt', 'date']) {
      final v = r[key];
      if (v is Timestamp) return v.toDate();
      if (v is DateTime) return v;
      if (v is String) {
        final d = DateTime.tryParse(v);
        if (d != null) return d;
      }
    }
    return null;
  }

  static String _status(Map<String, dynamic> r) =>
      (r['status'] ?? 'pending').toString().toLowerCase().replaceAll('_', ' ');

  static Color _statusColor(String s) {
    switch (s) {
      case 'resolved':
        return Colors.green;
      case 'in progress':
        return Colors.blue;
      case 'under review':
        return Colors.purple;
      case 'rejected':
        return Colors.grey;
      default:
        return Colors.orange;
    }
  }

  static String _titleCase(String s) => s
      .split(' ')
      .map((w) => w.isEmpty ? w : w[0].toUpperCase() + w.substring(1))
      .join(' ');

  static String _formatDate(DateTime? d) {
    if (d == null) return 'Date unknown';
    const months = [
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
    final h = d.hour % 12 == 0 ? 12 : d.hour % 12;
    final m = d.minute.toString().padLeft(2, '0');
    return '${d.day} ${months[d.month - 1]} ${d.year}, $h:$m ${d.hour < 12 ? 'AM' : 'PM'}';
  }

  @override
  Widget build(BuildContext context) {
    final userId = FirebaseAuth.instance.currentUser?.uid;

    return Scaffold(
      appBar: AppBar(title: const Text('My Reports')),
      floatingActionButton: FloatingActionButton.extended(
        backgroundColor: _primary,
        foregroundColor: Colors.white,
        onPressed: () => Navigator.pushNamed(context, '/report'),
        icon: const Icon(Icons.add),
        label: const Text('New Report'),
      ),
      body: ContentWidth(
        maxWidth: 720,
        child: userId == null
            ? const Center(child: Text('Please sign in to see your reports'))
            // No orderBy here: sorting client-side avoids needing a composite index.
            : StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
                stream: FirebaseFirestore.instance
                    .collection('reports')
                    .where('userId', isEqualTo: userId)
                    .snapshots(),
                builder: (context, snapshot) {
                  if (snapshot.hasError) {
                    return Center(
                      child: Padding(
                        padding: const EdgeInsets.all(24),
                        child: Text(
                          'Could not load reports: ${snapshot.error}',
                          textAlign: TextAlign.center,
                        ),
                      ),
                    );
                  }
                  if (!snapshot.hasData) {
                    return const Center(child: CircularProgressIndicator());
                  }

                  final all = snapshot.data!.docs.toList()
                    ..sort((a, b) {
                      final da = _date(a.data()) ?? DateTime(1970);
                      final db = _date(b.data()) ?? DateTime(1970);
                      return db.compareTo(da);
                    });

                  final counts = <String, int>{
                    for (final f in _filters)
                      f: f == 'all'
                          ? all.length
                          : all.where((d) => _status(d.data()) == f).length,
                  };

                  final q = _search.trim().toLowerCase();
                  final visible = all.where((d) {
                    final r = d.data();
                    if (_filter != 'all' && _status(r) != _filter) return false;
                    if (q.isEmpty) return true;
                    return [
                      r['title'],
                      r['category'],
                      r['description'],
                      r['address'],
                      d.id,
                    ].any(
                      (v) => (v ?? '').toString().toLowerCase().contains(q),
                    );
                  }).toList();

                  return Column(
                    children: [
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                        child: TextField(
                          key: const Key('my_reports_search_field'),
                          onChanged: (v) => setState(() => _search = v),
                          decoration: const InputDecoration(
                            hintText: 'Search your reports…',
                            prefixIcon: Icon(Icons.search),
                            isDense: true,
                          ),
                        ),
                      ),
                      SingleChildScrollView(
                        scrollDirection: Axis.horizontal,
                        padding: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 6,
                        ),
                        child: Row(
                          children: _filters.map((f) {
                            return Padding(
                              padding: const EdgeInsets.only(right: 8),
                              child: ChoiceChip(
                                key: Key('my_reports_filter_$f'),
                                label: Text('${_titleCase(f)} (${counts[f]})'),
                                selected: _filter == f,
                                onSelected: (_) => setState(() => _filter = f),
                              ),
                            );
                          }).toList(),
                        ),
                      ),
                      Expanded(
                        child: all.isEmpty
                            ? _emptyState()
                            : visible.isEmpty
                            ? const Center(
                                child: Text('No reports match this filter'),
                              )
                            : ListView.builder(
                                padding: const EdgeInsets.fromLTRB(
                                  16,
                                  4,
                                  16,
                                  90,
                                ),
                                itemCount: visible.length,
                                itemBuilder: (context, i) => _reportCard(
                                  visible[i].id,
                                  visible[i].data(),
                                ),
                              ),
                      ),
                    ],
                  );
                },
              ),
      ),
    );
  }

  Widget _emptyState() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.description_outlined,
              size: 64,
              color: Colors.blue.shade200,
            ),
            const SizedBox(height: 12),
            const Text(
              'No reports submitted yet',
              style: TextStyle(fontSize: 17, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 6),
            Text(
              'Reports you submit will appear here so you can follow their progress.',
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.grey.shade600),
            ),
          ],
        ),
      ),
    );
  }

  Widget _statusChip(String status) {
    final c = _statusColor(status);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: c.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: c.withValues(alpha: 0.5)),
      ),
      child: Text(
        _titleCase(status),
        style: TextStyle(color: c, fontSize: 12, fontWeight: FontWeight.w600),
      ),
    );
  }

  Widget _reportCard(String id, Map<String, dynamic> r) {
    final status = _status(r);
    final title = (r['title'] ?? '').toString().trim();
    final category = (r['category'] ?? 'Other').toString();
    final images = List<String>.from(r['images'] ?? const []);

    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: () => _openDetails(id, r),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      title.isEmpty ? category : title,
                      style: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  const SizedBox(width: 8),
                  _statusChip(status),
                ],
              ),
              const SizedBox(height: 6),
              Row(
                children: [
                  Icon(
                    Icons.label_outline,
                    size: 14,
                    color: Colors.grey.shade600,
                  ),
                  const SizedBox(width: 4),
                  Text(
                    category,
                    style: TextStyle(fontSize: 12, color: Colors.grey.shade700),
                  ),
                  const SizedBox(width: 12),
                  Icon(Icons.schedule, size: 14, color: Colors.grey.shade600),
                  const SizedBox(width: 4),
                  Flexible(
                    child: Text(
                      _formatDate(_date(r)),
                      style: TextStyle(
                        fontSize: 12,
                        color: Colors.grey.shade700,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
              if ((r['description'] ?? '').toString().isNotEmpty) ...[
                const SizedBox(height: 8),
                Text(
                  r['description'].toString(),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: Colors.grey.shade800),
                ),
              ],
              const SizedBox(height: 8),
              Row(
                children: [
                  if (r['isAnonymous'] == true) ...[
                    Icon(
                      Icons.visibility_off,
                      size: 14,
                      color: Colors.grey.shade600,
                    ),
                    const SizedBox(width: 4),
                    Text(
                      'Anonymous',
                      style: TextStyle(
                        fontSize: 11,
                        color: Colors.grey.shade600,
                      ),
                    ),
                    const SizedBox(width: 12),
                  ],
                  if (images.isNotEmpty) ...[
                    Icon(
                      Icons.photo_outlined,
                      size: 14,
                      color: Colors.grey.shade600,
                    ),
                    const SizedBox(width: 4),
                    Text(
                      '${images.length}',
                      style: TextStyle(
                        fontSize: 11,
                        color: Colors.grey.shade600,
                      ),
                    ),
                  ],
                  const Spacer(),
                  Text(
                    'ID ${id.substring(0, id.length < 6 ? id.length : 6).toUpperCase()}',
                    style: TextStyle(fontSize: 11, color: Colors.grey.shade500),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _openDetails(String id, Map<String, dynamic> r) {
    final status = _status(r);
    final images = List<String>.from(r['images'] ?? const []);
    final factors = (r['detectedFactors'] is List)
        ? (r['detectedFactors'] as List).map((e) => e.toString()).toList()
        : <String>[];

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (context) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.75,
        maxChildSize: 0.95,
        builder: (context, controller) => ListView(
          controller: controller,
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 32),
          children: [
            Center(
              child: Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: Colors.grey.shade300,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: Text(
                    (r['title'] ?? '').toString().trim().isEmpty
                        ? (r['category'] ?? 'Report').toString()
                        : r['title'].toString(),
                    style: const TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
                _statusChip(status),
              ],
            ),
            const SizedBox(height: 16),
            _progress(status),
            const SizedBox(height: 16),
            ..._policeUpdates(r),
            _detailRow(
              Icons.label_outline,
              'Category',
              (r['category'] ?? '—').toString(),
            ),
            _detailRow(Icons.schedule, 'Submitted', _formatDate(_date(r))),
            _detailRow(
              Icons.place_outlined,
              'Location',
              RoutingService.displayAddress(r),
            ),
            if ((r['time'] ?? '').toString().isNotEmpty)
              _detailRow(
                Icons.access_time,
                'Incident time',
                r['time'].toString(),
              ),
            _detailRow(Icons.tag, 'Report ID', id),
            if (r['reporterFaceBlurred'] == true)
              _detailRow(
                Icons.face_retouching_off,
                'Privacy',
                'Your face was blurred before upload',
              ),
            const SizedBox(height: 12),
            const Text(
              'Description',
              style: TextStyle(fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 6),
            Text((r['description'] ?? '—').toString()),
            if (r['priority'] != null &&
                ![
                  'pending',
                  'not analyzed',
                ].contains(r['priority'].toString().toLowerCase())) ...[
              const SizedBox(height: 16),
              const Text(
                'Priority assessment',
                style: TextStyle(fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 6),
              Text(
                '${r['priority']}'
                '${r['severityScore'] != null ? ' • severity ${r['severityScore']}/100' : ''}',
              ),
              if (factors.isNotEmpty) ...[
                const SizedBox(height: 6),
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: factors
                      .map(
                        (f) => Chip(
                          label: Text(f, style: const TextStyle(fontSize: 11)),
                        ),
                      )
                      .toList(),
                ),
              ],
            ],
            if (images.isNotEmpty) ...[
              const SizedBox(height: 16),
              const Text(
                'Photos',
                style: TextStyle(fontWeight: FontWeight.bold),
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
                      width: 110,
                      height: 110,
                      fit: BoxFit.cover,
                      errorBuilder: (_, _, _) => Container(
                        width: 110,
                        color: Colors.grey.shade200,
                        child: const Icon(Icons.broken_image),
                      ),
                    ),
                  ),
                ),
              ),
            ],
            if (status == 'pending') ...[
              const SizedBox(height: 24),
              OutlinedButton.icon(
                key: const Key('my_reports_withdraw_button'),
                style: OutlinedButton.styleFrom(foregroundColor: Colors.red),
                icon: const Icon(Icons.delete_outline),
                label: const Text('Withdraw report'),
                onPressed: () => _withdraw(id),
              ),
            ],
          ],
        ),
      ),
    );
  }

  /// Police remarks and the history of status changes, newest first.
  List<Widget> _policeUpdates(Map<String, dynamic> r) {
    final history = (r['statusHistory'] is List)
        ? (r['statusHistory'] as List)
              .whereType<Map>()
              .map((e) => Map<String, dynamic>.from(e))
              .toList()
        : <Map<String, dynamic>>[];
    history.sort((a, b) {
      final ta = a['at'] is Timestamp
          ? (a['at'] as Timestamp).toDate()
          : DateTime(1970);
      final tb = b['at'] is Timestamp
          ? (b['at'] as Timestamp).toDate()
          : DateTime(1970);
      return tb.compareTo(ta);
    });
    final latest = (r['policeRemarks'] ?? '').toString().trim();
    if (latest.isEmpty && history.isEmpty) return const [];

    return [
      Container(
        width: double.infinity,
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: const Color(0xFFEFF6FF),
          borderRadius: BorderRadius.circular(14),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Row(
              children: [
                Icon(
                  Icons.local_police_outlined,
                  size: 18,
                  color: Color(0xFF1D4ED8),
                ),
                SizedBox(width: 6),
                Text(
                  'Police updates',
                  style: TextStyle(
                    fontWeight: FontWeight.bold,
                    color: Color(0xFF1E3A8A),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            if (history.isEmpty)
              Text(latest)
            else
              for (final h in history)
                Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          _statusChip((h['status'] ?? '').toString()),
                          const SizedBox(width: 8),
                          if (h['at'] is Timestamp)
                            Text(
                              _formatDate((h['at'] as Timestamp).toDate()),
                              style: const TextStyle(
                                fontSize: 12,
                                color: Colors.grey,
                              ),
                            ),
                        ],
                      ),
                      const SizedBox(height: 4),
                      Text((h['remarks'] ?? '').toString()),
                    ],
                  ),
                ),
          ],
        ),
      ),
      const SizedBox(height: 16),
    ];
  }

  Widget _progress(String status) {
    const steps = ['pending', 'in progress', 'resolved'];
    var current = steps.indexOf(status);
    if (status == 'under review') current = 1;
    if (current < 0) current = 0;
    return Row(
      children: List.generate(steps.length * 2 - 1, (i) {
        if (i.isOdd) {
          return Expanded(
            child: Container(
              height: 3,
              color: i ~/ 2 < current ? _primary : Colors.grey.shade300,
            ),
          );
        }
        final idx = i ~/ 2;
        final done = idx <= current;
        return Column(
          children: [
            CircleAvatar(
              radius: 12,
              backgroundColor: done ? _primary : Colors.grey.shade300,
              child: Icon(
                done ? Icons.check : Icons.circle,
                size: 14,
                color: Colors.white,
              ),
            ),
            const SizedBox(height: 4),
            Text(_titleCase(steps[idx]), style: const TextStyle(fontSize: 11)),
          ],
        );
      }),
    );
  }

  Widget _detailRow(IconData icon, String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 18, color: Colors.grey.shade600),
          const SizedBox(width: 8),
          SizedBox(
            width: 100,
            child: Text(label, style: TextStyle(color: Colors.grey.shade600)),
          ),
          Expanded(child: Text(value)),
        ],
      ),
    );
  }

  Future<void> _withdraw(String id) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Withdraw this report?'),
        content: const Text(
          'The report will be permanently deleted and police will no longer see it.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Withdraw', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    try {
      await FirebaseFirestore.instance.collection('reports').doc(id).delete();
      if (!mounted) return;
      Navigator.of(context).pop(); // close the details sheet
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Report withdrawn'),
          backgroundColor: Colors.green,
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Could not withdraw: $e'),
          backgroundColor: Colors.red,
        ),
      );
    }
  }
}
