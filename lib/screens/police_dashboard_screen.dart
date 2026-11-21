import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import '../services/report_analysis_service.dart';
import '../services/routing_service.dart';

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
        return date.year == now.year && date.month == now.month && date.day == now.day;
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
    final matchesSearch = searchQuery.trim().isEmpty ||
        (report != null &&
            matchesSearchQuery(
              report: report,
              docId: docId ?? '',
              query: searchQuery,
            ));

    return matchesPriority &&
        matchesStatus &&
        matchesCategory &&
        matchesSearch;
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

  static int _compareFallbackId(Map<String, dynamic> a, Map<String, dynamic> b) {
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

class _PoliceDashboardScreenState extends State<PoliceDashboardScreen> {
  final TextEditingController _searchController = TextEditingController();
  String _searchQuery = '';
  String _selectedStatus = 'all';
  String _selectedPriority = 'all';
  String _selectedCategory = 'all';
  String _selectedSort = PoliceDashboardScreen.sortPriority;
  String _selectedDateRange = 'all';
  bool _dangerOnly = false;
  bool _showFilters = false;
  final Set<String> _analyzingIds = {};
  bool _bulkAnalyzing = false;
  List<QueryDocumentSnapshot> _latestDocs = [];

  int get _activeFilterCount =>
      (_selectedStatus != 'all' ? 1 : 0) +
      (_selectedPriority != 'all' ? 1 : 0) +
      (_selectedCategory != 'all' ? 1 : 0) +
      (_selectedDateRange != 'all' ? 1 : 0) +
      (_dangerOnly ? 1 : 0);

  void _clearFilters() {
    setState(() {
      _selectedStatus = 'all';
      _selectedPriority = 'all';
      _selectedCategory = 'all';
      _selectedDateRange = 'all';
      _dangerOnly = false;
      _searchQuery = '';
      _searchController.clear();
    });
  }

  Future<void> _analyzeReport(String docId, Map<String, dynamic> data) async {
    if (_analyzingIds.contains(docId)) return;
    setState(() => _analyzingIds.add(docId));
    bool usedGemini = false;
    try {
      usedGemini = await ReportAnalysisService()
          .analyzeAndSaveReport(docId: docId, report: data);
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
              : 'AI unavailable – saved an on-device estimate instead',
        ),
        backgroundColor: usedGemini ? Colors.green : Colors.orange,
      ),
    );
  }

  Future<void> _analyzeAllPending() async {
    final pending = _latestDocs
        .where((d) => ReportAnalysisService.needsAnalysis(
              d.data() as Map<String, dynamic>,
            ))
        .toList();
    if (pending.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('All reports already have an AI analysis')),
      );
      return;
    }
    setState(() => _bulkAnalyzing = true);
    int ok = 0;
    for (final doc in pending) {
      if (!mounted) return;
      setState(() => _analyzingIds.add(doc.id));
      try {
        if (await ReportAnalysisService().analyzeAndSaveReport(
          docId: doc.id,
          report: doc.data() as Map<String, dynamic>,
        )) {
          ok++;
        }
      } catch (_) {}
      if (!mounted) return;
      setState(() => _analyzingIds.remove(doc.id));
    }
    if (!mounted) return;
    setState(() => _bulkAnalyzing = false);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          'Analyzed ${pending.length} report(s) • $ok by AI, ${pending.length - ok} on-device',
        ),
      ),
    );
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Police Control Room'),
        actions: [
          IconButton(
            key: const Key('open_prioritization_button'),
            tooltip: 'Report Prioritization',
            icon: const Icon(Icons.insights),
            onPressed: () => Navigator.pushNamed(context, '/prioritization'),
          ),
          IconButton(
            key: const Key('analyze_all_reports_button'),
            tooltip: 'AI-prioritise unanalysed reports',
            icon: _bulkAnalyzing
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: Color(0xFF1D4ED8),
                    ),
                  )
                : const Icon(Icons.auto_awesome),
            onPressed: _bulkAnalyzing ? null : _analyzeAllPending,
          ),
          IconButton(
            icon: const Icon(Icons.logout),
            onPressed: () => FirebaseAuth.instance.signOut(),
          ),
        ],
      ),
      body: StreamBuilder<QuerySnapshot>(
        stream: FirebaseFirestore.instance
            .collection('reports')
            .orderBy('timestamp', descending: true)
            .snapshots(),
        builder: (context, snapshot) {
          int total = 0;
          int pending = 0;
          int resolved = 0;
          int highPriority = 0;
          List<QueryDocumentSnapshot> allDocs = [];

          if (snapshot.hasData) {
            allDocs = snapshot.data!.docs;
            _latestDocs = allDocs;
            total = allDocs.length;
            pending = allDocs
                .where((doc) =>
                    (doc['status'] ?? '').toString().toLowerCase() == 'pending')
                .length;
            resolved = allDocs
                .where((doc) =>
                    (doc['status'] ?? '').toString().toLowerCase() ==
                    'resolved')
                .length;
            highPriority = allDocs.where((doc) {
              final data = doc.data() as Map<String, dynamic>;
              final p = (data['priority'] ?? '').toString().toLowerCase();
              return p == 'high' || p == 'critical';
            }).length;
          }

          // Build dynamic categories set from application defaults + loaded reports
          final Set<String> categoriesSet = {
            ...PoliceDashboardScreen.applicationCategories,
          };
          for (final doc in allDocs) {
            final data = doc.data() as Map<String, dynamic>;
            final cat = data['category']?.toString().trim();
            if (cat != null && cat.isNotEmpty) {
              categoriesSet.add(cat);
            }
          }
          final categoriesList = ['All', ...categoriesSet];

          // Build dynamic statuses set from application defaults + loaded reports
          final Set<String> statusesSet = {
            ...PoliceDashboardScreen.applicationStatuses,
          };
          for (final doc in allDocs) {
            final data = doc.data() as Map<String, dynamic>;
            final st = data['status']?.toString().trim();
            if (st != null && st.isNotEmpty) {
              final lower = st.toLowerCase();
              if (lower == 'pending') {
                statusesSet.add('Pending');
              } else if (lower == 'resolved') {
                statusesSet.add('Resolved');
              } else if (lower == 'in progress' || lower == 'in_progress') {
                statusesSet.add('In Progress');
              } else if (lower == 'under review' || lower == 'under_review') {
                statusesSet.add('Under Review');
              } else {
                statusesSet.add(st);
              }
            }
          }
          final statusesList = ['All', ...statusesSet];

          // Filter reports using Priority, Status, Category, and Search simultaneously
          var reports = allDocs.where((doc) {
            final data = doc.data() as Map<String, dynamic>;
            return PoliceDashboardScreen.matchesReportFilters(
              rawPriority: data['priority'],
              rawStatus: data['status'],
              rawCategory: data['category'],
              priorityFilter: _selectedPriority,
              statusFilter: _selectedStatus,
              categoryFilter: _selectedCategory,
              report: data,
              docId: doc.id,
              searchQuery: _searchQuery,
            ) &&
                PoliceDashboardScreen.matchesDateRange(data, _selectedDateRange) &&
                (!_dangerOnly ||
                    PoliceReportCard.parseBoolField(data['immediateDanger']) == true);
          }).toList();

          // Sort reports in-memory using the selected sort option
          reports.sort((a, b) {
            final aData = a.data() as Map<String, dynamic>;
            final bData = b.data() as Map<String, dynamic>;
            return PoliceDashboardScreen.compareReports(
              a: aData,
              b: bData,
              sortOption: _selectedSort,
            );
          });

          return Column(
            children: [
              // Stats Row
              Container(
                padding: const EdgeInsets.all(16),
                child: Row(
                  children: [
                    _buildStatCard('Total', total.toString(), Colors.blue,
                        onTap: _clearFilters),
                    const SizedBox(width: 8),
                    _buildStatCard(
                      'Pending',
                      pending.toString(),
                      Colors.orange,
                      onTap: () => setState(() => _selectedStatus = 'pending'),
                    ),
                    const SizedBox(width: 8),
                    _buildStatCard(
                      'Resolved',
                      resolved.toString(),
                      Colors.green,
                      onTap: () => setState(() => _selectedStatus = 'resolved'),
                    ),
                    const SizedBox(width: 8),
                    _buildStatCard(
                      'High',
                      highPriority.toString(),
                      Colors.red,
                      onTap: () => setState(() => _selectedPriority = 'high'),
                    ),
                  ],
                ),
              ),

              // Search Field
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: TextField(
                  key: const Key('police_dashboard_search_field'),
                  controller: _searchController,
                  onChanged: (value) {
                    setState(() {
                      _searchQuery = value;
                    });
                  },
                  decoration: InputDecoration(
                    hintText:
                        'Search by title, description, category, location, ID...',
                    hintStyle: TextStyle(
                      fontSize: 13,
                      color: Colors.grey.shade500,
                    ),
                    prefixIcon: const Icon(
                      Icons.search,
                      size: 20,
                      color: Colors.grey,
                    ),
                    suffixIcon: _searchQuery.isNotEmpty
                        ? IconButton(
                            icon: const Icon(Icons.clear, size: 18),
                            onPressed: () {
                              _searchController.clear();
                              setState(() {
                                _searchQuery = '';
                              });
                            },
                          )
                        : null,
                    isDense: true,
                    contentPadding: const EdgeInsets.symmetric(
                      vertical: 10,
                      horizontal: 14,
                    ),
                    filled: true,
                    fillColor: Colors.grey.shade100,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(10),
                      borderSide: BorderSide(color: Colors.grey.shade300),
                    ),
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(10),
                      borderSide: BorderSide(color: Colors.grey.shade300),
                    ),
                    focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(10),
                      borderSide: const BorderSide(color: Colors.red),
                    ),
                  ),
                ),
              ),

              const SizedBox(height: 10),

              // Sort Dropdown Bar
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Row(
                  children: [
                    Icon(Icons.sort, size: 18, color: Colors.grey.shade700),
                    const SizedBox(width: 6),
                    Text(
                      'Sort by: ',
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.bold,
                        color: Colors.grey.shade700,
                      ),
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 2,
                        ),
                        decoration: BoxDecoration(
                          color: Colors.grey.shade100,
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(color: Colors.grey.shade300),
                        ),
                        child: DropdownButtonHideUnderline(
                          child: DropdownButton<String>(
                            key: const Key('police_dashboard_sort_dropdown'),
                            value: _selectedSort,
                            isExpanded: true,
                            isDense: true,
                            icon: const Icon(Icons.arrow_drop_down, color: Colors.red),
                            items: PoliceDashboardScreen.sortOptions.map((opt) {
                              return DropdownMenuItem<String>(
                                value: opt,
                                child: Text(
                                  opt,
                                  style: const TextStyle(fontSize: 12),
                                  overflow: TextOverflow.ellipsis,
                                ),
                              );
                            }).toList(),
                            onChanged: (newSort) {
                              if (newSort != null) {
                                setState(() {
                                  _selectedSort = newSort;
                                });
                              }
                            },
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),

              const SizedBox(height: 10),

              // Filter toggle + result count
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Row(
                  children: [
                    TextButton.icon(
                      key: const Key('toggle_filters_button'),
                      onPressed: () => setState(() => _showFilters = !_showFilters),
                      icon: Icon(
                        _showFilters ? Icons.filter_list_off : Icons.filter_list,
                        size: 18,
                        color: Colors.red,
                      ),
                      label: Text(
                        _activeFilterCount > 0
                            ? 'Filters ($_activeFilterCount)'
                            : 'Filters',
                        style: const TextStyle(color: Colors.red),
                      ),
                    ),
                    const Spacer(),
                    Text(
                      '${reports.length} of $total',
                      style: TextStyle(fontSize: 12, color: Colors.grey.shade700),
                    ),
                    if (_activeFilterCount > 0 || _searchQuery.isNotEmpty)
                      TextButton(
                        key: const Key('clear_filters_button'),
                        onPressed: _clearFilters,
                        child: const Text('Clear'),
                      ),
                  ],
                ),
              ),

              if (_showFilters) ...[
                  // Status Filter Chips
                  SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: Row(
                      children: [
                        Text(
                          'Status: ',
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.bold,
                            color: Colors.grey.shade700,
                          ),
                        ),
                        const SizedBox(width: 4),
                        ...statusesList.map((status) {
                          return Padding(
                            padding: const EdgeInsets.only(right: 8),
                            child: _buildStatusFilterChip(
                                status, status.toLowerCase()),
                          );
                        }),
                      ],
                    ),
                  ),

                  const SizedBox(height: 8),

                  // Priority Filter Chips
                  SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: Row(
                      children: [
                        Text(
                          'Priority: ',
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.bold,
                            color: Colors.grey.shade700,
                          ),
                        ),
                        const SizedBox(width: 4),
                        _buildPriorityFilterChip('All', 'all'),
                        const SizedBox(width: 8),
                        _buildPriorityFilterChip('Critical', 'critical'),
                        const SizedBox(width: 8),
                        _buildPriorityFilterChip('High', 'high'),
                        const SizedBox(width: 8),
                        _buildPriorityFilterChip('Medium', 'medium'),
                        const SizedBox(width: 8),
                        _buildPriorityFilterChip('Low', 'low'),
                        const SizedBox(width: 8),
                        _buildPriorityFilterChip('Not Analyzed', 'not_analyzed'),
                      ],
                    ),
                  ),

                  const SizedBox(height: 8),

                  // Category Filter Chips
                  SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: Row(
                      children: [
                        Text(
                          'Category: ',
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.bold,
                            color: Colors.grey.shade700,
                          ),
                        ),
                        const SizedBox(width: 4),
                        ...categoriesList.map((category) {
                          return Padding(
                            padding: const EdgeInsets.only(right: 8),
                            child: _buildCategoryFilterChip(
                                category, category.toLowerCase()),
                          );
                        }),
                      ],
                    ),
                  ),


                  const SizedBox(height: 8),

                  // Date Range Filter Chips
                  SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: Row(
                      children: [
                        Text(
                          'Date: ',
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.bold,
                            color: Colors.grey.shade700,
                          ),
                        ),
                        const SizedBox(width: 4),
                        ...PoliceDashboardScreen.dateRangeOptions.map((range) {
                          return Padding(
                            padding: const EdgeInsets.only(right: 8),
                            child: FilterChip(
                              key: Key('date_filter_$range'),
                              label: Text(PoliceDashboardScreen.dateRangeLabel(range)),
                              selected: _selectedDateRange == range,
                              onSelected: (_) =>
                                  setState(() => _selectedDateRange = range),
                              backgroundColor: Colors.grey.shade100,
                              selectedColor: Colors.teal.shade100,
                            ),
                          );
                        }),
                      ],
                    ),
                  ),

                  // Immediate danger only
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    child: SwitchListTile(
                      key: const Key('danger_only_switch'),
                      dense: true,
                      contentPadding: const EdgeInsets.symmetric(horizontal: 8),
                      title: const Text(
                        'Immediate danger only',
                        style: TextStyle(fontSize: 13),
                      ),
                      value: _dangerOnly,
                      onChanged: (v) => setState(() => _dangerOnly = v),
                    ),
                  ),
              ],

              const SizedBox(height: 6),

              // Reports List
              Expanded(
                child: Builder(
                  builder: (context) {
                    if (snapshot.hasError) {
                      return Center(child: Text('Error: ${snapshot.error}'));
                    }

                    if (snapshot.connectionState == ConnectionState.waiting) {
                      return const Center(child: CircularProgressIndicator());
                    }

                    if (reports.isEmpty) {
                      return const Center(child: Text('No reports found'));
                    }

                    return ListView.builder(
                      padding: const EdgeInsets.all(16),
                      itemCount: reports.length,
                      itemBuilder: (context, index) {
                        var report =
                            reports[index].data() as Map<String, dynamic>;
                        var docId = reports[index].id;
                        return _buildReportCard(report, docId);
                      },
                    );
                  },
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _buildStatCard(String title, String value, Color color,
      {VoidCallback? onTap}) {
    return Expanded(
      child: GestureDetector(
        onTap: onTap,
        child: Card(
        elevation: 4,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            children: [
              Text(title, style: TextStyle(fontSize: 12, color: Colors.grey)),
              const SizedBox(height: 4),
              Text(
                value,
                style: TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.bold,
                  color: color,
                ),
              ),
            ],
          ),
        ),
      ),
      ),
    );
  }

  Widget _buildStatusFilterChip(String label, String value) {
    return FilterChip(
      key: Key('status_filter_${value.toLowerCase()}'),
      label: Text(label),
      selected: _selectedStatus.toLowerCase() == value.toLowerCase(),
      onSelected: (selected) {
        setState(() {
          _selectedStatus = value;
        });
      },
      backgroundColor: Colors.grey.shade100,
      selectedColor: Colors.blue.shade100,
    );
  }

  Widget _buildPriorityFilterChip(String label, String value) {
    return FilterChip(
      key: Key('priority_filter_${value.toLowerCase()}'),
      label: Text(label),
      selected: _selectedPriority.toLowerCase() == value.toLowerCase(),
      onSelected: (selected) {
        setState(() {
          _selectedPriority = value;
        });
      },
      backgroundColor: Colors.grey.shade100,
      selectedColor: Colors.red.shade100,
    );
  }

  Widget _buildCategoryFilterChip(String label, String value) {
    return FilterChip(
      key: Key('category_filter_${value.toLowerCase()}'),
      label: Text(label),
      selected: _selectedCategory.toLowerCase() == value.toLowerCase(),
      onSelected: (selected) {
        setState(() {
          _selectedCategory = value;
        });
      },
      backgroundColor: Colors.grey.shade100,
      selectedColor: Colors.purple.shade100,
    );
  }

  Widget _buildReportCard(Map<String, dynamic> report, String docId) {
    return PoliceReportCard(
      report: report,
      docId: docId,
      onResolve: () => _updateStatus(docId, 'resolved'),
      onAnalyze: () => _analyzeReport(docId, report),
      isAnalyzing: _analyzingIds.contains(docId),
    );
  }

  Future<void> _updateStatus(String docId, String status) async {
    await FirebaseFirestore.instance.collection('reports').doc(docId).update({
      'status': status,
      'updatedAt': FieldValue.serverTimestamp(),
    });

    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text('Report marked as $status')));
  }
}

