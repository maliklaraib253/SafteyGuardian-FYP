import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';

import '../services/report_analysis_service.dart';
import '../theme/app_theme.dart';

import 'package:url_launcher/url_launcher.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import '../services/routing_service.dart';
import '../widgets/evidence_image.dart';
import 'police_profile_screen.dart';
import '../widgets/evidence_video.dart';
import '../widgets/map_pin.dart';

class PoliceDashboardScreen extends StatefulWidget {
  const PoliceDashboardScreen({super.key});

  static const List<String> applicationCategories = [
    'Murder',
    'Snatching',
    'Harassment',
    'Corruption',
    'Robbery',
    'Theft',
    'Assault',
    'Fraud',
    'Traffic Violation',
    'Other',
  ];

  static const List<String> applicationStatuses = [
    'Pending',
    'In Progress',
    'Under Review',
    'Resolved',
  ];

  static bool matchesPriorityFilter(dynamic rawPriority, String filter) {
    if (filter.toLowerCase() == 'all') return true;
    final display = PoliceReportCard.getPriorityDisplay(rawPriority);
    switch (filter.toLowerCase()) {
      case 'critical':
        return display == 'CRITICAL';
      case 'high':
        return display == 'HIGH';
      case 'medium':
        return display == 'MEDIUM';
      case 'low':
        return display == 'LOW';
      case 'not_analyzed':
      case 'not analyzed':
        return display == 'Not Analyzed';
      default:
        return true;
    }
  }

  static bool matchesStatusFilter(dynamic rawStatus, String filter) {
    if (filter.toLowerCase() == 'all') return true;
    if (rawStatus == null) return false;
    final s = rawStatus.toString().trim().toLowerCase().replaceAll('_', ' ');
    final f = filter.trim().toLowerCase().replaceAll('_', ' ');
    return s == f;
  }

  static bool matchesCategoryFilter(dynamic rawCategory, String filter) {
    if (filter.toLowerCase() == 'all') return true;
    if (rawCategory == null) return false;
    final c = rawCategory.toString().trim().toLowerCase();
    final f = filter.trim().toLowerCase();
    return c == f;
  }

  static bool matchesSearchQuery({
    required Map<String, dynamic> report,
    required String docId,
    required String query,
  }) {
    final q = query.trim().toLowerCase();
    if (q.isEmpty) return true;

    // 1. Report title
    final title = (report['title'] ?? '').toString().toLowerCase();
    if (title.contains(q)) return true;

    // 2. Report description
    final description = (report['description'] ?? '').toString().toLowerCase();
    if (description.contains(q)) return true;

    // 3. Category
    final category = (report['category'] ?? '').toString().toLowerCase();
    if (category.contains(q)) return true;

    // 4. Location
    final address = (report['address'] ?? '').toString().toLowerCase();
    if (address.contains(q)) return true;
    final location = (report['location'] ?? '').toString().toLowerCase();
    if (location.contains(q)) return true;

    // 5. Reporter email (hidden for anonymous reports), AI reason & factors
    if (report['isAnonymous'] != true) {
      final email = (report['userEmail'] ?? '').toString().toLowerCase();
      if (email.contains(q)) return true;
    }
    final reason = (report['reason'] ?? '').toString().toLowerCase();
    if (reason.contains(q)) return true;
    final factors = report['detectedFactors'];
    if (factors is List &&
        factors.any((f) => f.toString().toLowerCase().contains(q))) {
      return true;
    }
    final priority = (report['priority'] ?? '').toString().toLowerCase();
    if (priority == q) return true;

    // 6. Report ID (checks both Firestore docId and any report['id'])
    final docIdLower = docId.toLowerCase();
    if (docIdLower.contains(q)) return true;
    final reportId = (report['id'] ?? '').toString().toLowerCase();
    if (reportId.contains(q)) return true;

    return false;
  }

  static const List<String> dateRangeOptions = ['all', 'today', '7d', '30d'];

  static String dateRangeLabel(String value) {
    switch (value) {
      case 'today':
        return 'Today';
      case '7d':
        return 'Last 7 days';
      case '30d':
        return 'Last 30 days';
      default:
        return 'Any time';
    }
  }

  static bool matchesDateRange(Map<String, dynamic> report, String range) {
    if (range == 'all') return true;
    final date = getReportDateTime(report);
    if (date == null) return false;
    final now = DateTime.now();
    switch (range) {
      case 'today':
        return date.year == now.year &&
            date.month == now.month &&
            date.day == now.day;
      case '7d':
        return now.difference(date).inDays < 7;
      case '30d':
        return now.difference(date).inDays < 30;
      default:
        return true;
    }
  }

  static bool matchesReportFilters({
    required dynamic rawPriority,
    required dynamic rawStatus,
    required dynamic rawCategory,
    required String priorityFilter,
    required String statusFilter,
    required String categoryFilter,
    Map<String, dynamic>? report,
    String? docId,
    String searchQuery = '',
  }) {
    final matchesPriority = matchesPriorityFilter(rawPriority, priorityFilter);
    final matchesStatus = matchesStatusFilter(rawStatus, statusFilter);
    final matchesCategory = matchesCategoryFilter(rawCategory, categoryFilter);
    final matchesSearch =
        searchQuery.trim().isEmpty ||
        (report != null &&
            matchesSearchQuery(
              report: report,
              docId: docId ?? '',
              query: searchQuery,
            ));

    return matchesPriority && matchesStatus && matchesCategory && matchesSearch;
  }

  static const String sortPriority =
      'Priority: Critical → High → Medium → Low → Not Analyzed';
  static const String sortSeverity = 'Severity Score: Highest → Lowest';
  static const String sortNewest = 'Newest First';
  static const String sortOldest = 'Oldest First';

  static const List<String> sortOptions = [
    sortPriority,
    sortSeverity,
    sortNewest,
    sortOldest,
  ];

  static int getPriorityRank(dynamic priority) {
    final display = PoliceReportCard.getPriorityDisplay(priority);
    switch (display) {
      case 'CRITICAL':
        return 0;
      case 'HIGH':
        return 1;
      case 'MEDIUM':
        return 2;
      case 'LOW':
        return 3;
      default:
        return 4; // 'Not Analyzed'
    }
  }

  static int? parseSeverityScore(dynamic score) {
    if (score == null) return null;
    if (score is num) return score.toInt();
    return int.tryParse(score.toString().trim());
  }

  static DateTime? parseReportDateTime(dynamic val) {
    if (val == null) return null;
    if (val is Timestamp) return val.toDate();
    if (val is DateTime) return val;
    if (val is String) return DateTime.tryParse(val);
    if (val is int) return DateTime.fromMillisecondsSinceEpoch(val);
    return null;
  }

  static DateTime? getReportDateTime(Map<String, dynamic> data) {
    return parseReportDateTime(data['timestamp']) ??
        parseReportDateTime(data['createdAt']) ??
        parseReportDateTime(data['date']);
  }

  static int compareReports({
    required Map<String, dynamic> a,
    required Map<String, dynamic> b,
    required String sortOption,
  }) {
    final opt = sortOption.trim().toLowerCase();

    if (opt.contains('severity')) {
      // 2. Severity Score: Highest → Lowest
      final aScore = parseSeverityScore(a['severityScore']);
      final bScore = parseSeverityScore(b['severityScore']);
      if (aScore != null && bScore != null) {
        if (aScore != bScore) {
          return bScore.compareTo(aScore); // Highest first
        }
      } else if (aScore != null && bScore == null) {
        return -1;
      } else if (aScore == null && bScore != null) {
        return 1;
      }
      // Tie breaker: timestamp newest first
      final dateCmp = _compareTimestamp(a, b, newestFirst: true);
      if (dateCmp != 0) return dateCmp;
      return _compareFallbackId(a, b);
    } else if (opt.contains('oldest')) {
      // 4. Oldest First
      final dateCmp = _compareTimestamp(a, b, newestFirst: false);
      if (dateCmp != 0) return dateCmp;
      final prioCmp = _comparePriority(a, b);
      if (prioCmp != 0) return prioCmp;
      return _compareFallbackId(a, b);
    } else if (opt.contains('newest')) {
      // 3. Newest First
      final dateCmp = _compareTimestamp(a, b, newestFirst: true);
      if (dateCmp != 0) return dateCmp;
      final prioCmp = _comparePriority(a, b);
      if (prioCmp != 0) return prioCmp;
      return _compareFallbackId(a, b);
    } else {
      // 1. Priority: Critical → High → Medium → Low → Not Analyzed
      final prioCmp = _comparePriority(a, b);
      if (prioCmp != 0) return prioCmp;
      return _compareFallbackId(a, b);
    }
  }

  static int _comparePriority(Map<String, dynamic> a, Map<String, dynamic> b) {
    final aRank = getPriorityRank(a['priority']);
    final bRank = getPriorityRank(b['priority']);
    if (aRank != bRank) return aRank.compareTo(bRank);

    // Secondary tie breaker: severity score (highest first)
    final aScore = parseSeverityScore(a['severityScore']);
    final bScore = parseSeverityScore(b['severityScore']);
    if (aScore != null && bScore != null) {
      if (aScore != bScore) return bScore.compareTo(aScore);
    } else if (aScore != null && bScore == null) {
      return -1;
    } else if (aScore == null && bScore != null) {
      return 1;
    }

    // Tertiary tie breaker: timestamp (newest first)
    return _compareTimestamp(a, b, newestFirst: true);
  }

  static int _compareTimestamp(
    Map<String, dynamic> a,
    Map<String, dynamic> b, {
    required bool newestFirst,
  }) {
    final aDate = getReportDateTime(a);
    final bDate = getReportDateTime(b);
    if (aDate != null && bDate != null) {
      if (aDate != bDate) {
        return newestFirst ? bDate.compareTo(aDate) : aDate.compareTo(bDate);
      }
      return 0;
    } else if (aDate != null && bDate == null) {
      return -1;
    } else if (aDate == null && bDate != null) {
      return 1;
    }
    return 0;
  }

