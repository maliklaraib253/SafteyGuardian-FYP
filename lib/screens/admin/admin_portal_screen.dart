import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

import '../../services/admin_access.dart';
import '../../theme/app_theme.dart';
import '../../widgets/app_logo.dart';
import 'admin_content_page.dart';
import 'admin_police_page.dart';
import 'admin_reports_page.dart';
import 'admin_users_page.dart';
import 'admin_widgets.dart';

/// Admin portal: manages police accounts, citizens, reports and app content.
/// Opened for accounts listed in the `admins` collection.
class AdminPortalScreen extends StatefulWidget {
  const AdminPortalScreen({super.key});

  @override
  State<AdminPortalScreen> createState() => _AdminPortalScreenState();
}

class _Section {
  final String label;
  final IconData icon;
  final IconData selectedIcon;
  const _Section(this.label, this.icon, this.selectedIcon);
}

class _AdminPortalScreenState extends State<AdminPortalScreen> {
  static const _sections = [
    _Section('Overview', Icons.dashboard_outlined, Icons.dashboard),
    _Section('Police', Icons.local_police_outlined, Icons.local_police),
    _Section('Users', Icons.people_outline, Icons.people),
    _Section('Reports', Icons.assignment_outlined, Icons.assignment),
    _Section('Content', Icons.menu_book_outlined, Icons.menu_book),
    _Section('Activity log', Icons.history, Icons.history),
  ];

  int _index = 0;
  final _scaffoldKey = GlobalKey<ScaffoldState>();

  void _open(int i) => setState(() => _index = i);

  Widget _page() {
    switch (_index) {
      case 1:
        return const AdminPolicePage();
      case 2:
        return const AdminUsersPage();
      case 3:
        return const AdminReportsPage();
      case 4:
        return const AdminContentPage();
      case 5:
        return const AdminActivityPage();
      default:
        return AdminOverviewPage(onOpen: _open);
    }
  }

  Future<void> _signOut() async {
    final ok = await adminConfirm(
      context,
      title: 'Sign out',
      message: 'Sign out of the admin portal?',
      confirmLabel: 'Sign out',
    );
    if (!ok) return;
    AdminAccess.clearCache();
    await FirebaseAuth.instance.signOut();
  }

