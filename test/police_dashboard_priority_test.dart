import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:safety_guardian/screens/police_dashboard_screen.dart';

void main() {
  group('Police Dashboard AI Priority & Report Card Tests', () {
    testWidgets('Displays CRITICAL priority report matching Firestore data exactly', (WidgetTester tester) async {
      final firestoreReport = {
        'category': 'Armed Robbery',
        'description': 'Gunmen entered the convenience store and threatened the cashier.',
        'address': 'F-6 Super Market, Islamabad',
        'userEmail': 'officer.test@safetyguardian.pk',
        'isAnonymous': false,
        'verified': true,
        // AI Prioritization fields from Firestore
        'priority': 'CRITICAL',
        'severityScore': 95,
        'reason': 'Armed confrontation with active firearm threat to life.',
        'detectedFactors': ['Armed robbery', 'Weapon present', 'Immediate danger'],
      };

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: PoliceReportCard(
                report: firestoreReport,
                docId: 'report_critical_001',
              ),
            ),
          ),
        ),
      );

      // Verify category and reporter
      expect(find.text('Armed Robbery'), findsOneWidget);
      expect(find.text('By: officer.test@safetyguardian.pk'), findsOneWidget);

      // Verify Priority and Severity Score displayed on the card
      expect(find.text('Priority: CRITICAL'), findsOneWidget);
      expect(find.text('Severity Score: 95'), findsOneWidget);

      // Verify Priority Badge
      expect(find.text('CRITICAL'), findsOneWidget);

      // Verify Priority Color is Deep Red (#991B1B)
      final badgeText = tester.widget<Text>(find.text('CRITICAL'));
      expect(badgeText.style?.color, Colors.white);
      expect(
        PoliceReportCard.getPriorityColor(
          PoliceReportCard.getPriorityDisplay(firestoreReport['priority']),
        ),
        const Color(0xFF991B1B),
      );

      // Expand ExpansionTile to inspect AI assessment details
      await tester.tap(find.text('Armed Robbery'));
      await tester.pumpAndSettle();

      // Verify Reason and Detected Factors
      expect(find.text('Reason: Armed confrontation with active firearm threat to life.'), findsOneWidget);
      expect(find.text('Detected Factors:'), findsOneWidget);
      expect(find.text('Armed robbery'), findsOneWidget);
      expect(find.text('Weapon present'), findsOneWidget);
      expect(find.text('Immediate danger'), findsOneWidget);
    });

    testWidgets('Displays HIGH priority report matching Firestore data exactly', (WidgetTester tester) async {
      final firestoreReport = {
        'category': 'Physical Assault',
        'description': 'Man attacked a bystander on Main Boulevard.',
        'address': 'Gulberg III, Lahore',
        'userEmail': 'witness@safetyguardian.pk',
        'isAnonymous': false,
        'verified': false,
        'priority': 'HIGH',
        'severityScore': 80,
        'reason': 'Physical assault causing injury and public threat.',
        'detectedFactors': ['Assault', 'Violence detected', 'Injury present'],
      };

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: PoliceReportCard(
                report: firestoreReport,
                docId: 'report_high_002',
              ),
            ),
          ),
        ),
      );

      expect(find.text('Priority: HIGH'), findsOneWidget);
      expect(find.text('Severity Score: 80'), findsOneWidget);
      expect(find.text('HIGH'), findsOneWidget);
      expect(
        PoliceReportCard.getPriorityColor('HIGH'),
        const Color(0xFFDC2626),
      );

      // Expand tile to verify AI analysis details
      await tester.tap(find.text('Physical Assault'));
      await tester.pumpAndSettle();

      expect(find.text('Reason: Physical assault causing injury and public threat.'), findsOneWidget);
      expect(find.text('Assault'), findsOneWidget);
      expect(find.text('Violence detected'), findsOneWidget);
    });

    testWidgets('Displays MEDIUM priority report matching Firestore data exactly', (WidgetTester tester) async {
      final firestoreReport = {
        'category': 'Vandalism',
        'description': 'Graffiti sprayed on public property wall.',
        'address': 'Saddar, Rawalpindi',
        'userEmail': 'citizen@safetyguardian.pk',
        'isAnonymous': false,
        'priority': 'MEDIUM',
        'severityScore': 50,
        'reason': 'Property damage without physical injuries or weapons.',
        'detectedFactors': ['Vandalism', 'Property damage'],
      };

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: PoliceReportCard(
                report: firestoreReport,
                docId: 'report_med_003',
              ),
            ),
          ),
        ),
      );

      expect(find.text('Priority: MEDIUM'), findsOneWidget);
      expect(find.text('Severity Score: 50'), findsOneWidget);
      expect(find.text('MEDIUM'), findsOneWidget);
      expect(
        PoliceReportCard.getPriorityColor('MEDIUM'),
        const Color(0xFFD97706),
      );
    });

    testWidgets('Displays LOW priority report matching Firestore data exactly', (WidgetTester tester) async {
      final firestoreReport = {
        'category': 'Lost Item',
        'description': 'Misplaced purse with keys in park.',
        'address': 'Fatima Jinnah Park, Islamabad',
        'userEmail': 'park.visitor@safetyguardian.pk',
        'isAnonymous': true,
        'priority': 'LOW',
        'severityScore': 15,
        'reason': 'Lost personal property without criminal threat.',
        'detectedFactors': ['Lost item', 'No threat'],
      };

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: PoliceReportCard(
                report: firestoreReport,
                docId: 'report_low_004',
              ),
            ),
          ),
        ),
      );

      expect(find.text('Priority: LOW'), findsOneWidget);
      expect(find.text('Severity Score: 15'), findsOneWidget);
      expect(find.text('LOW'), findsOneWidget);
      expect(
        PoliceReportCard.getPriorityColor('LOW'),
        const Color(0xFF16A34A),
      );
    });

    testWidgets('Safely handles old / unanalysed reports without AI fields', (WidgetTester tester) async {
      // Legacy report missing all AI fields
      final legacyReport = {
        'category': 'General Noise',
        'description': 'Loud music from next door.',
        'address': 'Street 10, Sector G-11, Islamabad',
        'userEmail': 'neighbor@test.com',
        'isAnonymous': false,
        // priority, severityScore, reason, detectedFactors are completely omitted / null
      };

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: PoliceReportCard(
                report: legacyReport,
                docId: 'legacy_report_005',
              ),
            ),
          ),
        ),
      );

      // Verify that "Not Analyzed" is displayed safely without exceptions
      expect(find.text('Priority: Not Analyzed'), findsOneWidget);
      expect(find.text('Severity Score: Not Analyzed'), findsOneWidget);
      expect(find.text('NOT ANALYZED'), findsOneWidget);
      expect(
        PoliceReportCard.getPriorityColor('Not Analyzed'),
        Colors.grey.shade600,
      );

      // Expand tile to ensure no crash
      await tester.tap(find.text('General Noise'));
      await tester.pumpAndSettle();

      expect(find.text('Loud music from next door.'), findsOneWidget);
      expect(find.text('Street 10, Sector G-11, Islamabad'), findsOneWidget);
    });

    testWidgets('Safely handles legacy report with old lowercase priority but missing score', (WidgetTester tester) async {
      final legacyReportWithOldPriority = {
        'category': 'Harassment',
        'description': 'Verbal harassment on street.',
        'address': 'Blue Area, Islamabad',
        'userEmail': 'user@safetyguardian.pk',
        'priority': 'high', // Old lowercase string from before AI was integrated
        // severityScore is missing
      };

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: PoliceReportCard(
                report: legacyReportWithOldPriority,
                docId: 'legacy_report_006',
              ),
            ),
          ),
        ),
      );

      expect(find.text('Priority: HIGH'), findsOneWidget);
      expect(find.text('Severity Score: Not Analyzed'), findsOneWidget);
      expect(find.text('HIGH'), findsOneWidget);
    });

    test('Helper method unit tests for priority and score parsing', () {
      expect(PoliceReportCard.getPriorityDisplay('CRITICAL'), 'CRITICAL');
      expect(PoliceReportCard.getPriorityDisplay('critical'), 'CRITICAL');
      expect(PoliceReportCard.getPriorityDisplay('HIGH'), 'HIGH');
      expect(PoliceReportCard.getPriorityDisplay('high'), 'HIGH');
      expect(PoliceReportCard.getPriorityDisplay('MEDIUM'), 'MEDIUM');
      expect(PoliceReportCard.getPriorityDisplay('medium'), 'MEDIUM');
      expect(PoliceReportCard.getPriorityDisplay('LOW'), 'LOW');
      expect(PoliceReportCard.getPriorityDisplay('low'), 'LOW');
      expect(PoliceReportCard.getPriorityDisplay(null), 'Not Analyzed');
      expect(PoliceReportCard.getPriorityDisplay(''), 'Not Analyzed');
      expect(PoliceReportCard.getPriorityDisplay('pending'), 'Not Analyzed');
      expect(PoliceReportCard.getPriorityDisplay('Not Analyzed'), 'Not Analyzed');

      expect(PoliceReportCard.getSeverityScoreDisplay(95), '95');
      expect(PoliceReportCard.getSeverityScoreDisplay(0), '0');
      expect(PoliceReportCard.getSeverityScoreDisplay(100), '100');
      expect(PoliceReportCard.getSeverityScoreDisplay('75'), '75');
      expect(PoliceReportCard.getSeverityScoreDisplay(null), 'Not Analyzed');
      expect(PoliceReportCard.getSeverityScoreDisplay(''), 'Not Analyzed');
      expect(PoliceReportCard.getSeverityScoreDisplay('invalid'), 'Not Analyzed');
    });

    group('Priority Filter Logic & Selection Tests', () {
      final sampleReports = [
        {'id': '1', 'priority': 'CRITICAL', 'category': 'Armed Robbery'},
        {'id': '2', 'priority': 'HIGH', 'category': 'Assault'},
        {'id': '3', 'priority': 'MEDIUM', 'category': 'Theft'},
        {'id': '4', 'priority': 'LOW', 'category': 'Noise Complaint'},
        {'id': '5', 'priority': null, 'category': 'Old Report 1'},
        {'id': '6', 'priority': '', 'category': 'Old Report 2'},
        {'id': '7', 'priority': 'Not Analyzed', 'category': 'Pending Report'},
      ];

      test('Filter "All" returns every single report', () {
        final filtered = sampleReports.where((r) {
          return PoliceDashboardScreen.matchesPriorityFilter(r['priority'], 'all');
        }).toList();

        expect(filtered.length, 7);
      });

      test('Filter "Critical" returns only Critical reports', () {
        final filtered = sampleReports.where((r) {
          return PoliceDashboardScreen.matchesPriorityFilter(r['priority'], 'critical');
        }).toList();

        expect(filtered.length, 1);
        expect(filtered.first['id'], '1');
        expect(filtered.first['priority'], 'CRITICAL');
      });

      test('Filter "High" returns only High reports', () {
        final filtered = sampleReports.where((r) {
          return PoliceDashboardScreen.matchesPriorityFilter(r['priority'], 'high');
        }).toList();

        expect(filtered.length, 1);
        expect(filtered.first['id'], '2');
        expect(filtered.first['priority'], 'HIGH');
      });

      test('Filter "Medium" returns only Medium reports', () {
        final filtered = sampleReports.where((r) {
          return PoliceDashboardScreen.matchesPriorityFilter(r['priority'], 'medium');
        }).toList();

        expect(filtered.length, 1);
        expect(filtered.first['id'], '3');
        expect(filtered.first['priority'], 'MEDIUM');
      });

      test('Filter "Low" returns only Low reports', () {
        final filtered = sampleReports.where((r) {
          return PoliceDashboardScreen.matchesPriorityFilter(r['priority'], 'low');
        }).toList();

        expect(filtered.length, 1);
        expect(filtered.first['id'], '4');
        expect(filtered.first['priority'], 'LOW');
      });

      test('Filter "Not Analyzed" returns only reports where priority is null, empty, or unanalyzed', () {
        final filtered = sampleReports.where((r) {
          return PoliceDashboardScreen.matchesPriorityFilter(r['priority'], 'not_analyzed');
        }).toList();

        expect(filtered.length, 3);
        expect(filtered.map((r) => r['id']).toList(), ['5', '6', '7']);
      });

      test('Case-insensitivity and whitespace safety in matchesPriorityFilter', () {
        expect(PoliceDashboardScreen.matchesPriorityFilter(' critical ', 'critical'), isTrue);
        expect(PoliceDashboardScreen.matchesPriorityFilter('High', 'high'), isTrue);
        expect(PoliceDashboardScreen.matchesPriorityFilter('medium', 'medium'), isTrue);
        expect(PoliceDashboardScreen.matchesPriorityFilter('LOW', 'low'), isTrue);
        expect(PoliceDashboardScreen.matchesPriorityFilter('not_analyzed', 'not_analyzed'), isTrue);
      });

      testWidgets('Widget Test: Tapping Priority Filter chips filters loaded reports in real time', (WidgetTester tester) async {
        String selectedPriority = 'all';

        final reports = [
          {'id': '1', 'priority': 'CRITICAL', 'category': 'Armed Robbery', 'description': 'Gun violence', 'address': 'F-6'},
          {'id': '2', 'priority': 'HIGH', 'category': 'Assault', 'description': 'Street fight', 'address': 'Gulberg'},
          {'id': '3', 'priority': 'MEDIUM', 'category': 'Theft', 'description': 'Bicycle stolen', 'address': 'Saddar'},
          {'id': '4', 'priority': 'LOW', 'category': 'Noise Complaint', 'description': 'Loud music', 'address': 'F-10'},
          {'id': '5', 'priority': null, 'category': 'Old Unanalysed Report', 'description': 'Lost bag', 'address': 'G-11'},
        ];

        await tester.pumpWidget(
          MaterialApp(
            home: StatefulBuilder(
              builder: (context, setState) {
                final filtered = reports.where((r) {
                  return PoliceDashboardScreen.matchesPriorityFilter(r['priority'], selectedPriority);
                }).toList();

                return Scaffold(
                  body: Column(
                    children: [
                      SingleChildScrollView(
                        scrollDirection: Axis.horizontal,
                        child: Row(
                          children: [
                            FilterChip(
                              label: const Text('All'),
                              selected: selectedPriority == 'all',
                              onSelected: (_) => setState(() => selectedPriority = 'all'),
                            ),
                            FilterChip(
                              label: const Text('Critical'),
                              selected: selectedPriority == 'critical',
                              onSelected: (_) => setState(() => selectedPriority = 'critical'),
                            ),
                            FilterChip(
                              label: const Text('High'),
                              selected: selectedPriority == 'high',
                              onSelected: (_) => setState(() => selectedPriority = 'high'),
                            ),
                            FilterChip(
                              label: const Text('Medium'),
                              selected: selectedPriority == 'medium',
                              onSelected: (_) => setState(() => selectedPriority = 'medium'),
                            ),
                            FilterChip(
                              label: const Text('Low'),
                              selected: selectedPriority == 'low',
                              onSelected: (_) => setState(() => selectedPriority = 'low'),
                            ),
                            FilterChip(
                              label: const Text('Not Analyzed'),
                              selected: selectedPriority == 'not_analyzed',
                              onSelected: (_) => setState(() => selectedPriority = 'not_analyzed'),
                            ),
                          ],
                        ),
                      ),
                      Expanded(
                        child: ListView.builder(
                          itemCount: filtered.length,
                          itemBuilder: (context, index) {
                            return PoliceReportCard(
                              report: filtered[index],
                              docId: filtered[index]['id']!,
                            );
                          },
                        ),
                      ),
                    ],
                  ),
                );
              },
            ),
          ),
        );

        // Initially All (5 reports present)
        expect(find.text('Armed Robbery'), findsOneWidget);
        expect(find.text('Assault'), findsOneWidget);
        expect(find.text('Theft'), findsOneWidget);
        expect(find.text('Noise Complaint'), findsOneWidget);
        expect(find.text('Old Unanalysed Report'), findsOneWidget);

        // Tap Critical: only Armed Robbery remains
        await tester.tap(find.text('Critical'));
        await tester.pumpAndSettle();
        expect(find.text('Armed Robbery'), findsOneWidget);
        expect(find.text('Assault'), findsNothing);
        expect(find.text('Theft'), findsNothing);
        expect(find.text('Noise Complaint'), findsNothing);
        expect(find.text('Old Unanalysed Report'), findsNothing);

        // Tap High: only Assault remains
        await tester.tap(find.text('High'));
        await tester.pumpAndSettle();
        expect(find.text('Armed Robbery'), findsNothing);
        expect(find.text('Assault'), findsOneWidget);
        expect(find.text('Theft'), findsNothing);

        // Tap Medium: only Theft remains
        await tester.tap(find.text('Medium'));
        await tester.pumpAndSettle();
        expect(find.text('Theft'), findsOneWidget);
        expect(find.text('Assault'), findsNothing);

        // Tap Low: only Noise Complaint remains
        await tester.tap(find.text('Low'));
        await tester.pumpAndSettle();
        expect(find.text('Noise Complaint'), findsOneWidget);
        expect(find.text('Theft'), findsNothing);

        // Tap Not Analyzed: only Old Unanalysed Report remains
        await tester.tap(find.text('Not Analyzed'));
        await tester.pumpAndSettle();
        expect(find.text('Old Unanalysed Report'), findsOneWidget);
        expect(find.text('Noise Complaint'), findsNothing);

        // Tap All: all reports return
        await tester.tap(find.text('All'));
        await tester.pumpAndSettle();
        expect(find.text('Armed Robbery'), findsOneWidget);
        expect(find.text('Old Unanalysed Report'), findsOneWidget);
      });
    });

    group('Category, Status & Multi-Filter Combination Tests', () {
      final multiReports = [
        {'id': 'R1', 'priority': 'CRITICAL', 'category': 'Robbery', 'status': 'pending'},
        {'id': 'R2', 'priority': 'CRITICAL', 'category': 'Robbery', 'status': 'resolved'},
        {'id': 'R3', 'priority': 'CRITICAL', 'category': 'Assault', 'status': 'pending'},
        {'id': 'R4', 'priority': 'HIGH', 'category': 'Robbery', 'status': 'pending'},
        {'id': 'R5', 'priority': 'HIGH', 'category': 'Assault', 'status': 'in progress'},
        {'id': 'R6', 'priority': 'MEDIUM', 'category': 'Theft', 'status': 'pending'},
        {'id': 'R7', 'priority': 'MEDIUM', 'category': 'Theft', 'status': 'resolved'},
        {'id': 'R8', 'priority': 'LOW', 'category': 'Traffic Violation', 'status': 'pending'},
        {'id': 'R9', 'priority': null, 'category': null, 'status': null},
        {'id': 'R10', 'priority': null, 'category': 'Harassment', 'status': 'under review'},
      ];

      test('Test 1: Category filter alone', () {
        // Robbery alone
        final robberyReports = multiReports.where((r) {
          return PoliceDashboardScreen.matchesReportFilters(
            rawPriority: r['priority'],
            rawStatus: r['status'],
            rawCategory: r['category'],
            priorityFilter: 'all',
            statusFilter: 'all',
            categoryFilter: 'Robbery',
          );
        }).toList();

        expect(robberyReports.length, 3);
        expect(robberyReports.map((r) => r['id']).toList(), ['R1', 'R2', 'R4']);

        // Assault alone
        final assaultReports = multiReports.where((r) {
          return PoliceDashboardScreen.matchesReportFilters(
            rawPriority: r['priority'],
            rawStatus: r['status'],
            rawCategory: r['category'],
            priorityFilter: 'all',
            statusFilter: 'all',
            categoryFilter: 'Assault',
          );
        }).toList();

        expect(assaultReports.length, 2);
        expect(assaultReports.map((r) => r['id']).toList(), ['R3', 'R5']);
      });

      test('Test 2: Status filter alone', () {
        // Pending alone
        final pendingReports = multiReports.where((r) {
          return PoliceDashboardScreen.matchesReportFilters(
            rawPriority: r['priority'],
            rawStatus: r['status'],
            rawCategory: r['category'],
            priorityFilter: 'all',
            statusFilter: 'pending',
            categoryFilter: 'all',
          );
        }).toList();

        expect(pendingReports.length, 5);
        expect(pendingReports.map((r) => r['id']).toList(), ['R1', 'R3', 'R4', 'R6', 'R8']);

        // Resolved alone
        final resolvedReports = multiReports.where((r) {
          return PoliceDashboardScreen.matchesReportFilters(
            rawPriority: r['priority'],
            rawStatus: r['status'],
            rawCategory: r['category'],
            priorityFilter: 'all',
            statusFilter: 'resolved',
            categoryFilter: 'all',
          );
        }).toList();

        expect(resolvedReports.length, 2);
        expect(resolvedReports.map((r) => r['id']).toList(), ['R2', 'R7']);

        // In Progress alone
        final inProgressReports = multiReports.where((r) {
          return PoliceDashboardScreen.matchesReportFilters(
            rawPriority: r['priority'],
            rawStatus: r['status'],
            rawCategory: r['category'],
            priorityFilter: 'all',
            statusFilter: 'in progress',
            categoryFilter: 'all',
          );
        }).toList();

        expect(inProgressReports.length, 1);
        expect(inProgressReports.first['id'], 'R5');
      });

      test('Test 3: Category + Status together', () {
        // Robbery + Pending
        final robberyPending = multiReports.where((r) {
          return PoliceDashboardScreen.matchesReportFilters(
            rawPriority: r['priority'],
            rawStatus: r['status'],
            rawCategory: r['category'],
            priorityFilter: 'all',
            statusFilter: 'pending',
            categoryFilter: 'Robbery',
          );
        }).toList();

        expect(robberyPending.length, 2);
        expect(robberyPending.map((r) => r['id']).toList(), ['R1', 'R4']);

        // Robbery + Resolved
        final robberyResolved = multiReports.where((r) {
          return PoliceDashboardScreen.matchesReportFilters(
            rawPriority: r['priority'],
            rawStatus: r['status'],
            rawCategory: r['category'],
            priorityFilter: 'all',
            statusFilter: 'resolved',
            categoryFilter: 'Robbery',
          );
        }).toList();

        expect(robberyResolved.length, 1);
        expect(robberyResolved.first['id'], 'R2');

        // Theft + Resolved
        final theftResolved = multiReports.where((r) {
          return PoliceDashboardScreen.matchesReportFilters(
            rawPriority: r['priority'],
            rawStatus: r['status'],
            rawCategory: r['category'],
            priorityFilter: 'all',
            statusFilter: 'resolved',
            categoryFilter: 'Theft',
          );
        }).toList();

        expect(theftResolved.length, 1);
        expect(theftResolved.first['id'], 'R7');
      });

      test('Test 4: Priority + Category + Status together', () {
        // Example from requirements: Critical + Pending
        final criticalPending = multiReports.where((r) {
          return PoliceDashboardScreen.matchesReportFilters(
            rawPriority: r['priority'],
            rawStatus: r['status'],
            rawCategory: r['category'],
            priorityFilter: 'critical',
            statusFilter: 'pending',
            categoryFilter: 'all',
          );
        }).toList();

        expect(criticalPending.length, 2);
        expect(criticalPending.map((r) => r['id']).toList(), ['R1', 'R3']);

        // Critical + Robbery + Pending
        final critRobberyPending = multiReports.where((r) {
          return PoliceDashboardScreen.matchesReportFilters(
            rawPriority: r['priority'],
            rawStatus: r['status'],
            rawCategory: r['category'],
            priorityFilter: 'critical',
            statusFilter: 'pending',
            categoryFilter: 'Robbery',
          );
        }).toList();

        expect(critRobberyPending.length, 1);
        expect(critRobberyPending.first['id'], 'R1');

        // High + Robbery + Pending
        final highRobberyPending = multiReports.where((r) {
          return PoliceDashboardScreen.matchesReportFilters(
            rawPriority: r['priority'],
            rawStatus: r['status'],
            rawCategory: r['category'],
            priorityFilter: 'high',
            statusFilter: 'pending',
            categoryFilter: 'Robbery',
          );
        }).toList();

        expect(highRobberyPending.length, 1);
        expect(highRobberyPending.first['id'], 'R4');

        // Not Analyzed + Harassment + Under Review
        final legacyHarassment = multiReports.where((r) {
          return PoliceDashboardScreen.matchesReportFilters(
            rawPriority: r['priority'],
            rawStatus: r['status'],
            rawCategory: r['category'],
            priorityFilter: 'not_analyzed',
            statusFilter: 'under review',
            categoryFilter: 'Harassment',
          );
        }).toList();

        expect(legacyHarassment.length, 1);
        expect(legacyHarassment.first['id'], 'R10');
      });

      test('Existing Priority Filter continues to work correctly alone', () {
        // Critical alone
        final criticalOnly = multiReports.where((r) {
          return PoliceDashboardScreen.matchesReportFilters(
            rawPriority: r['priority'],
            rawStatus: r['status'],
            rawCategory: r['category'],
            priorityFilter: 'critical',
            statusFilter: 'all',
            categoryFilter: 'all',
          );
        }).toList();

        expect(criticalOnly.length, 3);
        expect(criticalOnly.map((r) => r['id']).toList(), ['R1', 'R2', 'R3']);

        // Low alone
        final lowOnly = multiReports.where((r) {
          return PoliceDashboardScreen.matchesReportFilters(
            rawPriority: r['priority'],
            rawStatus: r['status'],
            rawCategory: r['category'],
            priorityFilter: 'low',
            statusFilter: 'all',
            categoryFilter: 'all',
          );
        }).toList();

        expect(lowOnly.length, 1);
        expect(lowOnly.first['id'], 'R8');
      });

      test('Safely handles missing and null category and status fields', () {
        // When filtering by specific category, null category does not crash and is excluded
        final robberyReports = multiReports.where((r) {
          return PoliceDashboardScreen.matchesCategoryFilter(r['category'], 'Robbery');
        }).toList();
        expect(robberyReports.every((r) => r['category'] == 'Robbery'), isTrue);

        // When filtering by specific status, null status does not crash and is excluded
        final pendingReports = multiReports.where((r) {
          return PoliceDashboardScreen.matchesStatusFilter(r['status'], 'pending');
        }).toList();
        expect(pendingReports.every((r) => r['status'] == 'pending'), isTrue);

        // R9 has null priority, null category, and null status. When all filters are 'all', R9 is included safely.
        final allReports = multiReports.where((r) {
          return PoliceDashboardScreen.matchesReportFilters(
            rawPriority: r['priority'],
            rawStatus: r['status'],
            rawCategory: r['category'],
            priorityFilter: 'all',
            statusFilter: 'all',
            categoryFilter: 'all',
          );
        }).toList();
        expect(allReports.length, 10);
      });
    });

    group('Search Feature & Multi-Filter Integration Tests', () {
      final searchReports = [
        {
          'id': 'RPT-101',
          'docId': 'doc_101',
          'title': 'Bank Robbery in Attock City',
          'description': 'Armed suspects entered local bank branch with weapons.',
          'category': 'Robbery',
          'address': 'Main Bazaar, Attock',
          'status': 'pending',
          'priority': 'CRITICAL',
        },
        {
          'id': 'RPT-102',
          'docId': 'doc_102',
          'title': 'Street Robbery in Rawalpindi',
          'description': 'Motorcycle snatchers took gold chain from pedestrian.',
          'category': 'Robbery',
          'address': 'Saddar, Rawalpindi',
          'status': 'resolved',
          'priority': 'HIGH',
        },
        {
          'id': 'RPT-103',
          'docId': 'doc_103',
          'title': 'Assault outside hospital',
          'description': 'Fight broke out between two groups near emergency gate.',
          'category': 'Assault',
          'address': 'DHQ Hospital, Attock',
          'status': 'pending',
          'priority': 'CRITICAL',
        },
        {
          'id': 'RPT-104',
          'docId': 'doc_104',
          'title': 'Shoplifting at mall',
          'description': 'Stolen cosmetic items recovered from backpack.',
          'category': 'Theft',
          'address': 'Centaurus Mall, Islamabad',
          'status': 'pending',
          'priority': 'MEDIUM',
        },
        {
          'id': 'RPT-105',
          'docId': 'doc_105',
          'title': null,
          'description': null,
          'category': null,
          'address': null,
          'status': null,
          'priority': null,
        },
      ];

      test('1. Search by title (case-insensitive)', () {
        final matches = searchReports.where((r) {
          return PoliceDashboardScreen.matchesSearchQuery(
            report: r,
            docId: r['docId'] ?? '',
            query: 'bank robbery',
          );
        }).toList();

        expect(matches.length, 1);
        expect(matches.first['id'], 'RPT-101');
      });

      test('2. Search by description', () {
        final matches = searchReports.where((r) {
          return PoliceDashboardScreen.matchesSearchQuery(
            report: r,
            docId: r['docId'] ?? '',
            query: 'gold chain',
          );
        }).toList();

        expect(matches.length, 1);
        expect(matches.first['id'], 'RPT-102');
      });

      test('3. Search by category', () {
        final matches = searchReports.where((r) {
          return PoliceDashboardScreen.matchesSearchQuery(
            report: r,
            docId: r['docId'] ?? '',
            query: 'theft',
          );
        }).toList();

        expect(matches.length, 1);
        expect(matches.first['id'], 'RPT-104');
      });

      test('4. Search by location', () {
        // "Attock" matches both RPT-101 and RPT-103
        final attockMatches = searchReports.where((r) {
          return PoliceDashboardScreen.matchesSearchQuery(
            report: r,
            docId: r['docId'] ?? '',
            query: 'attock',
          );
        }).toList();

        expect(attockMatches.length, 2);
        expect(attockMatches.map((r) => r['id']).toList(), ['RPT-101', 'RPT-103']);

        // "Centaurus" matches only RPT-104
        final centaurusMatches = searchReports.where((r) {
          return PoliceDashboardScreen.matchesSearchQuery(
            report: r,
            docId: r['docId'] ?? '',
            query: 'Centaurus',
          );
        }).toList();

        expect(centaurusMatches.length, 1);
        expect(centaurusMatches.first['id'], 'RPT-104');
      });

      test('5. Search by report ID (docId and report id)', () {
        // Search by custom report ID
        final idMatches = searchReports.where((r) {
          return PoliceDashboardScreen.matchesSearchQuery(
            report: r,
            docId: r['docId'] ?? '',
            query: 'RPT-102',
          );
        }).toList();

        expect(idMatches.length, 1);
        expect(idMatches.first['id'], 'RPT-102');

        // Search by Firestore docId
        final docIdMatches = searchReports.where((r) {
          return PoliceDashboardScreen.matchesSearchQuery(
            report: r,
            docId: r['docId'] ?? '',
            query: 'doc_103',
          );
        }).toList();

        expect(docIdMatches.length, 1);
        expect(docIdMatches.first['id'], 'RPT-103');
      });

      test('6. Search combined with Priority + Category + Status filters (Example: Critical + Robbery + "Attock")', () {
        final combinedMatches = searchReports.where((r) {
          return PoliceDashboardScreen.matchesReportFilters(
            rawPriority: r['priority'],
            rawStatus: r['status'],
            rawCategory: r['category'],
            priorityFilter: 'critical',
            statusFilter: 'all',
            categoryFilter: 'Robbery',
            report: r,
            docId: r['docId'],
            searchQuery: 'Attock',
          );
        }).toList();

        // RPT-101 is Critical + Robbery + Attock -> MATCHES
        // RPT-102 is High (not Critical) -> Excluded
        // RPT-103 is Assault (not Robbery) -> Excluded
        expect(combinedMatches.length, 1);
        expect(combinedMatches.first['id'], 'RPT-101');
      });

      test('Empty search query returns all reports permitted by active filters', () {
        final allWithEmptySearch = searchReports.where((r) {
          return PoliceDashboardScreen.matchesReportFilters(
            rawPriority: r['priority'],
            rawStatus: r['status'],
            rawCategory: r['category'],
            priorityFilter: 'all',
            statusFilter: 'all',
            categoryFilter: 'all',
            report: r,
            docId: r['docId'],
            searchQuery: '   ',
          );
        }).toList();

        expect(allWithEmptySearch.length, 5);
      });

      test('Safely handles missing and null fields during search without exceptions', () {
        // Query that won't match null fields doesn't crash
        final noMatches = searchReports.where((r) {
          return PoliceDashboardScreen.matchesSearchQuery(
            report: r,
            docId: r['docId'] ?? '',
            query: 'nonexistent keyword xyz',
          );
        }).toList();

        expect(noMatches, isEmpty);
      });

      testWidgets('Interactive search text entry updates results in real-time', (WidgetTester tester) async {
        String searchQuery = '';
        final controller = TextEditingController();

        await tester.pumpWidget(
          MaterialApp(
            home: StatefulBuilder(
              builder: (context, setState) {
                final filtered = searchReports.where((r) {
                  return PoliceDashboardScreen.matchesSearchQuery(
                    report: r,
                    docId: r['docId'] ?? '',
                    query: searchQuery,
                  );
                }).toList();

                return Scaffold(
                  body: Column(
                    children: [
                      TextField(
                        key: const Key('police_dashboard_search_field'),
                        controller: controller,
                        onChanged: (val) => setState(() => searchQuery = val),
                      ),
                      Expanded(
                        child: ListView.builder(
                          itemCount: filtered.length,
                          itemBuilder: (context, i) {
                            return ListTile(
                              title: Text(filtered[i]['title'] ?? 'No Title'),
                            );
                          },
                        ),
                      ),
                    ],
                  ),
                );
              },
            ),
          ),
        );

        // Initially all reports shown
        expect(find.text('Bank Robbery in Attock City'), findsOneWidget);
        expect(find.text('Street Robbery in Rawalpindi'), findsOneWidget);
        expect(find.text('Assault outside hospital'), findsOneWidget);

        // Enter search "Attock"
        await tester.enterText(find.byKey(const Key('police_dashboard_search_field')), 'Attock');
        await tester.pumpAndSettle();

        expect(find.text('Bank Robbery in Attock City'), findsOneWidget);
        expect(find.text('Assault outside hospital'), findsOneWidget);
        expect(find.text('Street Robbery in Rawalpindi'), findsNothing);

        // Clear search
        await tester.enterText(find.byKey(const Key('police_dashboard_search_field')), '');
        await tester.pumpAndSettle();

        expect(find.text('Street Robbery in Rawalpindi'), findsOneWidget);
      });
    });

    group('Sorting Feature & Multi-Filter Integration Tests', () {
      final sortReports = [
        {
          'id': 'RPT-001',
          'title': 'Armed Bank Robbery',
          'description': 'Gunmen inside bank branch',
          'category': 'Robbery',
          'address': 'Main Market, Attock',
          'status': 'Pending',
          'priority': 'CRITICAL',
          'severityScore': 95,
          'timestamp': DateTime(2026, 10, 1, 10, 0), // 10:00 AM
        },
        {
          'id': 'RPT-002',
          'title': 'Street Snatching',
          'description': 'Phone snatched by two riders',
          'category': 'Snatching',
          'address': 'Saddar, Rawalpindi',
          'status': 'Pending',
          'priority': 'HIGH',
          'severityScore': 75,
          'timestamp': DateTime(2026, 10, 1, 14, 0), // 2:00 PM (Newest)
        },
        {
          'id': 'RPT-003',
          'title': 'Bicycle Theft',
          'description': 'Bicycle taken from outside shop',
          'category': 'Theft',
          'address': 'Attock Cantt',
          'status': 'In Progress',
          'priority': 'LOW',
          'severityScore': 25,
          'timestamp': DateTime(2026, 10, 1, 8, 0), // 8:00 AM
        },
        {
          'id': 'RPT-004',
          'title': 'Shoplifting Incident',
          'description': 'Customer walked out without paying',
          'category': 'Theft',
          'address': 'Islamabad F-10',
          'status': 'Resolved',
          'priority': 'MEDIUM',
          'severityScore': 50,
          'timestamp': DateTime(2026, 9, 30, 12, 0), // Sept 30 (Oldest)
        },
        {
          'id': 'RPT-005',
          'title': 'Suspicious Noise Report',
          'description': 'Citizen reported unusual sound at night',
          'category': 'Other',
          'address': 'Attock City',
          'status': 'Pending',
          'priority': null, // Not Analyzed
          'severityScore': null,
          'timestamp': DateTime(2026, 10, 1, 9, 0),
        },
        {
          'id': 'RPT-006',
          'title': 'Critical Hostage Threat',
          'description': 'Active shooter and hostage crisis',
          'category': 'Robbery',
          'address': 'Attock Downtown',
          'status': 'Pending',
          'priority': 'CRITICAL',
          'severityScore': 98,
          'timestamp': DateTime(2026, 10, 1, 11, 0),
        },
        {
          'id': 'RPT-007',
          'title': 'Legacy Unanalyzed Missing Timestamp',
          'description': 'Old record without date or priority',
          'category': 'Other',
          'address': 'Lahore',
          'status': 'Pending',
          'priority': 'not_analyzed',
          'severityScore': null,
          'timestamp': null, // Missing date
        },
      ];

      test('1. Sort by Priority: Critical → High → Medium → Low → Not Analyzed', () {
        final list = List<Map<String, dynamic>>.from(sortReports);
        list.sort((a, b) => PoliceDashboardScreen.compareReports(
              a: a,
              b: b,
              sortOption: PoliceDashboardScreen.sortPriority,
            ));

        final ids = list.map((r) => r['id']).toList();
        expect(ids, [
          'RPT-006', // CRITICAL (score 98)
          'RPT-001', // CRITICAL (score 95)
          'RPT-002', // HIGH (score 75)
          'RPT-004', // MEDIUM (score 50)
          'RPT-003', // LOW (score 25)
          'RPT-005', // Not Analyzed (has timestamp)
          'RPT-007', // Not Analyzed (missing timestamp)
        ]);
      });

      test('2. Sort by Severity Score: Highest → Lowest', () {
        final list = List<Map<String, dynamic>>.from(sortReports);
        list.sort((a, b) => PoliceDashboardScreen.compareReports(
              a: a,
              b: b,
              sortOption: PoliceDashboardScreen.sortSeverity,
            ));

        final ids = list.map((r) => r['id']).toList();
        expect(ids, [
          'RPT-006', // 98
          'RPT-001', // 95
          'RPT-002', // 75
          'RPT-004', // 50
          'RPT-003', // 25
          'RPT-005', // null score (tiebreaker timestamp 9:00 AM)
          'RPT-007', // null score (null timestamp)
        ]);
      });

      test('3. Sort by Newest First', () {
        final list = List<Map<String, dynamic>>.from(sortReports);
        list.sort((a, b) => PoliceDashboardScreen.compareReports(
              a: a,
              b: b,
              sortOption: PoliceDashboardScreen.sortNewest,
            ));

        final ids = list.map((r) => r['id']).toList();
        expect(ids, [
          'RPT-002', // Oct 1, 14:00 (Newest)
          'RPT-006', // Oct 1, 11:00
          'RPT-001', // Oct 1, 10:00
          'RPT-005', // Oct 1, 09:00
          'RPT-003', // Oct 1, 08:00
          'RPT-004', // Sept 30, 12:00
          'RPT-007', // null timestamp placed at bottom safely
        ]);
      });

      test('4. Sort by Oldest First', () {
        final list = List<Map<String, dynamic>>.from(sortReports);
        list.sort((a, b) => PoliceDashboardScreen.compareReports(
              a: a,
              b: b,
              sortOption: PoliceDashboardScreen.sortOldest,
            ));

        final ids = list.map((r) => r['id']).toList();
        expect(ids, [
          'RPT-004', // Sept 30, 12:00 (Oldest)
          'RPT-003', // Oct 1, 08:00
          'RPT-005', // Oct 1, 09:00
          'RPT-001', // Oct 1, 10:00
          'RPT-006', // Oct 1, 11:00
          'RPT-002', // Oct 1, 14:00 (Newest)
          'RPT-007', // null timestamp placed at bottom safely
        ]);
      });

      test('5. Sorting combined with Search, Priority, Category, and Status filters', () {
        // Multi-filter: Priority = Critical, Category = Robbery, Status = Pending, Search = "Attock"
        final filtered = sortReports.where((r) {
          return PoliceDashboardScreen.matchesReportFilters(
            rawPriority: r['priority'],
            rawStatus: r['status'],
            rawCategory: r['category'],
            priorityFilter: 'critical',
            statusFilter: 'pending',
            categoryFilter: 'robbery',
            report: r,
            docId: r['id']?.toString() ?? '',
            searchQuery: 'Attock',
          );
        }).toList();

        // Matching reports are RPT-001 (score 95, 10:00 AM) and RPT-006 (score 98, 11:00 AM)
        expect(filtered.length, 2);

        // Sub-test A: Sort by Severity Score: Highest -> Lowest
        final sortedByScore = List<Map<String, dynamic>>.from(filtered);
        sortedByScore.sort((a, b) => PoliceDashboardScreen.compareReports(
              a: a,
              b: b,
              sortOption: PoliceDashboardScreen.sortSeverity,
            ));
        expect(sortedByScore.first['id'], 'RPT-006'); // 98
        expect(sortedByScore.last['id'], 'RPT-001');  // 95

        // Sub-test B: Sort by Newest First
        final sortedByNewest = List<Map<String, dynamic>>.from(filtered);
        sortedByNewest.sort((a, b) => PoliceDashboardScreen.compareReports(
              a: a,
              b: b,
              sortOption: PoliceDashboardScreen.sortNewest,
            ));
        expect(sortedByNewest.first['id'], 'RPT-006'); // 11:00 AM
        expect(sortedByNewest.last['id'], 'RPT-001');  // 10:00 AM

        // Sub-test C: Sort by Oldest First
        final sortedByOldest = List<Map<String, dynamic>>.from(filtered);
        sortedByOldest.sort((a, b) => PoliceDashboardScreen.compareReports(
              a: a,
              b: b,
              sortOption: PoliceDashboardScreen.sortOldest,
            ));
        expect(sortedByOldest.first['id'], 'RPT-001'); // 10:00 AM
        expect(sortedByOldest.last['id'], 'RPT-006');  // 11:00 AM
      });

      test('6. Missing, null, and legacy string date/score values handled safely without errors', () {
        final legacyReportA = {
          'id': 'LEG-01',
          'priority': null,
          'severityScore': null,
          'timestamp': null,
        };
        final legacyReportB = {
          'id': 'LEG-02',
          'priority': 'high',
          'severityScore': '88', // String score
          'timestamp': '2026-10-01T15:00:00Z', // ISO String date
        };

        expect(
          () => PoliceDashboardScreen.compareReports(
            a: legacyReportA,
            b: legacyReportB,
            sortOption: PoliceDashboardScreen.sortPriority,
          ),
          returnsNormally,
        );
        expect(
          () => PoliceDashboardScreen.compareReports(
            a: legacyReportA,
            b: legacyReportB,
            sortOption: PoliceDashboardScreen.sortSeverity,
          ),
          returnsNormally,
        );
        expect(
          () => PoliceDashboardScreen.compareReports(
            a: legacyReportA,
            b: legacyReportB,
            sortOption: PoliceDashboardScreen.sortNewest,
          ),
          returnsNormally,
        );
        expect(
          () => PoliceDashboardScreen.compareReports(
            a: legacyReportA,
            b: legacyReportB,
            sortOption: PoliceDashboardScreen.sortOldest,
          ),
          returnsNormally,
        );

        // Verify string severity parsed and prioritized over null
        final cmpScore = PoliceDashboardScreen.compareReports(
          a: legacyReportA,
          b: legacyReportB,
          sortOption: PoliceDashboardScreen.sortSeverity,
        );
        expect(cmpScore > 0, isTrue); // legacyReportA (null) comes after legacyReportB (88)
      });

      testWidgets('7. Interactive Sort Dropdown updates report order on UI', (WidgetTester tester) async {
        String selectedSort = PoliceDashboardScreen.sortPriority;

        await tester.pumpWidget(
          MaterialApp(
            home: StatefulBuilder(
              builder: (context, setState) {
                final displayReports = List<Map<String, dynamic>>.from(sortReports);
                displayReports.sort((a, b) => PoliceDashboardScreen.compareReports(
                      a: a,
                      b: b,
                      sortOption: selectedSort,
                    ));

                return Scaffold(
                  body: Column(
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: DropdownButton<String>(
                              key: const Key('police_dashboard_sort_dropdown'),
                              value: selectedSort,
                              isExpanded: true,
                              items: PoliceDashboardScreen.sortOptions.map((opt) {
                                return DropdownMenuItem<String>(
                                  value: opt,
                                  child: Text(opt, overflow: TextOverflow.ellipsis),
                                );
                              }).toList(),
                              onChanged: (newSort) {
                                if (newSort != null) {
                                  setState(() => selectedSort = newSort);
                                }
                              },
                            ),
                          ),
                        ],
                      ),
                      Expanded(
                        child: ListView.builder(
                          itemCount: displayReports.length,
                          itemBuilder: (context, i) {
                            return ListTile(
                              key: Key('report_item_${displayReports[i]['id']}'),
                              title: Text(displayReports[i]['title'] ?? ''),
                            );
                          },
                        ),
                      ),
                    ],
                  ),
                );
              },
            ),
          ),
        );

        // Initially sorted by Priority: Critical Hostage Threat (RPT-006) should be first
        expect(find.byKey(const Key('police_dashboard_sort_dropdown')), findsOneWidget);
        expect(find.text(PoliceDashboardScreen.sortPriority), findsOneWidget);

        // Switch to "Oldest First"
        await tester.tap(find.byKey(const Key('police_dashboard_sort_dropdown')));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Oldest First').last);
        await tester.pumpAndSettle();

        // Shoplifting Incident (Sept 30 - RPT-004) is oldest
        expect(find.text('Oldest First'), findsOneWidget);

        // Switch to "Newest First"
        await tester.tap(find.byKey(const Key('police_dashboard_sort_dropdown')));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Newest First').last);
        await tester.pumpAndSettle();

        // Street Snatching (Oct 1 2:00 PM - RPT-002) is newest
        expect(find.text('Newest First'), findsOneWidget);
      });
    });

    group('Police Dashboard Report Details & AI Analysis Section Tests', () {
      testWidgets('1. Report with complete AI analysis displays all AI fields & danger indicators', (WidgetTester tester) async {
        final completeReport = {
          'category': 'Armed Robbery',
          'description': 'Gunmen holding employees inside branch.',
          'address': 'Commercial Market, Satellite Town, Rawalpindi',
          'userEmail': 'officer.khan@safetyguardian.pk',
          'isAnonymous': false,
          'priority': 'CRITICAL',
          'severityScore': 96,
          'reason': 'Active armed conflict threatening human lives in bank.',
          'detectedFactors': ['Armed robbery', 'Active firearms', 'Immediate life threat'],
          'immediateDanger': true,
          'violenceDetected': true,
          'weaponDetected': true,
          'injuryDetected': false,
          'threatDetected': true,
        };

        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: SingleChildScrollView(
                child: PoliceReportCard(
                  report: completeReport,
                  docId: 'rep_details_001',
                ),
              ),
            ),
          ),
        );

        // Verify summary row & category
        expect(find.text('Armed Robbery'), findsOneWidget);
        expect(find.text('Priority: CRITICAL'), findsOneWidget);
        expect(find.text('Severity Score: 96'), findsOneWidget);

        // Open report details
        await tester.tap(find.text('Armed Robbery'));
        await tester.pumpAndSettle();

        // Verify clearly separated AI Analysis section
        expect(find.byKey(const Key('report_ai_analysis_section')), findsOneWidget);
        expect(find.text('AI Analysis'), findsOneWidget);
        expect(find.text('Reason: Active armed conflict threatening human lives in bank.'), findsOneWidget);
        expect(find.text('Detected Factors:'), findsOneWidget);
        expect(find.text('Armed robbery'), findsOneWidget);
        expect(find.text('Active firearms'), findsOneWidget);
        expect(find.text('Immediate life threat'), findsOneWidget);

        // Verify danger indicators
        expect(find.text('Immediate Danger: '), findsOneWidget);
        expect(find.text('Violence Detected: '), findsOneWidget);
        expect(find.text('Weapon Detected: '), findsOneWidget);
        expect(find.text('Injury Detected: '), findsOneWidget);
        expect(find.text('Threat Detected: '), findsOneWidget);

        // Verify boolean values displayed
        expect(find.text('YES'), findsNWidgets(4)); // immediateDanger, violenceDetected, weaponDetected, threatDetected
        expect(find.text('No'), findsOneWidget);     // injuryDetected
      });

      testWidgets('2. Old report without AI fields displays "Not Analyzed" safely', (WidgetTester tester) async {
        final oldReport = {
          'category': 'Noise Complaint',
          'description': 'Loud generators running during quiet hours.',
          'address': 'Sector I-8/2, Islamabad',
          'userEmail': 'resident@islamabad.pk',
          'isAnonymous': true,
          // All AI fields omitted
        };

        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: SingleChildScrollView(
                child: PoliceReportCard(
                  report: oldReport,
                  docId: 'old_rep_002',
                ),
              ),
            ),
          ),
        );

        // Open report details
        await tester.tap(find.text('Noise Complaint'));
        await tester.pumpAndSettle();

        // Verify AI Analysis section exists and indicates Not Analyzed
        expect(find.byKey(const Key('report_ai_analysis_section')), findsOneWidget);
        expect(find.text('AI Analysis: Not Analyzed'), findsOneWidget);
        expect(
          find.text('AI analysis is not available for this report (submitted prior to AI integration or unanalyzed).'),
          findsOneWidget,
        );
        expect(find.text('NOT ANALYZED'), findsNWidgets(2)); // Card title badge + AI section badge

        // Basic report info remains intact
        expect(find.text('Loud generators running during quiet hours.'), findsOneWidget);
        expect(find.text('Sector I-8/2, Islamabad'), findsOneWidget);
      });

      testWidgets('3. HIGH and CRITICAL priority displays use distinct visual indicators', (WidgetTester tester) async {
        final highReport = {
          'category': 'Physical Assault',
          'description': 'Suspect assaulted shop owner.',
          'address': 'F-7 Jinnah Super, Islamabad',
          'priority': 'HIGH',
          'severityScore': 82,
          'reason': 'Physical assault with threat of repeated violence.',
          'detectedFactors': ['Assault', 'Violence detected'],
          'immediateDanger': true,
          'violenceDetected': true,
          'weaponDetected': false,
          'injuryDetected': true,
          'threatDetected': true,
        };

        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: SingleChildScrollView(
                child: PoliceReportCard(
                  report: highReport,
                  docId: 'high_rep_003',
                ),
              ),
            ),
          ),
        );

        expect(find.text('HIGH'), findsOneWidget);
        expect(
          PoliceReportCard.getPriorityColor('HIGH'),
          const Color(0xFFDC2626),
        );

        await tester.tap(find.text('Physical Assault'));
        await tester.pumpAndSettle();

        expect(find.text('Priority:'), findsOneWidget);
        expect(find.text('HIGH'), findsNWidgets(3)); // Card title badge + AI section header badge + Priority text
        expect(find.text('82 / 100'), findsOneWidget);
      });

      testWidgets('4. Missing and null AI fields are handled safely with fallbacks', (WidgetTester tester) async {
        final partialReport = {
          'category': 'Suspicious Activity',
          'description': 'Suspicious van parked outside school.',
          'address': 'G-9 Markaz, Islamabad',
          'priority': 'MEDIUM',
          // severityScore, reason, detectedFactors are null
          'severityScore': null,
          'reason': null,
          'detectedFactors': null,
          'immediateDanger': null,
          'violenceDetected': false,
          'weaponDetected': null,
          'injuryDetected': null,
          'threatDetected': null,
        };

        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: SingleChildScrollView(
                child: PoliceReportCard(
                  report: partialReport,
                  docId: 'partial_rep_004',
                ),
              ),
            ),
          ),
        );

        await tester.tap(find.text('Suspicious Activity'));
        await tester.pumpAndSettle();

        // Verify fallback representations
        expect(find.text('Severity Score:'), findsOneWidget);
        expect(find.text('Reason: Not Analyzed'), findsOneWidget);
        expect(find.text('None detected'), findsOneWidget);

        // Verify danger indicators with null values display 'Not Analyzed'
        expect(find.text('Not Analyzed'), findsNWidgets(5)); // Severity + 4 null boolean indicators
        expect(find.text('No'), findsOneWidget);             // violenceDetected = false
      });

      testWidgets('5. Opening multiple reports simultaneously renders independent details safely', (WidgetTester tester) async {
        final multiReports = [
          {
            'id': 'MULTI-01',
            'category': 'Robbery',
            'description': 'Robbery in Sector F-6.',
            'address': 'Islamabad',
            'priority': 'CRITICAL',
            'severityScore': 95,
            'reason': 'Armed robbers on scene.',
            'detectedFactors': ['Armed robbery'],
            'immediateDanger': true,
          },
          {
            'id': 'MULTI-02',
            'category': 'Cyber Fraud',
            'description': 'ATM skimming report.',
            'address': 'Rawalpindi',
            // Missing AI fields
          },
          {
            'id': 'MULTI-03',
            'category': 'Assault',
            'description': 'Street brawl outside cafe.',
            'address': 'Lahore',
            'priority': 'HIGH',
            'severityScore': 78,
            'reason': 'Fight in public place.',
            'detectedFactors': ['Assault', 'Violence'],
            'immediateDanger': false,
            'violenceDetected': true,
          },
        ];

        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: SingleChildScrollView(
                child: Column(
                  children: multiReports.map((r) {
                    return PoliceReportCard(
                      report: r,
                      docId: r['id'] as String,
                    );
                  }).toList(),
                ),
              ),
            ),
          ),
        );

        // Open Report 1 (Robbery)
        await tester.tap(find.text('Robbery'));
        await tester.pumpAndSettle();
        expect(find.text('Reason: Armed robbers on scene.'), findsOneWidget);

        // Open Report 2 (Cyber Fraud - Old / Unanalyzed)
        await tester.ensureVisible(find.text('Cyber Fraud'));
        await tester.tap(find.text('Cyber Fraud'));
        await tester.pumpAndSettle();
        expect(find.text('AI Analysis: Not Analyzed'), findsOneWidget);

        // Open Report 3 (Assault)
        await tester.ensureVisible(find.text('Assault'));
        await tester.tap(find.text('Assault'));
        await tester.pumpAndSettle();
        expect(find.text('Reason: Fight in public place.'), findsOneWidget);

        // Verify all 3 remain open and co-exist properly
        expect(find.text('Reason: Armed robbers on scene.'), findsOneWidget);
        expect(find.text('AI Analysis: Not Analyzed'), findsOneWidget);
        expect(find.text('Reason: Fight in public place.'), findsOneWidget);
      });
    });
  });
}