  static int _compareFallbackId(
    Map<String, dynamic> a,
    Map<String, dynamic> b,
  ) {
    final aId = (a['id'] ?? a['docId'] ?? '').toString();
    final bId = (b['id'] ?? b['docId'] ?? '').toString();
    if (aId.isNotEmpty && bId.isNotEmpty) {
      return aId.compareTo(bId);
    }
    return 0;
  }

  @override
  State<PoliceDashboardScreen> createState() => _PoliceDashboardScreenState();
}

/// Colours for the Command Center, in a dark and a light variant.
class _CC {
  final bool dark;
  const _CC(this.dark);

  Color get bg => dark ? const Color(0xFF0A1228) : const Color(0xFFF5F7FA);
  Color get panel => dark ? const Color(0xFF0F1B33) : Colors.white;
  Color get panelAlt =>
      dark ? const Color(0xFF1E2A47) : const Color(0xFFEFF6FF);
  Color get field => dark ? const Color(0xFF0B1430) : Colors.white;
  Color get border => dark ? const Color(0xFF1E293B) : const Color(0xFFE2E8F0);
  Color get borderStrong =>
      dark ? const Color(0xFF334155) : const Color(0xFFCBD5E1);
  Color get text => dark ? const Color(0xFFE2E8F0) : const Color(0xFF0F172A);
  Color get muted => dark ? const Color(0xFF94A3B8) : const Color(0xFF475569);
  Color get chip => dark ? const Color(0xFF1E293B) : const Color(0xFFF1F5F9);
  static const Color accent = Color(0xFF2563EB);

  /// (background, foreground) for a priority label.
  (Color, Color) priority(String display) {
    switch (display) {
      case 'CRITICAL':
        return dark
            ? (const Color(0xFF3F1D1D), const Color(0xFFFCA5A5))
            : (const Color(0xFFFEE2E2), const Color(0xFF991B1B));
      case 'HIGH':
        return dark
            ? (const Color(0xFF3B2414), const Color(0xFFFDBA74))
            : (const Color(0xFFFFEDD5), const Color(0xFF9A3412));
      case 'MEDIUM':
        return dark
            ? (const Color(0xFF3A3012), const Color(0xFFFDE68A))
            : (const Color(0xFFFEF9C3), const Color(0xFF854D0E));
      case 'LOW':
        return dark
            ? (const Color(0xFF1E293B), const Color(0xFFCBD5E1))
            : (const Color(0xFFF1F5F9), const Color(0xFF334155));
      default:
        return dark
            ? (const Color(0xFF1E293B), const Color(0xFF94A3B8))
            : (const Color(0xFFF1F5F9), const Color(0xFF64748B));
    }
  }

  /// Map pin colour for a priority.
  static Color pin(String display) {
    switch (display) {
      case 'CRITICAL':
        return const Color(0xFFEF4444);
      case 'HIGH':
        return const Color(0xFFF97316);
      case 'MEDIUM':
        return const Color(0xFFEAB308);
      case 'LOW':
        return const Color(0xFF16A34A);
      default:
        return const Color(0xFF64748B);
    }
  }

  /// Short label shown on a map pin.
  static String pinLabel(String display) => switch (display) {
    'CRITICAL' => 'Critical',
    'HIGH' => 'High',
    'MEDIUM' => 'Medium',
    'LOW' => 'Low',
    _ => 'New',
  };

  (Color, Color) status(String s) {
    switch (s) {
      case 'resolved':
        return dark
            ? (const Color(0xFF14321F), const Color(0xFF86EFAC))
            : (const Color(0xFFECFDF5), const Color(0xFF047857));
      case 'in progress':
        return dark
            ? (const Color(0xFF172554), const Color(0xFF93C5FD))
            : (const Color(0xFFEFF6FF), const Color(0xFF1D4ED8));
      case 'rejected':
        return dark
            ? (const Color(0xFF1E293B), const Color(0xFF94A3B8))
            : (const Color(0xFFF1F5F9), const Color(0xFF475569));
      default:
        return dark
            ? (const Color(0xFF3A2A10), const Color(0xFFFCD34D))
            : (const Color(0xFFFFFBEB), const Color(0xFF92400E));
    }
  }
}

class _PoliceDashboardScreenState extends State<PoliceDashboardScreen> {
  final TextEditingController _searchController = TextEditingController();
  final MapController _mapController = MapController();
  String? _lastPinKey;
  String _searchQuery = '';
  String _selectedStatus = 'all';
  String _selectedPriority = 'all';
  String _selectedSort = PoliceDashboardScreen.sortPriority;
  String _selectedDateRange = 'all';
  bool _dangerOnly = false;
  bool _mineOnly = false;
  // Reports an administrator flagged as fake/spam live in their own archive.
  bool _showFlagged = false;

  /// Flagged by an administrator as fake or spam (read-only for police).
  static bool _isFlagged(Map<String, dynamic> r) =>
      (r['moderation'] ?? '').toString().isNotEmpty;
  // Paging: newest reports first, more on request.
  static const int _pageSize = 200;
  int _limit = _pageSize;
  String? _selectedId;
  // Police use one theme: the same light look as the rest of the app.
  final bool _dark = false;
  int _mobileTab = 0; // phone: 0 = queue, 1 = map
  final Set<String> _analyzingIds = {};

  _CC get _c => _CC(_dark);

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  // ---------------------------------------------------------------------------
  // Helpers
  // ---------------------------------------------------------------------------

  String get _myEmail => FirebaseAuth.instance.currentUser?.email ?? '';

  static String _shortName(String email) =>
      email.contains('@') ? email.split('@').first : email;

