import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import '../services/routing_service.dart';
import 'package:iconsax/iconsax.dart';

class ReportPrioritizationScreen extends StatefulWidget {
  const ReportPrioritizationScreen({super.key});

  @override
  State<ReportPrioritizationScreen> createState() => _ReportPrioritizationScreenState();
}

class _ReportPrioritizationScreenState extends State<ReportPrioritizationScreen> with SingleTickerProviderStateMixin {
  // Tab controller for different priority views
  late TabController _tabController;
  
  // Selected filter
  String _selectedFilter = 'All';
  final List<String> _filters = ['All', 'Today', 'This Week', 'This Month'];
  
  // Statistics
  int _totalReports = 0;
  int _highPriority = 0;
  int _mediumPriority = 0;
  int _lowPriority = 0;
  int _resolvedReports = 0;
  
  // Live reports from Firestore, mapped to the shape this screen displays.
  List<Map<String, dynamic>> _reports = [];
  bool _loading = true;
  String? _loadError;
  StreamSubscription<QuerySnapshot<Map<String, dynamic>>>? _subscription;

  /// Reports matching the selected date filter, highest AI score first.
  List<Map<String, dynamic>> get _visibleReports {
    final now = DateTime.now();
    return _reports.where((r) {
      final DateTime? date = r['date'] as DateTime?;
      switch (_selectedFilter) {
        case 'Today':
          return date != null &&
              date.year == now.year &&
              date.month == now.month &&
              date.day == now.day;
        case 'This Week':
          return date != null && now.difference(date).inDays < 7;
        case 'This Month':
          return date != null && now.difference(date).inDays < 30;
        default:
          return true;
      }
    }).toList();
  }

  static String _relativeTime(DateTime? d) {
    if (d == null) return 'Unknown time';
    final diff = DateTime.now().difference(d);
    if (diff.inMinutes < 1) return 'Just now';
    if (diff.inMinutes < 60) return '${diff.inMinutes} min ago';
    if (diff.inHours < 24) return '${diff.inHours} hour${diff.inHours == 1 ? '' : 's'} ago';
    if (diff.inDays < 30) return '${diff.inDays} day${diff.inDays == 1 ? '' : 's'} ago';
    return '${d.day}/${d.month}/${d.year}';
  }