class PoliceReportCard extends StatelessWidget {
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
          Text(
            '$label: ',
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w600,
              color: textColor,
            ),
          ),
          Text(
            statusText,
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.bold,
              color: textColor,
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

    final bool isAiAnalyzed = (priorityDisplay != 'Not Analyzed') ||
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

                // Location
                Row(
                  children: [
                    const Icon(Icons.location_on, size: 16),
                    const SizedBox(width: 4),
                    Expanded(child: Text(RoutingService.displayAddress(report))),
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
                          Text(
                            'AI Analysis',
                            style: TextStyle(
                              fontWeight: FontWeight.bold,
                              fontSize: 14,
                              color: isAiAnalyzed
                                  ? getPriorityColor(priorityDisplay)
                                  : Colors.grey.shade800,
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
                            Text(
                              'AI Analysis: Not Analyzed',
                              style: TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.bold,
                                color: Colors.grey.shade700,
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

                // Verification selfie (if provided)
                if (report['verificationSelfieUrl'] is String) ...[
                  Row(
                    children: [
                      const Icon(Icons.verified, size: 14, color: Colors.blue),
                      const SizedBox(width: 4),
                      const Text(
                        'Verification Selfie (ML Kit verified)',
                        style: TextStyle(fontWeight: FontWeight.bold),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(8),
                    child: Image.network(
                      report['verificationSelfieUrl'] as String,
                      height: 100,
                      width: 100,
                      fit: BoxFit.cover,
                      errorBuilder: (c, e, s) =>
                          const Icon(Icons.broken_image, size: 40),
                    ),
                  ),
                  const SizedBox(height: 12),
                ],

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
                                      child: Image.network(imageUrls[index]),
                                    ),
                                  ),
                                ),
                              );
                            },
                            child: Image.network(
                              imageUrls[index],
                              width: 100,
                              height: 100,
                              fit: BoxFit.cover,
                              errorBuilder: (context, error, stackTrace) {
                                return Container(
                                  width: 100,
                                  height: 100,
                                  color: Colors.grey,
                                  child: const Icon(Icons.broken_image),
                                );
                              },
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
                            : (isAiAnalyzed && report['analysisSource'] != 'offline'
                                ? 'Re-run AI Analysis'
                                : 'Run AI Analysis'),
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),
                ],

                // Resolve Button
                if (onResolve != null &&
                    (report['status'] ?? '').toString().toLowerCase() != 'resolved')
                  ElevatedButton(
                    onPressed: onResolve,
                    child: const Text('Mark Resolved'),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