  Future<void> _assign(String docId, {required bool toMe}) async {
    try {
      final snap = await FirebaseFirestore.instance
          .collection('reports')
          .doc(docId)
          .get();
      if (_isFlagged(snap.data() ?? const {})) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'This report was flagged as fake by an administrator and '
              "can't be assigned.",
            ),
          ),
        );
        return;
      }
      await FirebaseFirestore.instance.collection('reports').doc(docId).update({
        'assignedTo': toMe ? _myEmail : FieldValue.delete(),
        'assignedAt': toMe ? FieldValue.serverTimestamp() : FieldValue.delete(),
        'updatedAt': FieldValue.serverTimestamp(),
      });
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(toMe ? 'Case assigned to you' : 'Case unassigned'),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text("Couldn't update assignment: $e")));
    }
  }

  static Map<String, dynamic> _data(QueryDocumentSnapshot d) =>
      (d.data() as Map<String, dynamic>?) ?? <String, dynamic>{};

  static String _statusOf(Map<String, dynamic> r) =>
      (r['status'] ?? 'pending').toString().toLowerCase().replaceAll('_', ' ');

  static String _ago(DateTime? d) {
    if (d == null) return '';
    final diff = DateTime.now().difference(d);
    if (diff.inMinutes < 1) return 'just now';
    if (diff.inMinutes < 60) return '${diff.inMinutes} min ago';
    if (diff.inHours < 24) return '${diff.inHours} h ago';
    if (diff.inDays < 7) return '${diff.inDays} d ago';
    return '${d.day}/${d.month}/${d.year}';
  }

  static String _title(Map<String, dynamic> r) {
    final t = (r['title'] ?? '').toString().trim();
    return t.isNotEmpty ? t : (r['category'] ?? 'Incident report').toString();
  }

  static LatLng? _point(Map<String, dynamic> r) {
    final lat = r['latitude'];
    final lng = r['longitude'];
    if (lat is num && lng is num && (lat != 0 || lng != 0)) {
      return LatLng(lat.toDouble(), lng.toDouble());
    }
    return null;
  }

  Future<void> _analyzeReport(String docId, Map<String, dynamic> data) async {
    if (_analyzingIds.contains(docId)) return;
    setState(() => _analyzingIds.add(docId));
    bool usedGemini = false;
    try {
      usedGemini = await ReportAnalysisService().analyzeAndSaveReport(
        docId: docId,
        report: data,
      );
    } catch (e) {
      debugPrint('[PoliceDashboard] analyze failed: $e');
    }
    if (!mounted) return;
    setState(() => _analyzingIds.remove(docId));
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          usedGemini
              ? 'AI analysis updated'
              : 'AI unavailable: saved an on-device estimate instead',
        ),
      ),
    );
  }

  void _select(String id, Map<String, dynamic> r, {required bool phone}) {
    setState(() => _selectedId = id);
    final p = _point(r);
    if (p != null) {
      try {
        _mapController.move(p, 15);
      } catch (_) {}
    }
    if (phone) {
      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => Theme(
            data: _themeData ?? Theme.of(context),
            child: _PhoneDetailPage(
              docId: id,
              dark: _dark,
              buildDetail: _detailPanel,
            ),
          ),
        ),
      );
    }
  }

  // ---------------------------------------------------------------------------
  // Build
  // ---------------------------------------------------------------------------

  ThemeData? _themeData;

  @override
  Widget build(BuildContext context) {
    final c = _c;
    _themeData = Theme.of(context).copyWith(
      brightness: _dark ? Brightness.dark : Brightness.light,
      scaffoldBackgroundColor: c.bg,
      canvasColor: c.panel,
      colorScheme: Theme.of(context).colorScheme.copyWith(
        brightness: _dark ? Brightness.dark : Brightness.light,
        surface: c.panel,
        onSurface: c.text,
        primary: _CC.accent,
      ),
      textTheme: Theme.of(context).textTheme
          .apply(bodyColor: c.text, displayColor: c.text),
      inputDecorationTheme: Theme.of(context).inputDecorationTheme.copyWith(
        fillColor: c.field,
        hintStyle: TextStyle(color: c.muted),
        labelStyle: TextStyle(color: c.muted),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: c.borderStrong),
        ),
      ),
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: c.panel,
        surfaceTintColor: Colors.transparent,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
        ),
      ),
      iconTheme: IconThemeData(color: c.text),
      dividerTheme: DividerThemeData(color: c.border),
    );
    return Theme(
      data: _themeData!,
      child: StreamBuilder<QuerySnapshot>(
        stream: FirebaseFirestore.instance
            .collection('reports')
            .orderBy('timestamp', descending: true)
            .limit(_limit)
            .snapshots(),
        builder: (context, snapshot) {
          return LayoutBuilder(
            builder: (context, box) {
              final w = box.maxWidth;
              final phone = w < 760;
              return Scaffold(
                backgroundColor: c.bg,
                body: SafeArea(
                  child: Column(
                    children: [
                      _header(snapshot, phone),
                      Expanded(child: _body(snapshot, w)),
                    ],
                  ),
                ),
                bottomNavigationBar: phone
                    ? NavigationBar(
                        backgroundColor: c.panel,
                        indicatorColor: c.panelAlt,
                        selectedIndex: _mobileTab,
                        onDestinationSelected: (i) =>
                            setState(() => _mobileTab = i),
                        destinations: const [
                          NavigationDestination(
                            icon: Icon(Icons.view_list_outlined),
                            label: 'Queue',
                          ),
                          NavigationDestination(
                            icon: Icon(Icons.map_outlined),
                            label: 'Map',
                          ),
                        ],
                      )
                    : null,
              );
            },
          );
        },
      ),
    );
  }

  Widget _header(AsyncSnapshot<QuerySnapshot> snap, bool phone) {
    final c = _c;
    final docs = snap.data?.docs ?? const [];
    final critical = docs.where((d) {
      final r = _data(d);
      return PoliceReportCard.getPriorityDisplay(r['priority']) == 'CRITICAL' &&
          _statusOf(r) == 'pending';
    }).length;
    final email = FirebaseAuth.instance.currentUser?.email ?? 'Officer';

    final search = TextField(
      controller: _searchController,
      onChanged: (v) => setState(() => _searchQuery = v),
      style: TextStyle(color: c.text, fontSize: 14),
      decoration: InputDecoration(
        isDense: true,
        hintText: 'Search title, area or reference',
        prefixIcon: Icon(Icons.search, color: c.muted, size: 20),
        suffixIcon: _searchQuery.isEmpty
            ? null
            : IconButton(
                tooltip: 'Clear search',
                icon: Icon(Icons.close, color: c.muted, size: 18),
                onPressed: () {
                  _searchController.clear();
                  setState(() => _searchQuery = '');
                },
              ),
      ),
    );

    return Container(
      padding: const EdgeInsets.fromLTRB(16, 10, 8, 10),
      decoration: BoxDecoration(
        color: c.panel,
        border: Border(bottom: BorderSide(color: c.border)),
      ),
      child: Column(
        children: [
          Row(
            children: [
              if (!phone) ...[
                Container(
                  width: 36,
                  height: 36,
                  decoration: BoxDecoration(
                    color: _CC.accent,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: const Icon(
                    Icons.shield_outlined,
                    color: Colors.white,
                    size: 20,
                  ),
                ),
                const SizedBox(width: 10),
              ],
              // Flexible so the title shrinks instead of overflowing on
              // narrow phones.
              Flexible(
                flex: phone ? 1 : 0,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Control Room',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: c.text,
                        fontWeight: FontWeight.w700,
                        fontSize: 15,
                      ),
                    ),
                    Text(
                      'Safety Guardian · Police',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(color: c.muted, fontSize: 12),
                    ),
                  ],
                ),
              ),
              if (!phone) ...[
                const SizedBox(width: 24),
                Expanded(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 520),
                    child: search,
                  ),
                ),
              ],
              if (critical > 0)
                Padding(
                  padding: const EdgeInsets.only(left: 8),
                  child: InkWell(
                    borderRadius: BorderRadius.circular(999),
                    onTap: () => setState(() {
                      _selectedPriority = 'critical';
                      _selectedStatus = 'pending';
                    }),
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 6,
                      ),
                      decoration: BoxDecoration(
                        color: c.priority('CRITICAL').$1,
                        borderRadius: BorderRadius.circular(999),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Container(
                            width: 8,
                            height: 8,
                            decoration: const BoxDecoration(
                              color: Color(0xFFEF4444),
                              shape: BoxShape.circle,
                            ),
                          ),
                          const SizedBox(width: 6),
                          Text(
                            phone ? '$critical' : '$critical critical now',
                            style: TextStyle(
                              color: c.priority('CRITICAL').$2,
                              fontSize: 12,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              if (!phone)
                IconButton(
                  key: const Key('open_prioritization_button'),
                  tooltip: 'Report prioritization',
                  icon: Icon(Icons.insights, color: c.text),
                  onPressed: () =>
                      Navigator.pushNamed(context, '/prioritization'),
                ),
              PopupMenuButton<String>(
                tooltip: 'Account',
                color: c.panel,
                icon: Icon(Icons.account_circle_outlined, color: c.text),
                onSelected: (v) {
                  if (v == 'logout') FirebaseAuth.instance.signOut();
                  if (v == 'prioritization') {
                    Navigator.pushNamed(context, '/prioritization');
                  }
                  if (v == 'profile') {
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => PoliceProfileScreen(dark: _dark),
                      ),
                    );
                  }
                },
                itemBuilder: (_) => [
                  PopupMenuItem(
                    enabled: false,
                    child: Text(email, style: TextStyle(color: c.muted)),
                  ),
                  PopupMenuItem(
                    value: 'profile',
                    child: Row(
                      children: [
                        Icon(Icons.person_outline, size: 18, color: c.text),
                        const SizedBox(width: 10),
                        Text('My profile', style: TextStyle(color: c.text)),
                      ],
                    ),
                  ),
                  if (phone) ...[
                    PopupMenuItem(
                      value: 'prioritization',
                      child: Row(
                        children: [
                          Icon(Icons.insights, size: 18, color: c.text),
                          const SizedBox(width: 10),
                          Text(
                            'Report prioritization',
                            style: TextStyle(color: c.text),
                          ),
                        ],
                      ),
                    ),
                  ],
                  PopupMenuItem(
                    value: 'logout',
                    child: Row(
                      children: [
                        Icon(Icons.logout, size: 18, color: c.text),
                        const SizedBox(width: 10),
                        Text('Log out', style: TextStyle(color: c.text)),
                      ],
                    ),
                  ),
                ],
              ),
            ],
          ),
          if (phone) ...[
            const SizedBox(height: 10),
            Padding(padding: const EdgeInsets.only(right: 8), child: search),
          ],
        ],
      ),
    );
  }

  Widget _body(AsyncSnapshot<QuerySnapshot> snapshot, double width) {
    final c = _c;
    if (snapshot.hasError) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            "Couldn't load reports. Check your internet connection, and that "
            'this account is approved as police.\n\n${snapshot.error}',
            textAlign: TextAlign.center,
            style: TextStyle(color: c.muted),
          ),
        ),
      );
    }
    if (!snapshot.hasData) {
      return const Center(child: CircularProgressIndicator());
    }

    final all = snapshot.data!.docs;
    var reports = all.where((doc) {
      final data = _data(doc);
      return PoliceDashboardScreen.matchesReportFilters(
            rawPriority: data['priority'],
            rawStatus: data['status'] ?? 'pending',
            rawCategory: data['category'],
            priorityFilter: _selectedPriority,
            statusFilter: _selectedStatus,
            categoryFilter: 'all',
            report: data,
            docId: doc.id,
            searchQuery: _searchQuery,
          ) &&
          PoliceDashboardScreen.matchesDateRange(data, _selectedDateRange) &&
          (!_dangerOnly ||
              PoliceReportCard.parseBoolField(data['immediateDanger']) ==
                  true) &&
          (!_mineOnly || data['assignedTo'] == _myEmail) &&
          // Flagged reports only appear in the "Fake / flagged" archive.
          _isFlagged(data) == _showFlagged;
    }).toList();
    reports.sort(
      (a, b) => PoliceDashboardScreen.compareReports(
        a: _data(a),
        b: _data(b),
        sortOption: _selectedSort,
      ),
    );

    QueryDocumentSnapshot? selected;
    for (final d in all) {
      if (d.id == _selectedId) selected = d;
    }
    if (selected == null && reports.isNotEmpty && width >= 760) {
      selected = reports.first;
    }

    final stats = _stats(all);
    final queue = _queue(
      reports,
      selected?.id,
      phone: width < 760,
      canLoadMore: all.length >= _limit,
    );

    if (width < 760) {
      return Column(
        children: [
          stats,
          Expanded(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
              child: _mobileTab == 0
                  ? queue
                  : _map(reports, selected?.id, phone: true),
            ),
          ),
        ],
      );
    }

    final detail = selected == null
        ? _emptyDetail()
        : _panel(child: _detailPanel(selected.id, _data(selected)));

    if (width < 1180) {
      // Tablet: queue + (map over details).
      return Column(
        children: [
          stats,
          Expanded(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  SizedBox(width: 320, child: queue),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      children: [
                        SizedBox(
                          height: 220,
                          child: _map(reports, selected?.id, phone: false),
                        ),
                        const SizedBox(height: 12),
                        Expanded(child: detail),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      );
    }

    // Desktop / large tablet: queue | map | details.
    return Column(
      children: [
        stats,
        Expanded(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SizedBox(width: 330, child: queue),
                const SizedBox(width: 12),
                Expanded(child: _map(reports, selected?.id, phone: false)),
                const SizedBox(width: 12),
                SizedBox(width: 390, child: detail),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _panel({required Widget child, EdgeInsets? padding}) {
    final c = _c;
    return Container(
      padding: padding,
      decoration: BoxDecoration(
        color: c.panel,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: c.border),
      ),
      clipBehavior: Clip.antiAlias,
      child: child,
    );
  }

  Widget _stats(List<QueryDocumentSnapshot> all) {
    final c = _c;
    final now = DateTime.now();
    int today = 0, high = 0, active = 0, resolved = 0, pending = 0;
    for (final d in all) {
      final r = _data(d);
      if (_isFlagged(r)) continue; // fake/spam: not part of the workload
      final s = _statusOf(r);
      final t = PoliceDashboardScreen.getReportDateTime(r);
      if (t != null &&
          t.year == now.year &&
          t.month == now.month &&
          t.day == now.day) {
        today++;
      }
      final p = PoliceReportCard.getPriorityDisplay(r['priority']);
      if ((p == 'CRITICAL' || p == 'HIGH') &&
          s != 'resolved' &&
          s != 'rejected') {
        high++;
      }
      if (s == 'in progress') active++;
      if (s == 'resolved') resolved++;
      if (s == 'pending') pending++;
    }
    Widget card(String label, int value, Color color, VoidCallback onTap) {
      return Expanded(
        child: Material(
          color: c.panel,
          borderRadius: BorderRadius.circular(14),
          child: InkWell(
            borderRadius: BorderRadius.circular(14),
            onTap: onTap,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: c.border),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: c.muted, fontSize: 11.5),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    '$value',
                    style: TextStyle(
                      color: color,
                      fontSize: 22,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
    }

    final red = _dark ? const Color(0xFFFCA5A5) : const Color(0xFFB91C1C);
    final blue = _dark ? const Color(0xFF93C5FD) : const Color(0xFF1D4ED8);
    final green = _dark ? const Color(0xFF86EFAC) : const Color(0xFF047857);
    final amber = _dark ? const Color(0xFFFCD34D) : const Color(0xFFB45309);
    void reset() => setState(() {
      _selectedStatus = 'all';
      _selectedPriority = 'all';
      _selectedDateRange = 'all';
      _dangerOnly = false;
    });
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      child: Row(
        children: [
          card('New today', today, c.text, () {
            reset();
            setState(() => _selectedDateRange = 'today');
          }),
          const SizedBox(width: 8),
          card('Pending', pending, amber, () {
            reset();
            setState(() => _selectedStatus = 'pending');
          }),
          const SizedBox(width: 8),
          card('Critical / high', high, red, () {
            reset();
            setState(() => _selectedPriority = 'high');
          }),
          const SizedBox(width: 8),
          card('In progress', active, blue, () {
            reset();
            setState(() => _selectedStatus = 'in progress');
          }),
          const SizedBox(width: 8),
          card('Resolved', resolved, green, () {
            reset();
            setState(() => _selectedStatus = 'resolved');
          }),
        ],
      ),
    );
  }

  // ---- Queue ---------------------------------------------------------------

  Widget _queue(
    List<QueryDocumentSnapshot> reports,
    String? selectedId, {
    required bool phone,
    bool canLoadMore = false,
  }) {
    final c = _c;
    Widget chip(String label, bool on, VoidCallback onTap) {
      return Padding(
        padding: const EdgeInsets.only(right: 6),
        child: InkWell(
          borderRadius: BorderRadius.circular(999),
          onTap: onTap,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            decoration: BoxDecoration(
              color: on ? _CC.accent : Colors.transparent,
              borderRadius: BorderRadius.circular(999),
              border: Border.all(color: on ? _CC.accent : c.borderStrong),
            ),
            child: Text(
              label,
              style: TextStyle(
                fontSize: 12,
                fontWeight: on ? FontWeight.w600 : FontWeight.w500,
                color: on ? Colors.white : c.text,
              ),
            ),
          ),
        ),
      );
    }

    return _panel(
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 12, 4, 8),
            child: Row(
              children: [
                Flexible(
                  child: Text(
                    '${reports.length} report${reports.length == 1 ? '' : 's'}',
                    style: TextStyle(
                      color: c.text,
                      fontWeight: FontWeight.w700,
                      fontSize: 14,
                    ),
                  ),
                ),
                const Spacer(),
                PopupMenuButton<String>(
                  tooltip: 'Sort',
                  color: c.panel,
                  initialValue: _selectedSort,
                  onSelected: (v) => setState(() => _selectedSort = v),
                  itemBuilder: (_) => [
                    for (final o in PoliceDashboardScreen.sortOptions)
                      PopupMenuItem(
                        value: o,
                        child: Text(o, style: TextStyle(color: c.text)),
                      ),
                  ],
                  icon: Icon(Icons.sort, color: c.muted, size: 20),
                ),
                PopupMenuButton<String>(
                  tooltip: 'Date',
                  color: c.panel,
                  initialValue: _selectedDateRange,
                  onSelected: (v) => setState(() => _selectedDateRange = v),
                  itemBuilder: (_) => [
                    for (final o in PoliceDashboardScreen.dateRangeOptions)
                      PopupMenuItem(
                        value: o,
                        child: Text(
                          PoliceDashboardScreen.dateRangeLabel(o),
                          style: TextStyle(color: c.text),
                        ),
                      ),
                  ],
                  icon: Icon(
                    Icons.calendar_today_outlined,
                    color: _selectedDateRange == 'all' ? c.muted : _CC.accent,
                    size: 18,
                  ),
                ),
              ],
            ),
          ),
          SizedBox(
            height: 34,
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 12),
              children: [
                chip(
                  'All',
                  _selectedStatus == 'all' &&
                      _selectedPriority == 'all' &&
                      !_dangerOnly &&
                      !_mineOnly &&
                      !_showFlagged,
                  () => setState(() {
                    _selectedStatus = 'all';
                    _selectedPriority = 'all';
                    _dangerOnly = false;
                    _mineOnly = false;
                    _showFlagged = false;
                  }),
                ),
                chip(
                  'My cases',
                  _mineOnly,
                  () => setState(() => _mineOnly = !_mineOnly),
                ),
                chip(
                  'Critical',
                  _selectedPriority == 'critical',
                  () => setState(
                    () => _selectedPriority = _selectedPriority == 'critical'
                        ? 'all'
                        : 'critical',
                  ),
                ),
                chip(
                  'Danger now',
                  _dangerOnly,
                  () => setState(() => _dangerOnly = !_dangerOnly),
                ),
                chip(
                  'Pending',
                  _selectedStatus == 'pending',
                  () => setState(
                    () => _selectedStatus = _selectedStatus == 'pending'
                        ? 'all'
                        : 'pending',
                  ),
                ),
                chip(
                  'In progress',
                  _selectedStatus == 'in progress',
                  () => setState(
                    () => _selectedStatus = _selectedStatus == 'in progress'
                        ? 'all'
                        : 'in progress',
                  ),
                ),
                chip(
                  'Resolved',
                  _selectedStatus == 'resolved',
                  () => setState(
                    () => _selectedStatus = _selectedStatus == 'resolved'
                        ? 'all'
                        : 'resolved',
                  ),
                ),
                chip(
                  'Rejected',
                  _selectedStatus == 'rejected',
                  () => setState(
                    () => _selectedStatus = _selectedStatus == 'rejected'
                        ? 'all'
                        : 'rejected',
                  ),
                ),
                chip(
                  '🚩 Fake / flagged',
                  _showFlagged,
                  () => setState(() {
                    _showFlagged = !_showFlagged;
                    if (_showFlagged) {
                      _selectedStatus = 'all';
                      _mineOnly = false;
                    }
                  }),
                ),
              ],
            ),
          ),
          const SizedBox(height: 8),
          Divider(height: 1, color: c.border),
          Expanded(
            child: reports.isEmpty
                ? Center(
                    child: Padding(
                      padding: const EdgeInsets.all(24),
                      child: Text(
                        'No reports match these filters.',
                        style: TextStyle(color: c.muted),
                      ),
                    ),
                  )
                : ListView.builder(
                    padding: const EdgeInsets.all(8),
                    itemCount: reports.length + (canLoadMore ? 1 : 0),
                    itemBuilder: (_, i) {
                      if (i >= reports.length) {
                        return Padding(
                          padding: const EdgeInsets.all(8),
                          child: OutlinedButton.icon(
                            key: const Key('load_older_reports'),
                            onPressed: () =>
                                setState(() => _limit += _pageSize),
                            icon: const Icon(Icons.history, size: 18),
                            label: const Text('Load older reports'),
                          ),
                        );
                      }
                      final d = reports[i];
                      return _queueItem(
                        d.id,
                        _data(d),
                        selected: d.id == selectedId,
                        phone: phone,
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }

  Widget _queueItem(
    String id,
    Map<String, dynamic> r, {
    required bool selected,
    required bool phone,
  }) {
    final c = _c;
    final p = PoliceReportCard.getPriorityDisplay(r['priority']);
    final (pbg, pfg) = c.priority(p);
    final status = _statusOf(r);
    final (sbg, sfg) = c.status(status);
    final danger =
        PoliceReportCard.parseBoolField(r['immediateDanger']) == true;
    final weapon = PoliceReportCard.parseBoolField(r['weaponDetected']) == true;
    final area = RoutingService.displayAddress(r);
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Material(
        color: selected ? c.panelAlt : Colors.transparent,
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          key: Key('queue_item_$id'),
          borderRadius: BorderRadius.circular(12),
          onTap: () => _select(id, r, phone: phone),
          child: Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: selected ? _CC.accent : Colors.transparent,
              ),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: Text(
                        _title(r),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: c.text,
                          fontWeight: FontWeight.w600,
                          fontSize: 14,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    _pill(p == 'Not Analyzed' ? 'NEW' : p, pbg, pfg),
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  [
                    if (area.isNotEmpty) area,
                    _ago(PoliceDashboardScreen.getReportDateTime(r)),
                  ].join(' · '),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: c.muted, fontSize: 12),
                ),
                const SizedBox(height: 6),
                Wrap(
                  spacing: 6,
                  runSpacing: 4,
                  children: [
                    _pill(_titleCase(status), sbg, sfg),
                    if (_isFlagged(r))
                      _pill(
                        'Flagged ${r['moderation']}',
                        const Color(0xFF7F1D1D),
                        const Color(0xFFFECACA),
                      ),
                    if (danger) _pill('Danger now', pbg, pfg),
                    if (weapon) _pill('Weapon', pbg, pfg),
                    if (r['isAnonymous'] == true)
                      _pill('Anonymous', c.chip, c.muted),
                    if ((r['assignedTo'] ?? '').toString().isNotEmpty)
                      _pill(
                        r['assignedTo'] == _myEmail
                            ? 'Mine'
                            : _shortName(r['assignedTo'].toString()),
                        c.chip,
                        c.muted,
                      ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  static String _titleCase(String s) => s.isEmpty
      ? s
      : s
            .split(' ')
            .map((w) => w.isEmpty ? w : w[0].toUpperCase() + w.substring(1))
            .join(' ');

  Widget _pill(String text, Color bg, Color fg) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
    decoration: BoxDecoration(
      color: bg,
      borderRadius: BorderRadius.circular(999),
    ),
    child: Text(
      text,
      style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: fg),
    ),
  );

  // ---- Map -----------------------------------------------------------------

  Widget _map(
    List<QueryDocumentSnapshot> reports,
    String? selectedId, {
    required bool phone,
  }) {
    final c = _c;
    final pts = <(String, Map<String, dynamic>, LatLng)>[];
    for (final d in reports) {
      final r = _data(d);
      final p = _point(r);
      if (p != null) pts.add((d.id, r, p));
    }
    LatLng center = const LatLng(33.6844, 73.0479); // Islamabad
    for (final p in pts) {
      if (p.$1 == selectedId) center = p.$3;
    }
    if (selectedId == null && pts.isNotEmpty) center = pts.first.$3;

    // When the set of pins changes (new reports, filters), zoom to show all.
    final pinKey = pts.map((p) => p.$1).join(',');
    if (pinKey != _lastPinKey) {
      final first = _lastPinKey == null;
      _lastPinKey = pinKey;
      if (!first && selectedId == null && pts.length > 1) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          try {
            _mapController.fitCamera(
              CameraFit.coordinates(
                coordinates: [for (final p in pts) p.$3],
                padding: const EdgeInsets.fromLTRB(40, 60, 40, 70),
                maxZoom: 15,
              ),
            );
          } catch (_) {
            // Map not on screen right now.
          }
        });
      }
    }

    return _panel(
      child: Stack(
        children: [
          FlutterMap(
            mapController: _mapController,
            options: MapOptions(
              initialCenter: center,
              initialZoom: 13,
              initialCameraFit: (selectedId == null && pts.length > 1)
                  ? CameraFit.coordinates(
                      coordinates: [for (final p in pts) p.$3],
                      padding: const EdgeInsets.fromLTRB(40, 60, 40, 70),
                      maxZoom: 15,
                    )
                  : null,
            ),
            children: [
              appTileLayer(tileBuilder: _dark ? darkModeTileBuilder : null),
              MarkerLayer(
                markers: [
                  for (final p in pts)
                    pinMarker(
                      point: p.$3,
                      color: _CC.pin(
                        PoliceReportCard.getPriorityDisplay(p.$2['priority']),
                      ),
                      label: _CC.pinLabel(
                        PoliceReportCard.getPriorityDisplay(p.$2['priority']),
                      ),
                      size: p.$1 == selectedId ? 46 : 36,
                      onTap: () => _select(p.$1, p.$2, phone: phone),
                    ),
                ],
              ),
            ],
          ),
          Positioned(
            left: 12,
            bottom: 12,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              decoration: BoxDecoration(
                color: c.panel.withValues(alpha: 0.92),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: c.borderStrong),
              ),
              child: Wrap(
                spacing: 12,
                runSpacing: 4,
                children: [
                  for (final l in const [
                    'CRITICAL',
                    'HIGH',
                    'MEDIUM',
                    'LOW',
                    'NEW',
                  ])
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Container(
                          width: 9,
                          height: 9,
                          decoration: BoxDecoration(
                            color: _CC.pin(l),
                            shape: BoxShape.circle,
                          ),
                        ),
                        const SizedBox(width: 4),
                        Text(
                          _CC.pinLabel(l),
                          style: TextStyle(
                            color: c.text,
                            fontSize: 11,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ),
                ],
              ),
            ),
          ),
          Positioned(
            top: 4,
            right: 6,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
              color: Colors.white70,
              child: const Text(
                mapAttribution,
                style: TextStyle(fontSize: 9, color: Colors.black87),
              ),
            ),
          ),
          if (pts.length > 1)
            Positioned(
              right: 12,
              bottom: 12,
              child: Material(
                color: c.panel,
                shape: const CircleBorder(),
                elevation: 2,
                child: IconButton(
                  tooltip: 'Show all reports',
                  icon: Icon(Icons.zoom_out_map, color: c.text),
                  onPressed: () => _mapController.fitCamera(
                    CameraFit.coordinates(
                      coordinates: [for (final p in pts) p.$3],
                      padding: const EdgeInsets.fromLTRB(40, 60, 40, 70),
                      maxZoom: 15,
                    ),
                  ),
                ),
              ),
            ),
          if (pts.isEmpty)
            Center(
              child: Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: c.panel,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Text(
                  'No reports with a location',
                  style: TextStyle(color: c.muted),
                ),
              ),
            ),
        ],
      ),
    );
  }

  // ---- Details -------------------------------------------------------------

  Widget _emptyDetail() {
    final c = _c;
    return _panel(
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            'Select a report to see its details',
            style: TextStyle(color: c.muted),
          ),
        ),
      ),
    );
  }

  Widget _detailPanel(String id, Map<String, dynamic> r) {
    final c = _c;
    final p = PoliceReportCard.getPriorityDisplay(r['priority']);
    final (pbg, pfg) = c.priority(p);
    final score = PoliceDashboardScreen.parseSeverityScore(r['severityScore']);
    final status = _statusOf(r);
    final (sbg, sfg) = c.status(status);
    final images = (r['images'] is List)
        ? (r['images'] as List).whereType<String>().toList()
        : <String>[];
    final factors = (r['detectedFactors'] is List)
        ? (r['detectedFactors'] as List).map((e) => e.toString()).toList()
        : <String>[];
    bool flag(String k) => PoliceReportCard.parseBoolField(r[k]) == true;
    final flagged = _isFlagged(r);
    final point = _point(r);
    final reason = (r['reason'] ?? '').toString().trim();
    final history = (r['statusHistory'] is List)
        ? (r['statusHistory'] as List)
              .whereType<Map>()
              .map((e) => Map<String, dynamic>.from(e))
              .toList()
              .reversed
              .toList()
        : <Map<String, dynamic>>[];
    final analyzing = _analyzingIds.contains(id);

    Widget section(String label) => Padding(
      padding: const EdgeInsets.only(top: 16, bottom: 8),
      child: Text(
        label,
        style: TextStyle(
          color: c.muted,
          fontSize: 12,
          fontWeight: FontWeight.w600,
        ),
      ),
    );

    return ListView(
      padding: const EdgeInsets.all(18),
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Ref #${id.length > 8 ? id.substring(0, 8).toUpperCase() : id}',
                    style: TextStyle(color: c.muted, fontSize: 12),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    _title(r),
                    style: TextStyle(
                      color: c.text,
                      fontSize: 18,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            _pill(
              p == 'Not Analyzed'
                  ? 'NOT ANALYZED'
                  : (score != null ? '$p · $score' : p),
              pbg,
              pfg,
            ),
          ],
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: [
            _pill(_titleCase(status), sbg, sfg),
            _pill((r['category'] ?? 'Other').toString(), c.chip, c.muted),
            _pill(
              _ago(PoliceDashboardScreen.getReportDateTime(r)),
              c.chip,
              c.muted,
            ),
            _pill(
              r['isAnonymous'] == true
                  ? 'Anonymous'
                  : (r['userEmail'] ?? 'Reporter').toString(),
              c.chip,
              c.muted,
            ),
          ],
        ),
        const SizedBox(height: 12),
        if (flagged)
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: const Color(0xFF7F1D1D).withValues(alpha: _dark ? 0.6 : 1),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Icon(Icons.flag, color: Color(0xFFFECACA), size: 20),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    'Flagged as ${r['moderation']} by an administrator'
                    '${(r['moderationReason'] ?? '').toString().isEmpty ? '' : ': ${r['moderationReason']}'}.\n'
                    'This case is closed and read-only. Only an administrator '
                    'can clear the flag and reopen it.',
                    style: const TextStyle(
                      color: Color(0xFFFEE2E2),
                      fontSize: 13,
                    ),
                  ),
                ),
              ],
            ),
          )
        else
          Container(
            padding: const EdgeInsets.fromLTRB(12, 4, 4, 4),
            decoration: BoxDecoration(
              color: c.chip,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Row(
              children: [
                Icon(Icons.badge_outlined, size: 18, color: c.muted),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    (r['assignedTo'] ?? '').toString().isEmpty
                        ? 'Not assigned'
                        : (r['assignedTo'] == _myEmail
                              ? 'Assigned to you'
                              : 'Assigned to ${r['assignedTo']}'),
                    style: TextStyle(color: c.text, fontSize: 13),
                  ),
                ),
                TextButton(
                  key: Key('assign_$id'),
                  onPressed: () =>
                      _assign(id, toMe: r['assignedTo'] != _myEmail),
                  child: Text(
                    r['assignedTo'] == _myEmail ? 'Unassign' : 'Assign to me',
                  ),
                ),
              ],
            ),
          ),
        const SizedBox(height: 14),
        Text(
          (r['description'] ?? 'No description').toString(),
          style: TextStyle(color: c.text, fontSize: 14, height: 1.5),
        ),
        section('AI ASSESSMENT'),
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: [
            if (flag('immediateDanger')) _pill('Immediate danger', pbg, pfg),
            if (flag('weaponDetected')) _pill('Weapon', pbg, pfg),
            if (flag('violenceDetected')) _pill('Violence', pbg, pfg),
            if (flag('injuryDetected')) _pill('Injury', pbg, pfg),
            if (flag('threatDetected')) _pill('Threat', pbg, pfg),
            for (final f in factors.take(4)) _pill(f, c.chip, c.muted),
            if (r['reporterFaceBlurred'] == true)
              _pill('Reporter face blurred', c.chip, c.muted),
          ],
        ),
        if (reason.isNotEmpty) ...[
          const SizedBox(height: 8),
          Text(reason, style: TextStyle(color: c.muted, fontSize: 13)),
        ],
        if (!flagged)
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              key: Key('analyze_report_$id'),
              onPressed: analyzing ? null : () => _analyzeReport(id, r),
              icon: analyzing
                  ? const SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.auto_awesome, size: 16),
              label: Text(
                analyzing
                    ? 'Analyzing…'
                    : (p == 'Not Analyzed'
                          ? 'Run AI analysis'
                          : 'Re-run AI analysis'),
              ),
            ),
          ),
        if (images.isNotEmpty) ...[
          section('EVIDENCE (${images.length})'),
          GridView.count(
            crossAxisCount: 3,
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            mainAxisSpacing: 6,
            crossAxisSpacing: 6,
            children: [
              for (final url in images)
                GestureDetector(
                  onTap: () => showDialog(
                    context: context,
                    builder: (_) => Dialog(
                      backgroundColor: Colors.black,
                      insetPadding: const EdgeInsets.all(12),
                      child: InteractiveViewer(
                        child: EvidenceImage(
                          url,
                          fit: BoxFit.contain,
                          placeholderColor: Colors.black,
                        ),
                      ),
                    ),
                  ),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(10),
                    child: EvidenceImage(url, placeholderColor: c.chip),
                  ),
                ),
            ],
          ),
        ],
        if (EvidenceVideos.has(r)) ...[
          section('VIDEO EVIDENCE'),
          EvidenceVideos.forReport(r, background: c.chip, foreground: c.text),
        ],
        section('LOCATION'),
        Row(
          children: [
            Icon(Icons.location_on_outlined, size: 18, color: c.muted),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                RoutingService.displayAddress(r),
                style: TextStyle(color: c.text, fontSize: 13),
              ),
            ),
            if (point != null)
              TextButton.icon(
                key: Key('directions_$id'),
                onPressed: () => PoliceReportCard._openDirections(
                  context,
                  point.latitude,
                  point.longitude,
                ),
                icon: const Icon(Icons.directions, size: 18),
                label: const Text('Directions'),
              ),
          ],
        ),
        if (history.isNotEmpty) ...[
          section('POLICE UPDATES'),
          for (final h in history.take(5))
            Container(
              margin: const EdgeInsets.only(bottom: 8),
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: c.chip,
                borderRadius: BorderRadius.circular(10),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      _pill(
                        _titleCase((h['status'] ?? '').toString()),
                        c.status((h['status'] ?? '').toString()).$1,
                        c.status((h['status'] ?? '').toString()).$2,
                      ),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          [
                            (h['by'] ?? '').toString(),
                            if (h['at'] is Timestamp)
                              _ago((h['at'] as Timestamp).toDate()),
                          ].where((s) => s.isNotEmpty).join(' · '),
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(color: c.muted, fontSize: 11.5),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Text(
                    (h['remarks'] ?? '').toString(),
                    style: TextStyle(color: c.text, fontSize: 13),
                  ),
                ],
              ),
            ),
        ] else if ((r['policeRemarks'] ?? '').toString().isNotEmpty) ...[
          section('POLICE REMARKS'),
          Text(
            r['policeRemarks'].toString(),
            style: TextStyle(color: c.text, fontSize: 13),
          ),
        ],
        const SizedBox(height: 18),
        if (!flagged)
          Row(
            children: [
              Expanded(
                child: FilledButton(
                  key: Key('status_in_progress_$id'),
                  style: FilledButton.styleFrom(
                    backgroundColor: _CC.accent,
                    minimumSize: const Size(0, 46),
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                  ),
                  onPressed: () =>
                      _showStatusSheet(id, r, initialStatus: 'in progress'),
                  child: const FittedBox(
                    fit: BoxFit.scaleDown,
                    child: Text('In progress', maxLines: 1, softWrap: false),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: FilledButton(
                  key: Key('status_resolve_$id'),
                  style: FilledButton.styleFrom(
                    backgroundColor: const Color(0xFF15803D),
                    minimumSize: const Size(0, 46),
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                  ),
                  onPressed: () =>
                      _showStatusSheet(id, r, initialStatus: 'resolved'),
                  child: const FittedBox(
                    fit: BoxFit.scaleDown,
                    child: Text('Resolve', maxLines: 1, softWrap: false),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: OutlinedButton(
                  key: Key('status_reject_$id'),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: c.text,
                    side: BorderSide(color: c.borderStrong),
                    minimumSize: const Size(0, 46),
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                  ),
                  onPressed: () =>
                      _showStatusSheet(id, r, initialStatus: 'rejected'),
                  child: const FittedBox(
                    fit: BoxFit.scaleDown,
                    child: Text('Reject', maxLines: 1, softWrap: false),
                  ),
                ),
              ),
            ],
          ),
      ],
    );
  }

  /// Police update a report's status with remarks the citizen can read.
  Future<void> _showStatusSheet(
    String docId,
    Map<String, dynamic> report, {
    String? initialStatus,
  }) async {
    if (_isFlagged(report)) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Flagged as fake by an administrator: only an admin can reopen it.',
          ),
        ),
      );
      return;
    }
    final current = (report['status'] ?? 'pending')
        .toString()
        .toLowerCase()
        .replaceAll('_', ' ');
    String status =
        initialStatus ??
        ((current == 'resolved' || current == 'rejected')
            ? current
            : 'in progress');
    final remarks = TextEditingController(
      text: (report['policeRemarks'] ?? '').toString(),
    );
    String? error;

    final saved = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      backgroundColor: _c.panel,
      builder: (ctx) => Theme(
        data: _themeData ?? Theme.of(ctx),
        child: StatefulBuilder(
          builder: (ctx, setSheet) => Padding(
            padding: EdgeInsets.fromLTRB(
              20,
              16,
              20,
              16 + MediaQuery.of(ctx).viewInsets.bottom,
            ),
            child: SafeArea(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Update report status',
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    (report['title'] ?? report['category'] ?? 'Report')
                        .toString(),
                    style: const TextStyle(color: AppColors.textMuted),
                  ),
                  const SizedBox(height: 16),
                  SegmentedButton<String>(
                    segments: const [
                      ButtonSegment(
                        value: 'in progress',
                        icon: Icon(Icons.hourglass_top),
                        label: Text('In progress'),
                      ),
                      ButtonSegment(
                        value: 'resolved',
                        icon: Icon(Icons.check_circle_outline),
                        label: Text('Resolved'),
                      ),
                      ButtonSegment(
                        value: 'rejected',
                        icon: Icon(Icons.block),
                        label: Text('Rejected'),
                      ),
                    ],
                    selected: {status},
                    onSelectionChanged: (v) => setSheet(() => status = v.first),
                  ),
                  const SizedBox(height: 16),
                  TextField(
                    controller: remarks,
                    minLines: 3,
                    maxLines: 6,
                    textCapitalization: TextCapitalization.sentences,
                    onChanged: (_) {
                      if (error != null) setSheet(() => error = null);
                    },
                    decoration: InputDecoration(
                      labelText: 'Police remarks',
                      hintText: switch (status) {
                        'resolved' => 'Suspect arrested, FIR no. 123/26 registered at City police station',
                        'rejected' => 'False report: no such incident found at this location',
                        _ => 'Officer assigned, visiting the location today',
                      },
                      errorText: error,
                      alignLabelWithHint: true,
                    ),
                  ),
                  const SizedBox(height: 6),
                  const Text(
                    'The citizen sees these remarks in My reports.',
                    style: TextStyle(fontSize: 12, color: AppColors.textMuted),
                  ),
                  const SizedBox(height: 16),
                  SizedBox(
                    width: double.infinity,
                    height: 52,
                    child: FilledButton(
                      onPressed: () {
                        if (remarks.text.trim().length < 5) {
                          setSheet(
                            () => error = 'Add a short remark for the citizen',
                          );
                          return;
                        }
                        Navigator.pop(ctx, true);
                      },
                      child: Text(switch (status) {
                        'resolved' => 'Mark resolved',
                        'rejected' => 'Reject report',
                        _ => 'Mark in progress',
                      }),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    if (saved != true) return;

    final remark = remarks.text.trim();
    final officer = FirebaseAuth.instance.currentUser?.email ?? 'Police';
    try {
      await FirebaseFirestore.instance.collection('reports').doc(docId).update({
        'status': status,
        'policeRemarks': remark,
        'remarksBy': officer,
        'remarksAt': FieldValue.serverTimestamp(),
        'updatedAt': FieldValue.serverTimestamp(),
        if (status == 'resolved') 'resolvedAt': FieldValue.serverTimestamp(),
        // Whoever first acts on an unassigned case takes it.
        if ((report['assignedTo'] ?? '').toString().isEmpty) ...{
          'assignedTo': officer,
          'assignedAt': FieldValue.serverTimestamp(),
        },
        'statusHistory': FieldValue.arrayUnion([
          {
            'status': status,
            'remarks': remark,
            'by': officer,
            'at': Timestamp.now(),
          },
        ]),
      });
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          backgroundColor: status == 'rejected'
              ? AppColors.warning
              : AppColors.success,
          content: Text(switch (status) {
            'resolved' => 'Report marked resolved',
            'rejected' => 'Report rejected',
            _ => 'Report marked in progress',
          }),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          backgroundColor: AppColors.danger,
          content: Text("Couldn't update the report: $e"),
        ),
      );
    }
  }
}

/// Phone: a report's details on their own page, kept live from Firestore.
class _PhoneDetailPage extends StatelessWidget {
  final String docId;
  final bool dark;
  final Widget Function(String id, Map<String, dynamic> data) buildDetail;
  const _PhoneDetailPage({
    required this.docId,
    required this.dark,
    required this.buildDetail,
  });

  @override
  Widget build(BuildContext context) {
    final c = _CC(dark);
    return Scaffold(
      backgroundColor: c.panel,
      appBar: AppBar(
        backgroundColor: c.panel,
        foregroundColor: c.text,
        title: const Text('Report'),
        shape: Border(bottom: BorderSide(color: c.border)),
      ),
      body: StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
        stream: FirebaseFirestore.instance
            .collection('reports')
            .doc(docId)
            .snapshots(),
        builder: (context, snap) {
          final data = snap.data?.data();
          if (data == null) {
            return const Center(child: CircularProgressIndicator());
          }
          return buildDetail(docId, data);
        },
      ),
    );
  }
}