  static Map<String, dynamic> _mapReport(String id, Map<String, dynamic> r) {
    DateTime? date;
    for (final key in ['timestamp', 'createdAt', 'date']) {
      final v = r[key];
      if (v is Timestamp) {
        date = v.toDate();
        break;
      }
      if (v is String) {
        date = DateTime.tryParse(v);
        if (date != null) break;
      }
    }

    final rawPriority = (r['priority'] ?? '').toString().toLowerCase();
    final String priority;
    if (rawPriority == 'critical' || rawPriority == 'high') {
      priority = 'High';
    } else if (rawPriority == 'low') {
      priority = 'Low';
    } else {
      priority = 'Medium';
    }

    final rawStatus = (r['status'] ?? 'pending').toString().toLowerCase().replaceAll('_', ' ');
    final status = rawStatus
        .split(' ')
        .map((w) => w.isEmpty ? w : w[0].toUpperCase() + w.substring(1))
        .join(' ');

    final score = r['severityScore'];
    final title = (r['title'] ?? '').toString().trim();
    final address = RoutingService.displayAddress(r);
    final factors = r['detectedFactors'];

    return {
      'id': id.substring(0, id.length < 6 ? id.length : 6).toUpperCase(),
      'title': title.isEmpty ? (r['category'] ?? 'Report').toString() : title,
      'category': (r['category'] ?? 'Other').toString(),
      'location': address.isEmpty ? 'Location not provided' : address,
      'time': _relativeTime(date),
      'date': date,
      'priority': priority,
      'status': status,
      'description': (r['description'] ?? '').toString(),
      'keywords': factors is List
          ? factors.map((e) => e.toString()).toList()
          : <String>[],
      'aiScore': score is num ? score.round() : 0,
    };
  }

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 3, vsync: this);
    _subscription = FirebaseFirestore.instance
        .collection('reports')
        .snapshots()
        .listen((snapshot) {
      final mapped = snapshot.docs
          .map((d) => _mapReport(d.id, d.data()))
          .toList()
        ..sort((a, b) => (b['aiScore'] as int).compareTo(a['aiScore'] as int));
      if (!mounted) return;
      setState(() {
        _reports = mapped;
        _loading = false;
        _loadError = null;
        _calculateStatistics();
      });
    }, onError: (Object e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _loadError = 'Could not load reports: $e';
      });
    });
  }

  @override
  void dispose() {
    _subscription?.cancel();
    _tabController.dispose();
    super.dispose();
  }

  void _calculateStatistics() {
    _totalReports = _reports.length;
    _highPriority = _reports.where((r) => r['priority'] == 'High').length;
    _mediumPriority = _reports.where((r) => r['priority'] == 'Medium').length;
    _lowPriority = _reports.where((r) => r['priority'] == 'Low').length;
    _resolvedReports = _reports.where((r) => r['status'] == 'Resolved').length;
  }

  // Get color based on priority
  Color _getPriorityColor(String priority) {
    switch (priority) {
      case 'High':
        return Colors.red;
      case 'Medium':
        return Colors.orange;
      case 'Low':
        return Colors.green;
      default:
        return Colors.grey;
    }
  }

  // Get icon based on category
  IconData _getCategoryIcon(String category) {
    switch (category) {
      case 'Robbery':
        return Iconsax.lock;
      case 'Harassment':
        return Iconsax.warning_2;
      case 'Suspicious Activity':
        return Iconsax.eye;
      case 'Snatching':
        return Iconsax.money;
      case 'Corruption':
        return Iconsax.money_tick;
      case 'Theft':
        return Iconsax.box_remove;
      case 'Disturbance':
        return Iconsax.volume_high;
      case 'Traffic':
        return Iconsax.car;
      case 'Infrastructure':
        return Iconsax.buildings;
      default:
        return Iconsax.note;
    }
  }

  // AI Analysis Dialog
  void _showAIAnalysis(Map<String, dynamic> report) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(20),
        ),
        title: Row(
          children: [
            Icon(Iconsax.cpu, color: const Color(0xFF1D4ED8)),
            const SizedBox(width: 8),
            const Flexible(child: Text('AI Priority Analysis')),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: _getPriorityColor(report['priority']).withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Row(
                children: [
                  Icon(
                    Iconsax.status,
                    color: _getPriorityColor(report['priority']),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'AI Priority Score',
                          style: TextStyle(fontSize: 12),
                        ),
                        Text(
                          '${report['priority']} Priority',
                          style: TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.bold,
                            color: _getPriorityColor(report['priority']),
                          ),
                        ),
                      ],
                    ),
                  ),
                  Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: _getPriorityColor(report['priority']),
                      shape: BoxShape.circle,
                    ),
                    child: Text(
                      '${report['aiScore']}',
                      style: const TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.bold,
                        fontSize: 16,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            
            const SizedBox(height: 15),
            
            const Text(
              'Detected Keywords',
              style: TextStyle(
                fontWeight: FontWeight.bold,
                fontSize: 14,
              ),
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: List<String>.from(report['keywords'] as List).map((keyword) => Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 4,
                ),
                decoration: BoxDecoration(
                  color: Colors.blue.shade50,
                  borderRadius: BorderRadius.circular(15),
                  border: Border.all(color: Colors.blue.shade200),
                ),
                child: Text(
                  keyword,
                  style: TextStyle(
                    fontSize: 11,
                    color: Colors.blue.shade700,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              )).toList(),
            ),
            
            const SizedBox(height: 15),
            
            const Text(
              'NLP Analysis',
              style: TextStyle(
                fontWeight: FontWeight.bold,
                fontSize: 14,
              ),
            ),
            const SizedBox(height: 8),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.grey.shade50,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Column(
                children: [
                  _buildAnalysisRow(
                    label: 'Threat Level',
                    value: report['aiScore'] > 80 ? 'Critical' : report['aiScore'] > 50 ? 'Moderate' : 'Low',
                    color: report['aiScore'] > 80 ? Colors.red : report['aiScore'] > 50 ? Colors.orange : Colors.green,
                  ),
                  const Divider(height: 8),
                  _buildAnalysisRow(
                    label: 'Urgency',
                    value: report['priority'],
                    color: _getPriorityColor(report['priority']),
                  ),
                  const Divider(height: 8),
                  _buildAnalysisRow(
                    label: 'Confidence',
                    value: '${report['aiScore']}%',
                    color: const Color(0xFF1D4ED8),
                  ),
                ],
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  Widget _buildAnalysisRow({
    required String label,
    required String value,
    required Color color,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Flexible(child: Text(
            label,
            style: TextStyle(
              fontSize: 13,
              color: Colors.grey.shade600,
            ),
          )),
          Flexible(child: Text(
            value,
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.bold,
              color: color,
            ),
          )),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Report Prioritization'),
        bottom: TabBar(
          controller: _tabController,
          indicatorColor: const Color(0xFF1D4ED8),
          labelColor: const Color(0xFF1D4ED8),
          unselectedLabelColor: const Color(0xFF475569),
          indicatorWeight: 3,
          tabs: const [
            Tab(text: 'All Reports'),
            Tab(text: 'AI Analysis'),
            Tab(text: 'Statistics'),
          ],
        ),
      ),
      body: TabBarView(
        controller: _tabController,
        children: [
          // All Reports Tab
          _buildAllReportsTab(),
          
          // AI Analysis Tab
          _buildAIAnalysisTab(),
          
          // Statistics Tab
          _buildStatisticsTab(),
        ],
      ),
    );
  }

  // Tab 1: All Reports
  Widget _buildAllReportsTab() {
    return Column(
      children: [
        // Filter Row
        Container(
          padding: const EdgeInsets.all(16),
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: _filters.map((filter) => Padding(
                padding: const EdgeInsets.only(right: 8),
                child: FilterChip(
                  label: Text(filter),
                  selected: _selectedFilter == filter,
                  onSelected: (selected) {
                    setState(() {
                      _selectedFilter = filter;
                    });
                  },
                  backgroundColor: Colors.grey.shade100,
                  selectedColor: const Color(0xFF1D4ED8).withValues(alpha: 0.2),
                  checkmarkColor: const Color(0xFF1D4ED8),
                  labelStyle: TextStyle(
                    color: _selectedFilter == filter
                        ? const Color(0xFF1D4ED8)
                        : Colors.grey.shade700,
                    fontWeight: _selectedFilter == filter
                        ? FontWeight.bold
                        : FontWeight.normal,
                  ),
                ),
              )).toList(),
            ),
          ),
        ),

        // Stats Summary
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Row(
            children: [
              _buildStatChip('Total', _totalReports.toString(), Colors.blue),
              const SizedBox(width: 8),
              _buildStatChip('High', _highPriority.toString(), Colors.red),
              const SizedBox(width: 8),
              _buildStatChip('Medium', _mediumPriority.toString(), Colors.orange),
              const SizedBox(width: 8),
              _buildStatChip('Low', _lowPriority.toString(), Colors.green),
            ],
          ),
        ),

        const SizedBox(height: 10),

        // Reports List
        Expanded(
          child: _loading
              ? const Center(child: CircularProgressIndicator())
              : _loadError != null
                  ? Center(
                      child: Padding(
                        padding: const EdgeInsets.all(24),
                        child: Text(_loadError!, textAlign: TextAlign.center),
                      ),
                    )
                  : _visibleReports.isEmpty
                      ? const Center(child: Text('No reports for this period'))
                      : ListView.builder(
            padding: const EdgeInsets.all(16),
            itemCount: _visibleReports.length,
            itemBuilder: (context, index) {
              final report = _visibleReports[index];
              return Container(
                margin: const EdgeInsets.only(bottom: 12),
                child: Card(
                  elevation: 2,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(15),
                  ),
                  child: InkWell(
                    onTap: () => _showAIAnalysis(report),
                    borderRadius: BorderRadius.circular(15),
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Container(
                                padding: const EdgeInsets.all(8),
                                decoration: BoxDecoration(
                                  color: _getPriorityColor(report['priority']).withValues(alpha: 0.1),
                                  borderRadius: BorderRadius.circular(10),
                                ),
                                child: Icon(
                                  _getCategoryIcon(report['category']),
                                  color: _getPriorityColor(report['priority']),
                                  size: 20,
                                ),
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      report['title'],
                                      style: const TextStyle(
                                        fontWeight: FontWeight.bold,
                                        fontSize: 15,
                                      ),
                                    ),
                                    const SizedBox(height: 4),
                                    Row(
                                      children: [
                                        Icon(
                                          Iconsax.location,
                                          size: 12,
                                          color: Colors.grey.shade500,
                                        ),
                                        const SizedBox(width: 4),
                                        Expanded(
                                          child: Text(
                                            report['location'],
                                            style: TextStyle(
                                              fontSize: 11,
                                              color: Colors.grey.shade600,
                                            ),
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ],
                                ),
                              ),
                              Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 10,
                                  vertical: 5,
                                ),
                                decoration: BoxDecoration(
                                  color: _getPriorityColor(report['priority']).withValues(alpha: 0.1),
                                  borderRadius: BorderRadius.circular(20),
                                  border: Border.all(
                                    color: _getPriorityColor(report['priority']).withValues(alpha: 0.3),
                                  ),
                                ),
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Container(
                                      width: 8,
                                      height: 8,
                                      decoration: BoxDecoration(
                                        shape: BoxShape.circle,
                                        color: _getPriorityColor(report['priority']),
                                      ),
                                    ),
                                    const SizedBox(width: 4),
                                    Text(
                                      report['priority'],
                                      style: TextStyle(
                                        fontSize: 10,
                                        fontWeight: FontWeight.bold,
                                        color: _getPriorityColor(report['priority']),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 12),
                          Text(
                            report['description'],
                            style: TextStyle(
                              fontSize: 13,
                              color: Colors.grey.shade700,
                            ),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                          const SizedBox(height: 12),
                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              Row(
                                children: [
                                  Icon(
                                    Iconsax.clock,
                                    size: 12,
                                    color: Colors.grey.shade500,
                                  ),
                                  const SizedBox(width: 4),
                                  Flexible(child: Text(
                                    report['time'],
                                    style: TextStyle(
                                      fontSize: 11,
                                      color: Colors.grey.shade600,
                                    ),
                                  )),
                                ],
                              ),
                              Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 8,
                                  vertical: 4,
                                ),
                                decoration: BoxDecoration(
                                  color: report['status'] == 'Resolved'
                                      ? Colors.green.shade100
                                      : report['status'] == 'In Progress'
                                          ? Colors.blue.shade100
                                          : Colors.orange.shade100,
                                  borderRadius: BorderRadius.circular(10),
                                ),
                                child: Text(
                                  report['status'],
                                  style: TextStyle(
                                    fontSize: 10,
                                    fontWeight: FontWeight.bold,
                                    color: report['status'] == 'Resolved'
                                        ? Colors.green.shade700
                                        : report['status'] == 'In Progress'
                                            ? Colors.blue.shade700
                                            : Colors.orange.shade700,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              );
            },
          ),
        ),
      ],
    );
  }

  // Tab 2: AI Analysis
  Widget _buildAIAnalysisTab() {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        const Text(
          'AI Priority Classification',
          style: TextStyle(
            fontSize: 18,
            fontWeight: FontWeight.bold,
          ),
        ),
        const SizedBox(height: 5),
        Text(
          'Reports automatically classified using NLP keyword analysis',
          style: TextStyle(
            fontSize: 13,
            color: Colors.grey.shade600,
          ),
        ),
        
        const SizedBox(height: 20),
        
        // Priority Distribution
        Card(
          elevation: 4,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(20),
          ),
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Priority Distribution',
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 15),
                
                _buildPriorityBar('High', _highPriority, _totalReports, Colors.red),
                const SizedBox(height: 10),
                _buildPriorityBar('Medium', _mediumPriority, _totalReports, Colors.orange),
                const SizedBox(height: 10),
                _buildPriorityBar('Low', _lowPriority, _totalReports, Colors.green),
              ],
            ),
          ),
        ),

        const SizedBox(height: 20),

        // Keyword Analysis
        Card(
          elevation: 4,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(20),
          ),
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Top Keywords Detected',
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 15),
                
                _buildKeywordRow('gun', 12, Colors.red),
                _buildKeywordRow('robbery', 10, Colors.red),
                _buildKeywordRow('harassment', 8, Colors.orange),
                _buildKeywordRow('snatching', 7, Colors.orange),
                _buildKeywordRow('corruption', 6, Colors.orange),
                _buildKeywordRow('theft', 5, Colors.green),
                _buildKeywordRow('noise', 4, Colors.green),
                _buildKeywordRow('parking', 3, Colors.green),
              ],
            ),
          ),
        ),

        const SizedBox(height: 20),

        // NLP Explanation
        Card(
          elevation: 4,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(20),
          ),
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              children: [
                _buildNLPFeature(
                  icon: Iconsax.search_normal,
                  title: 'Keyword Extraction',
                  description: 'Identifies threat-related keywords in reports',
                ),
                const Divider(),
                _buildNLPFeature(
                  icon: Iconsax.weight,
                  title: 'Sentiment Analysis',
                  description: 'Analyzes urgency and emotional tone',
                ),
                const Divider(),
                _buildNLPFeature(
                  icon: Iconsax.category,
                  title: 'Context Classification',
                  description: 'Categorizes based on incident type',
                ),
                const Divider(),
                _buildNLPFeature(
                  icon: Iconsax.graph,
                  title: 'Priority Scoring',
                  description: 'Calculates priority score (0-100)',
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  // Tab 3: Statistics
  Widget _buildStatisticsTab() {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        // Stats Cards
        GridView.count(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          crossAxisCount: 2,
          crossAxisSpacing: 10,
          mainAxisSpacing: 10,
          childAspectRatio: 1.0,
          children: [
            _buildStatCard(
              'Total Reports',
              _totalReports.toString(),
              Iconsax.document,
              Colors.blue,
              'All time',
            ),
            _buildStatCard(
              'High Priority',
              _highPriority.toString(),
              Iconsax.warning_2,
              Colors.red,
              '${((_highPriority / _totalReports) * 100).toStringAsFixed(1)}%',
            ),
            _buildStatCard(
              'Medium Priority',
              _mediumPriority.toString(),
              Iconsax.status,
              Colors.orange,
              '${((_mediumPriority / _totalReports) * 100).toStringAsFixed(1)}%',
            ),
            _buildStatCard(
              'Low Priority',
              _lowPriority.toString(),
              Iconsax.tick_circle,
              Colors.green,
              '${((_lowPriority / _totalReports) * 100).toStringAsFixed(1)}%',
            ),
            _buildStatCard(
              'Resolved',
              _resolvedReports.toString(),
              Iconsax.tick_circle,
              Colors.green,
              '${((_resolvedReports / _totalReports) * 100).toStringAsFixed(1)}%',
            ),
            _buildStatCard(
              'Pending',
              (_totalReports - _resolvedReports).toString(),
              Iconsax.clock,
              Colors.orange,
              'Needs attention',
            ),
          ],
        ),

        const SizedBox(height: 20),

        // Response Time Chart
        Card(
          elevation: 4,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(20),
          ),
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Average Response Time',
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 15),
                
                _buildResponseRow('High Priority', '8 min', 0.9, Colors.red),
                const SizedBox(height: 8),
                _buildResponseRow('Medium Priority', '25 min', 0.6, Colors.orange),
                const SizedBox(height: 8),
                _buildResponseRow('Low Priority', '2 hours', 0.3, Colors.green),
              ],
            ),
          ),
        ),

        const SizedBox(height: 20),

        // Category Distribution
        Card(
          elevation: 4,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(20),
          ),
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Reports by Category',
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 15),
                
                _buildCategoryRow('Robbery', 1, Colors.red),
                _buildCategoryRow('Harassment', 1, Colors.orange),
                _buildCategoryRow('Snatching', 1, Colors.orange),
                _buildCategoryRow('Theft', 1, Colors.orange),
                _buildCategoryRow('Corruption', 1, Colors.green),
                _buildCategoryRow('Disturbance', 1, Colors.green),
                _buildCategoryRow('Traffic', 1, Colors.green),
                _buildCategoryRow('Infrastructure', 1, Colors.green),
              ],
            ),
          ),
        ),
      ],
    );
  }

  // Helper Widgets
  Widget _buildStatChip(String label, String value, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: color.withValues(alpha: 0.3)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            '$label: ',
            style: TextStyle(
              fontSize: 11,
              color: color,
            ),
          ),
          Text(
            value,
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.bold,
              color: color,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPriorityBar(String label, int count, int total, Color color) {
    double percentage = total > 0 ? count / total : 0;
    return Column(
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Flexible(child: Text(
              label,
              style: TextStyle(
                fontWeight: FontWeight.w600,
                color: color,
              ),
            )),
            Flexible(child: Text(
              '$count reports (${(percentage * 100).toStringAsFixed(1)}%)',
              style: TextStyle(
                fontSize: 12,
                color: Colors.grey.shade600,
              ),
            )),
          ],
        ),
        const SizedBox(height: 6),
        LinearProgressIndicator(
          value: percentage,
          backgroundColor: color.withValues(alpha: 0.2),
          valueColor: AlwaysStoppedAnimation<Color>(color),
          minHeight: 8,
          borderRadius: BorderRadius.circular(4),
        ),
      ],
    );
  }

  Widget _buildKeywordRow(String keyword, int count, Color color) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        children: [
          Container(
            width: 30,
            height: 30,
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.1),
              shape: BoxShape.circle,
            ),
            child: Center(
              child: Text(
                count.toString(),
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.bold,
                  color: color,
                ),
              ),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              keyword,
              style: const TextStyle(
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Text(
              '${count * 5} occurrences',
              style: TextStyle(
                fontSize: 10,
                color: color,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildNLPFeature({
    required IconData icon,
    required String title,
    required String description,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: const Color(0xFF1D4ED8).withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(icon, color: const Color(0xFF1D4ED8), size: 20),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(
                    fontWeight: FontWeight.w600,
                  ),
                ),
                Text(
                  description,
                  style: TextStyle(
                    fontSize: 12,
                    color: Colors.grey.shade600,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildStatCard(String title, String value, IconData icon, Color color, String subtitle) {
    return Card(
      elevation: 2,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(15),
      ),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Container(
                  padding: const EdgeInsets.all(6),
                  decoration: BoxDecoration(
                    color: color.withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Icon(icon, color: color, size: 16),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              value,
              style: const TextStyle(
                fontSize: 24,
                fontWeight: FontWeight.bold,
              ),
            ),
            Text(
              title,
              style: TextStyle(
                fontSize: 11,
                color: Colors.grey.shade600,
              ),
            ),
            const SizedBox(height: 2),
            Text(
              subtitle,
              style: TextStyle(
                fontSize: 9,
                color: color,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildResponseRow(String label, String time, double value, Color color) {
    return Column(
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Flexible(child: Text(
              label,
              style: const TextStyle(fontSize: 13),
            )),
            Flexible(child: Text(
              time,
              style: TextStyle(
                fontWeight: FontWeight.bold,
                color: color,
              ),
            )),
          ],
        ),
        const SizedBox(height: 4),
        LinearProgressIndicator(
          value: value,
          backgroundColor: color.withValues(alpha: 0.2),
          valueColor: AlwaysStoppedAnimation<Color>(color),
          minHeight: 4,
          borderRadius: BorderRadius.circular(2),
        ),
      ],
    );
  }

  Widget _buildCategoryRow(String category, int count, Color color) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        children: [
          Container(
            width: 24,
            height: 24,
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.1),
              shape: BoxShape.circle,
            ),
            child: Center(
              child: Text(
                count.toString(),
                style: TextStyle(
                  fontSize: 10,
                  fontWeight: FontWeight.bold,
                  color: color,
                ),
              ),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              category,
              style: const TextStyle(fontSize: 13),
            ),
          ),
        ],
      ),
    );
  }
}