  /// Pending police approval requests, shown as a badge on "Police".
  Widget _policeIcon(bool selected) {
    return StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
      stream: FirebaseFirestore.instance
          .collection('police_requests')
          .snapshots(),
      builder: (context, snap) {
        final n = snap.data?.docs.length ?? 0;
        return Badge(
          isLabelVisible: n > 0,
          label: Text('$n'),
          child: Icon(selected ? _sections[1].selectedIcon : _sections[1].icon),
        );
      },
    );
  }

  Widget _iconFor(int i, bool selected) {
    if (i == 1) return _policeIcon(selected);
    return Icon(selected ? _sections[i].selectedIcon : _sections[i].icon);
  }

  @override
  Widget build(BuildContext context) {
    final email = FirebaseAuth.instance.currentUser?.email ?? '';
    return LayoutBuilder(
      builder: (context, c) {
        final wide = c.maxWidth >= 900;
        final header = _Header(
          title: _sections[_index].label,
          email: email,
          onSignOut: _signOut,
          onMenu: wide ? null : () => _scaffoldKey.currentState?.openDrawer(),
        );

        if (wide) {
          return Scaffold(
            backgroundColor: AppColors.background,
            body: Row(
              children: [
                NavigationRail(
                  extended: c.maxWidth >= 1150,
                  minExtendedWidth: 210,
                  backgroundColor: AppColors.surface,
                  selectedIndex: _index,
                  onDestinationSelected: _open,
                  leading: const Padding(
                    padding: EdgeInsets.symmetric(vertical: 16),
                    child: AppLogoBadge(size: 40),
                  ),
                  destinations: [
                    for (var i = 0; i < _sections.length; i++)
                      NavigationRailDestination(
                        icon: _iconFor(i, false),
                        selectedIcon: _iconFor(i, true),
                        label: Text(_sections[i].label),
                      ),
                  ],
                ),
                const VerticalDivider(width: 1, color: AppColors.border),
                Expanded(
                  child: Column(
                    children: [
                      header,
                      Expanded(child: _page()),
                    ],
                  ),
                ),
              ],
            ),
          );
        }

        return Scaffold(
          key: _scaffoldKey,
          backgroundColor: AppColors.background,
          drawer: Drawer(
            child: SafeArea(
              child: ListView(
                children: [
                  const Padding(
                    padding: EdgeInsets.fromLTRB(20, 20, 20, 8),
                    child: Row(
                      children: [
                        AppLogoBadge(size: 36),
                        SizedBox(width: 12),
                        Flexible(child: Text(
                          'Admin Portal',
                          style: TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.w700,
                          ),
                        )),
                      ],
                    ),
                  ),
                  const Divider(),
                  for (var i = 0; i < _sections.length; i++)
                    ListTile(
                      leading: _iconFor(i, i == _index),
                      title: Text(_sections[i].label),
                      selected: i == _index,
                      onTap: () {
                        Navigator.pop(context);
                        _open(i);
                      },
                    ),
                ],
              ),
            ),
          ),
          body: SafeArea(
            child: Column(
              children: [
                header,
                Expanded(child: _page()),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _Header extends StatelessWidget {
  final String title;
  final String email;
  final VoidCallback onSignOut;
  final VoidCallback? onMenu;
  const _Header({
    required this.title,
    required this.email,
    required this.onSignOut,
    this.onMenu,
  });

  @override
  Widget build(BuildContext context) {
    final narrow = MediaQuery.sizeOf(context).width < 600;
    return Container(
      padding: const EdgeInsets.fromLTRB(8, 10, 12, 10),
      decoration: const BoxDecoration(
        color: AppColors.surface,
        border: Border(bottom: BorderSide(color: AppColors.border)),
      ),
      child: Row(
        children: [
          if (onMenu != null)
            IconButton(icon: const Icon(Icons.menu), onPressed: onMenu)
          else
            const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Safety Guardian Admin',
                  style: TextStyle(fontSize: 11.5, color: AppColors.textSubtle),
                ),
                Text(
                  title,
                  style: const TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w700,
                    color: AppColors.text,
                  ),
                ),
              ],
            ),
          ),
          if (!narrow)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: AdminChip(
                label: email,
                color: AppColors.primary,
                icon: Icons.admin_panel_settings,
              ),
            ),
          IconButton(
            tooltip: 'Sign out',
            icon: const Icon(Icons.logout),
            onPressed: onSignOut,
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Overview
// ---------------------------------------------------------------------------

class AdminOverviewPage extends StatefulWidget {
  final ValueChanged<int> onOpen;
  const AdminOverviewPage({super.key, required this.onOpen});

  @override
  State<AdminOverviewPage> createState() => _AdminOverviewPageState();
}

class _Counts {
  final int users;
  final int blocked;
  final int officers;
  final int requests;
  const _Counts(this.users, this.blocked, this.officers, this.requests);
}

class _AdminOverviewPageState extends State<AdminOverviewPage> {
  final _db = FirebaseFirestore.instance;
  late Future<_Counts> _counts = _loadCounts();

  Future<int> _count(Query<Map<String, dynamic>> q) async {
    try {
      final snap = await q.count().get();
      return snap.count ?? 0;
    } catch (e) {
      debugPrint('[AdminOverview] count failed: $e');
      return 0;
    }
  }

  Future<_Counts> _loadCounts() async {
    final results = await Future.wait([
      _count(_db.collection('users')),
      _count(_db.collection('users').where('blocked', isEqualTo: true)),
      _count(_db.collection('police_officers')),
      _count(_db.collection('police_requests')),
    ]);
    return _Counts(results[0], results[1], results[2], results[3]);
  }

  @override
  Widget build(BuildContext context) {
    return RefreshIndicator(
      onRefresh: () async {
        setState(() => _counts = _loadCounts());
        await _counts;
      },
      child: StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
        stream: _db
            .collection('reports')
            .orderBy('timestamp', descending: true)
            .limit(500)
            .snapshots(),
        builder: (context, snap) {
          if (snap.hasError) return AdminError(error: snap.error);
          final reports =
              snap.data?.docs.map((d) => d.data()).toList() ??
              <Map<String, dynamic>>[];
          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              FutureBuilder<_Counts>(
                future: _counts,
                builder: (context, c) => _peopleRow(c.data),
              ),
              const SizedBox(height: 12),
              _reportRow(reports, loading: !snap.hasData),
              const SizedBox(height: 16),
              LayoutBuilder(
                builder: (context, box) {
                  final twoCols = box.maxWidth >= 760;
                  final left = _categoryCard(reports);
                  final right = _recentActivity();
                  if (!twoCols) {
                    return Column(
                      children: [left, const SizedBox(height: 16), right],
                    );
                  }
                  return Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(child: left),
                      const SizedBox(width: 16),
                      Expanded(child: right),
                    ],
                  );
                },
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _grid(List<Widget> cards) {
    return LayoutBuilder(
      builder: (context, box) {
        final cols = box.maxWidth >= 900
            ? 4
            : box.maxWidth >= 520
            ? 2
            : 1;
        const gap = 12.0;
        final w = (box.maxWidth - gap * (cols - 1)) / cols;
        return Wrap(
          spacing: gap,
          runSpacing: gap,
          children: [for (final c in cards) SizedBox(width: w, child: c)],
        );
      },
    );
  }

  Widget _tap(int section, Widget child) => InkWell(
    borderRadius: BorderRadius.circular(14),
    onTap: () => widget.onOpen(section),
    child: child,
  );

  Widget _peopleRow(_Counts? c) {
    String v(int? n) => n == null ? '…' : '$n';
    return _grid([
      _tap(
        2,
        AdminStatCard(
          label: 'Registered users',
          value: v(c?.users),
          icon: Icons.people,
          color: AppColors.primary,
        ),
      ),
      _tap(
        2,
        AdminStatCard(
          label: 'Blocked accounts',
          value: v(c?.blocked),
          icon: Icons.block,
          color: AppColors.danger,
        ),
      ),
      _tap(
        1,
        AdminStatCard(
          label: 'Approved officers',
          value: v(c?.officers),
          icon: Icons.local_police,
          color: AppColors.success,
        ),
      ),
      _tap(
        1,
        AdminStatCard(
          label: 'Pending police requests',
          value: v(c?.requests),
          icon: Icons.how_to_reg,
          color: AppColors.warning,
        ),
      ),
    ]);
  }

  Widget _reportRow(
    List<Map<String, dynamic>> reports, {
    required bool loading,
  }) {
    int count(bool Function(Map<String, dynamic>) test) =>
        reports.where(test).length;
    final open = count((r) {
      final s = adminStatusOf(r);
      return s != 'resolved' && s != 'rejected';
    });
    final critical = count(
      (r) =>
          adminPriorityOf(r) == 'CRITICAL' &&
          adminStatusOf(r) != 'resolved' &&
          adminStatusOf(r) != 'rejected',
    );
    final resolved = count((r) => adminStatusOf(r) == 'resolved');
    final flagged = count((r) => (r['moderation'] ?? '').toString().isNotEmpty);

    // Average time from submission to "resolved".
    final hours = <double>[];
    for (final r in reports) {
      final a = adminToDate(r['timestamp']);
      final b = adminToDate(r['resolvedAt']);
      if (a != null && b != null && b.isAfter(a)) {
        hours.add(b.difference(a).inMinutes / 60.0);
      }
    }
    final avg = hours.isEmpty
        ? '-'
        : (hours.reduce((x, y) => x + y) / hours.length).toStringAsFixed(1);

    String v(int n) => loading ? '…' : '$n';
    return _grid([
      _tap(
        3,
        AdminStatCard(
          label: 'Open reports',
          value: v(open),
          icon: Icons.assignment_late,
          color: AppColors.warning,
          hint: '${reports.length} recent reports in total',
        ),
      ),
      _tap(
        3,
        AdminStatCard(
          label: 'Critical and open',
          value: v(critical),
          icon: Icons.priority_high,
          color: AppColors.dangerDark,
        ),
      ),
      _tap(
        3,
        AdminStatCard(
          label: 'Resolved',
          value: v(resolved),
          icon: Icons.task_alt,
          color: AppColors.success,
          hint: 'Avg. time to resolve: $avg h',
        ),
      ),
      _tap(
        3,
        AdminStatCard(
          label: 'Flagged as fake / spam',
          value: v(flagged),
          icon: Icons.flag,
          color: AppColors.danger,
        ),
      ),
    ]);
  }

  Widget _categoryCard(List<Map<String, dynamic>> reports) {
    final byCat = <String, int>{};
    for (final r in reports) {
      final c = (r['category'] ?? 'Other').toString();
      byCat[c] = (byCat[c] ?? 0) + 1;
    }
    final entries = byCat.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    final max = entries.isEmpty ? 1 : entries.first.value;
    return AdminCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Reports by category',
            style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 12),
          if (entries.isEmpty)
            const Text(
              'No reports yet.',
              style: TextStyle(color: AppColors.textMuted),
            ),
          for (final e in entries)
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(child: Text(e.key)),
                      Flexible(child: Text(
                        '${e.value}',
                        style: const TextStyle(fontWeight: FontWeight.w600),
                      )),
                    ],
                  ),
                  const SizedBox(height: 4),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(6),
                    child: LinearProgressIndicator(
                      value: e.value / max,
                      minHeight: 8,
                      backgroundColor: AppColors.divider,
                      color: AppColors.primary,
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget _recentActivity() {
    return AdminCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Expanded(
                child: Text(
                  'Recent admin activity',
                  style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
                ),
              ),
              TextButton(
                onPressed: () => widget.onOpen(5),
                child: const Text('View all'),
              ),
            ],
          ),
          StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
            stream: _db
                .collection('admin_logs')
                .orderBy('at', descending: true)
                .limit(6)
                .snapshots(),
            builder: (context, snap) {
              final docs = snap.data?.docs ?? [];
              if (docs.isEmpty) {
                return const Padding(
                  padding: EdgeInsets.symmetric(vertical: 8),
                  child: Text(
                    'No actions recorded yet.',
                    style: TextStyle(color: AppColors.textMuted),
                  ),
                );
              }
              return Column(
                children: [for (final d in docs) _logTile(d.data())],
              );
            },
          ),
        ],
      ),
    );
  }
}

Widget _logTile(Map<String, dynamic> l) {
  final target = (l['target'] ?? '').toString();
  final details = (l['details'] ?? '').toString();
  return ListTile(
    dense: true,
    contentPadding: EdgeInsets.zero,
    leading: const CircleAvatar(
      radius: 16,
      backgroundColor: AppColors.primarySoft,
      child: Icon(Icons.bolt, size: 16, color: AppColors.primary),
    ),
    title: Text(
      '${l['action'] ?? ''}${target.isEmpty ? '' : ': $target'}',
      maxLines: 2,
      overflow: TextOverflow.ellipsis,
    ),
    subtitle: Text(
      [
        if (details.isNotEmpty) details,
        '${l['by'] ?? ''} · ${adminFormatDate(l['at'])}',
      ].join('\n'),
    ),
  );
}

// ---------------------------------------------------------------------------
// Activity log
// ---------------------------------------------------------------------------

class AdminActivityPage extends StatelessWidget {
  const AdminActivityPage({super.key});

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
      stream: FirebaseFirestore.instance
          .collection('admin_logs')
          .orderBy('at', descending: true)
          .limit(200)
          .snapshots(),
      builder: (context, snap) {
        if (snap.hasError) return AdminError(error: snap.error);
        if (!snap.hasData) {
          return const Center(child: CircularProgressIndicator());
        }
        final docs = snap.data!.docs;
        if (docs.isEmpty) {
          return const AdminEmpty(
            icon: Icons.history,
            title: 'No admin actions yet',
            message: 'Approvals, blocks and report changes will appear here.',
          );
        }
        return ListView.separated(
          padding: const EdgeInsets.all(16),
          itemCount: docs.length,
          separatorBuilder: (_, _) => const Divider(height: 1),
          itemBuilder: (context, i) => _logTile(docs[i].data()),
        );
      },
    );
  }
}