class PoliceReportCard extends StatelessWidget {
  /// Opens Google Maps (app or browser) with directions to the incident.
  static Future<void> _openDirections(
    BuildContext context,
    double lat,
    double lng,
  ) async {
    final uri = Uri.parse(
      'https://www.google.com/maps/dir/?api=1&destination=$lat,$lng',
    );
    var ok = false;
    try {
      ok = await launchUrl(uri, mode: LaunchMode.externalApplication);
    } catch (_) {}
    if (!ok && context.mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text("Couldn't open maps")));
    }
  }

  final Map<String, dynamic> report;
  final String docId;
  final VoidCallback? onResolve;
  final VoidCallback? onAnalyze;
  final bool isAnalyzing;

  const PoliceReportCard({
    super.key,
    required this.report,
    required this.docId,
    this.onResolve,
    this.onAnalyze,
    this.isAnalyzing = false,
  });

  static String getPriorityDisplay(dynamic priority) {
    if (priority == null) return 'Not Analyzed';
    final p = priority.toString().trim();
    if (p.isEmpty) return 'Not Analyzed';
    final lower = p.toLowerCase();
    if (lower == 'critical') return 'CRITICAL';
    if (lower == 'high') return 'HIGH';
    if (lower == 'medium') return 'MEDIUM';
    if (lower == 'low') return 'LOW';
    if (lower == 'not analyzed' ||
        lower == 'not_analyzed' ||
        lower == 'pending') {
      return 'Not Analyzed';
    }
    return p.toUpperCase();
  }

  static String getSeverityScoreDisplay(dynamic severityScore) {
    if (severityScore == null) return 'Not Analyzed';
    if (severityScore is num) return severityScore.toInt().toString();
    final parsed = int.tryParse(severityScore.toString().trim());
    if (parsed != null) return parsed.toString();
    return 'Not Analyzed';
  }

  static Color getPriorityColor(String priorityDisplay) {
    switch (priorityDisplay) {
      case 'CRITICAL':
        return const Color(0xFF991B1B); // Deep Dark Red
      case 'HIGH':
        return const Color(0xFFDC2626); // Alert Red
      case 'MEDIUM':
        return const Color(0xFFD97706); // Amber / Orange
      case 'LOW':
        return const Color(0xFF16A34A); // Safe Green
      default:
        return Colors.grey.shade600;
    }
  }

  static Color getPriorityContainerColor(String priorityDisplay) {
    switch (priorityDisplay) {
      case 'CRITICAL':
        return const Color(0xFFFEE2E2);
      case 'HIGH':
        return const Color(0xFFFEF2F2);
      case 'MEDIUM':
        return const Color(0xFFFFFBEB);
      case 'LOW':
        return const Color(0xFFF0FDF4);
      default:
        return const Color(0xFFF3F4F6);
    }
  }

  static Color getPriorityBorderColor(String priorityDisplay) {
    switch (priorityDisplay) {
      case 'CRITICAL':
        return const Color(0xFFF87171);
      case 'HIGH':
        return const Color(0xFFFCA5A5);
      case 'MEDIUM':
        return const Color(0xFFFCD34D);
      case 'LOW':
        return const Color(0xFF86EFAC);
      default:
        return const Color(0xFFE5E7EB);
    }
  }

  static Widget buildPriorityBadgeWidget(dynamic rawPriority) {
    final display = getPriorityDisplay(rawPriority);
    final color = getPriorityColor(display);

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Text(
        display == 'Not Analyzed' ? 'NOT ANALYZED' : display,
        style: const TextStyle(
          color: Colors.white,
          fontSize: 11,
          fontWeight: FontWeight.bold,
        ),
      ),
    );
  }

  static bool? parseBoolField(dynamic val) {
    if (val == null) return null;
    if (val is bool) return val;
    if (val is String) {
      final lower = val.trim().toLowerCase();
      if (lower == 'true' || lower == 'yes' || lower == '1') return true;
      if (lower == 'false' || lower == 'no' || lower == '0') return false;
    }
    return null;
  }

  static Widget buildDangerIndicator({
    required String label,
    required bool? value,
    required IconData icon,
  }) {
    final bool isTrue = value == true;
    final bool isFalse = value == false;

    final Color bgColor = isTrue
        ? const Color(0xFFFEE2E2) // soft alert red
        : isFalse
        ? const Color(0xFFF0FDF4) // soft safe green
        : const Color(0xFFF3F4F6); // neutral grey

    final Color borderColor = isTrue
        ? const Color(0xFFF87171)
        : isFalse
        ? const Color(0xFF86EFAC)
        : const Color(0xFFD1D5DB);

    final Color textColor = isTrue
        ? const Color(0xFF991B1B)
        : isFalse
        ? const Color(0xFF166534)
        : const Color(0xFF4B5563);

    final IconData statusIcon = isTrue
        ? Icons.warning_amber_rounded
        : isFalse
        ? Icons.check_circle_outline
        : Icons.help_outline;

    final String statusText = isTrue
        ? 'YES'
        : isFalse
        ? 'No'
        : 'Not Analyzed';

    final String keyPrefix = label.replaceAll(' ', '_').toLowerCase();

    return Container(
      key: Key('danger_indicator_$keyPrefix'),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: bgColor,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: borderColor),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(statusIcon, size: 14, color: textColor),
          const SizedBox(width: 4),
          Flexible(
            child: Text(
              '$label: ',
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w600,
                color: textColor,
              ),
            ),
          ),
          Flexible(
            child: Text(
              statusText,
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.bold,
                color: textColor,
              ),
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final List<String> imageUrls = List<String>.from(report['images'] ?? []);
    final rawPriority = report['priority'];
    final rawSeverity = report['severityScore'];
    final priorityDisplay = getPriorityDisplay(rawPriority);
    final severityScoreDisplay = getSeverityScoreDisplay(rawSeverity);
    final reason = report['reason'] as String?;

    List<String> detectedFactors = [];
    if (report['detectedFactors'] is List) {
      detectedFactors = List<String>.from(
        (report['detectedFactors'] as List).map((e) => e.toString()),
      );
    }

    final bool? immediateDanger = parseBoolField(report['immediateDanger']);
    final bool? violenceDetected = parseBoolField(report['violenceDetected']);
    final bool? weaponDetected = parseBoolField(report['weaponDetected']);
    final bool? injuryDetected = parseBoolField(report['injuryDetected']);
    final bool? threatDetected = parseBoolField(report['threatDetected']);

    final bool isAiAnalyzed =
        (priorityDisplay != 'Not Analyzed') ||
        (rawSeverity != null) ||
        (reason != null && reason.trim().isNotEmpty) ||
        detectedFactors.isNotEmpty ||
        immediateDanger != null ||
        violenceDetected != null ||
        weaponDetected != null ||
        injuryDetected != null ||
        threatDetected != null;

    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: ExpansionTile(
        title: Row(
          children: [
            Expanded(
              child: Text(
                report['category'] ?? 'Unknown',
                style: const TextStyle(fontWeight: FontWeight.bold),
              ),
            ),
            if (report['verified'] == true) ...[
              const Icon(Icons.verified, size: 16, color: Colors.blue),
              const SizedBox(width: 6),
            ],
            buildPriorityBadgeWidget(rawPriority),
          ],
        ),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SizedBox(height: 2),
            Text(
              report['isAnonymous'] == true
                  ? 'Anonymous report'
                  : 'By: ${report['userEmail'] ?? 'Unknown'}',
              style: TextStyle(color: Colors.grey.shade700, fontSize: 13),
            ),
            const SizedBox(height: 6),
            Wrap(
              spacing: 12,
              runSpacing: 4,
              children: [
                Text(
                  'Priority: $priorityDisplay',
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.bold,
                    color: getPriorityColor(priorityDisplay),
                  ),
                ),
                Text(
                  'Severity Score: $severityScoreDisplay',
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: rawSeverity != null
                        ? getPriorityColor(priorityDisplay)
                        : Colors.grey.shade600,
                  ),
                ),
              ],
            ),
          ],
        ),
        children: [
          Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Description
                Text(report['description'] ?? 'No description'),
                const SizedBox(height: 12),

                // Location + directions
                Row(
                  children: [
                    const Icon(Icons.location_on, size: 16),
                    const SizedBox(width: 4),
                    Expanded(
                      child: Text(RoutingService.displayAddress(report)),
                    ),
                    if (report['latitude'] is num && report['longitude'] is num)
                      TextButton.icon(
                        key: Key('directions_$docId'),
                        onPressed: () => _openDirections(
                          context,
                          (report['latitude'] as num).toDouble(),
                          (report['longitude'] as num).toDouble(),
                        ),
                        icon: const Icon(Icons.directions, size: 18),
                        label: const Text('Directions'),
                      ),
                  ],
                ),
                const SizedBox(height: 12),

                // AI Assessment Section (Clearly separated)
                Container(
                  key: const Key('report_ai_analysis_section'),
                  width: double.infinity,
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: isAiAnalyzed
                        ? getPriorityContainerColor(priorityDisplay)
                        : Colors.grey.shade50,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(
                      color: isAiAnalyzed
                          ? getPriorityBorderColor(priorityDisplay)
                          : Colors.grey.shade300,
                    ),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // Header Row
                      Row(
                        children: [
                          Icon(
                            isAiAnalyzed
                                ? Icons.psychology
                                : Icons.psychology_outlined,
                            size: 20,
                            color: isAiAnalyzed
                                ? getPriorityColor(priorityDisplay)
                                : Colors.grey.shade600,
                          ),
                          const SizedBox(width: 6),
                          Flexible(
                            child: Text(
                              'AI Analysis',
                              style: TextStyle(
                                fontWeight: FontWeight.bold,
                                fontSize: 14,
                                color: isAiAnalyzed
                                    ? getPriorityColor(priorityDisplay)
                                    : Colors.grey.shade800,
                              ),
                            ),
                          ),
                          if (report['analysisSource'] == 'offline') ...[
                            const SizedBox(width: 6),
                            Text(
                              '(on-device estimate)',
                              style: TextStyle(
                                fontSize: 11,
                                color: Colors.grey.shade700,
                              ),
                            ),
                          ],
                          const Spacer(),
                          buildPriorityBadgeWidget(rawPriority),
                        ],
                      ),
                      const SizedBox(height: 10),

                      if (!isAiAnalyzed) ...[
                        Row(
                          children: [
                            Icon(
                              Icons.info_outline,
                              size: 16,
                              color: Colors.grey.shade600,
                            ),
                            const SizedBox(width: 6),
                            Flexible(
                              child: Text(
                                'AI Analysis: Not Analyzed',
                                style: TextStyle(
                                  fontSize: 12,
                                  fontWeight: FontWeight.bold,
                                  color: Colors.grey.shade700,
                                ),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 4),
                        Text(
                          'AI analysis is not available for this report (submitted prior to AI integration or unanalyzed).',
                          style: TextStyle(
                            fontSize: 12,
                            color: Colors.grey.shade600,
                          ),
                        ),
                      ] else ...[
                        // Priority and Severity Score Row
                        Row(
                          children: [
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    'Priority:',
                                    style: TextStyle(
                                      fontSize: 11,
                                      fontWeight: FontWeight.w600,
                                      color: Colors.grey.shade700,
                                    ),
                                  ),
                                  const SizedBox(height: 2),
                                  Text(
                                    priorityDisplay,
                                    style: TextStyle(
                                      fontSize: 13,
                                      fontWeight: FontWeight.bold,
                                      color: getPriorityColor(priorityDisplay),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    'Severity Score:',
                                    style: TextStyle(
                                      fontSize: 11,
                                      fontWeight: FontWeight.w600,
                                      color: Colors.grey.shade700,
                                    ),
                                  ),
                                  const SizedBox(height: 2),
                                  Text(
                                    rawSeverity != null
                                        ? '$severityScoreDisplay / 100'
                                        : 'Not Analyzed',
                                    style: TextStyle(
                                      fontSize: 13,
                                      fontWeight: FontWeight.bold,
                                      color: rawSeverity != null
                                          ? getPriorityColor(priorityDisplay)
                                          : Colors.grey.shade700,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 10),

                        // Reason
                        Text(
                          'Reason: ${reason != null && reason.trim().isNotEmpty ? reason : 'Not Analyzed'}',
                          style: TextStyle(
                            fontSize: 12,
                            color: Colors.grey.shade900,
                          ),
                        ),
                        const SizedBox(height: 10),

                        // Detected Factors
                        const Text(
                          'Detected Factors:',
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        const SizedBox(height: 4),
                        if (detectedFactors.isNotEmpty)
                          Wrap(
                            spacing: 6,
                            runSpacing: 4,
                            children: detectedFactors.map((factor) {
                              return Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 8,
                                  vertical: 2,
                                ),
                                decoration: BoxDecoration(
                                  color: Colors.white,
                                  borderRadius: BorderRadius.circular(4),
                                  border: Border.all(
                                    color: Colors.grey.shade300,
                                  ),
                                ),
                                child: Text(
                                  factor,
                                  style: const TextStyle(
                                    fontSize: 11,
                                    color: Colors.black87,
                                  ),
                                ),
                              );
                            }).toList(),
                          )
                        else
                          Text(
                            'None detected',
                            style: TextStyle(
                              fontSize: 11,
                              fontStyle: FontStyle.italic,
                              color: Colors.grey.shade600,
                            ),
                          ),
                        const SizedBox(height: 12),

                        // Danger & Threat Indicators
                        const Text(
                          'Danger & Threat Indicators:',
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        const SizedBox(height: 6),
                        Wrap(
                          spacing: 8,
                          runSpacing: 6,
                          children: [
                            buildDangerIndicator(
                              label: 'Immediate Danger',
                              value: immediateDanger,
                              icon: Icons.flash_on,
                            ),
                            buildDangerIndicator(
                              label: 'Violence Detected',
                              value: violenceDetected,
                              icon: Icons.front_hand,
                            ),
                            buildDangerIndicator(
                              label: 'Weapon Detected',
                              value: weaponDetected,
                              icon: Icons.warning_amber,
                            ),
                            buildDangerIndicator(
                              label: 'Injury Detected',
                              value: injuryDetected,
                              icon: Icons.medical_services,
                            ),
                            buildDangerIndicator(
                              label: 'Threat Detected',
                              value: threatDetected,
                              icon: Icons.crisis_alert,
                            ),
                          ],
                        ),
                      ],
                    ],
                  ),
                ),
                const SizedBox(height: 12),

                // Evidence Images
                if (imageUrls.isNotEmpty) ...[
                  const Text(
                    'Evidence Images:',
                    style: TextStyle(fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 8),
                  SizedBox(
                    height: 100,
                    child: ListView.builder(
                      scrollDirection: Axis.horizontal,
                      itemCount: imageUrls.length,
                      itemBuilder: (context, index) {
                        return Padding(
                          padding: const EdgeInsets.only(right: 8),
                          child: GestureDetector(
                            onTap: () {
                              showDialog(
                                context: context,
                                builder: (context) => Dialog(
                                  backgroundColor: Colors.black,
                                  child: GestureDetector(
                                    onTap: () => Navigator.pop(context),
                                    child: InteractiveViewer(
                                      child: EvidenceImage(
                                        imageUrls[index],
                                        fit: BoxFit.contain,
                                        placeholderColor: Colors.black,
                                      ),
                                    ),
                                  ),
                                ),
                              );
                            },
                            child: EvidenceImage(
                              imageUrls[index],
                              width: 100,
                              height: 100,
                            ),
                          ),
                        );
                      },
                    ),
                  ),
                  const SizedBox(height: 12),
                ],

                // AI (re)analysis button
                if (onAnalyze != null) ...[
                  SizedBox(
                    width: double.infinity,
                    child: OutlinedButton.icon(
                      key: Key('analyze_report_$docId'),
                      onPressed: isAnalyzing ? null : onAnalyze,
                      icon: isAnalyzing
                          ? const SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.auto_awesome, size: 18),
                      label: Text(
                        isAnalyzing
                            ? 'Analyzing…'
                            : (isAiAnalyzed &&
                                      report['analysisSource'] != 'offline'
                                  ? 'Re-run AI Analysis'
                                  : 'Run AI Analysis'),
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),
                ],

                // Latest police remarks
                if ((report['policeRemarks'] ?? '')
                    .toString()
                    .trim()
                    .isNotEmpty) ...[
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: AppColors.primarySoft,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'Police remarks',
                          style: TextStyle(
                            fontWeight: FontWeight.w700,
                            color: AppColors.primaryDark,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(report['policeRemarks'].toString()),
                        if (report['remarksBy'] != null) ...[
                          const SizedBox(height: 4),
                          Text(
                            '— ${report['remarksBy']}',
                            style: const TextStyle(
                              fontSize: 12,
                              color: AppColors.textMuted,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                  const SizedBox(height: 12),
                ],

                // Status update with remarks
                if (onResolve != null)
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton.icon(
                      key: Key('update_status_$docId'),
                      onPressed: onResolve,
                      icon: const Icon(Icons.edit_note),
                      label: Text(
                        (report['status'] ?? '').toString().toLowerCase() ==
                                'resolved'
                            ? 'Edit status & remarks'
                            : 'Update status & remarks',
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
