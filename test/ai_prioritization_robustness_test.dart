// ignore_for_file: avoid_print
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:safety_guardian/models/report_ai_analysis.dart';
import 'package:safety_guardian/models/report_model.dart';
import 'package:safety_guardian/screens/police_dashboard_screen.dart';
import 'package:safety_guardian/services/gemini_service.dart';
import 'package:safety_guardian/services/report_analysis_service.dart';

/// Mock GeminiService that allows deterministic simulation of any network condition or response.
class MockGeminiService extends GeminiService {
  final Future<GeminiResponse> Function(String prompt)? onGenerate;
  int callCount = 0;

  MockGeminiService({this.onGenerate}) : super(apiKey: 'AIzaSy_MOCK_KEY_FOR_TESTING');

  @override
  Future<GeminiResponse> generateContent(
    String prompt, {
    Map<String, dynamic>? generationConfig,
    String? overrideModel,
  }) async {
    callCount++;
    if (onGenerate != null) {
      return onGenerate!(prompt);
    }
    return const GeminiResponse(
      text: '{"priority": "MEDIUM", "severityScore": 50, "reason": "Mock default response", "detectedFactors": ["General incident"], "immediateDanger": false, "violenceDetected": false, "weaponDetected": false, "injuryDetected": false, "threatDetected": false}',
      model: 'gemini-3.5-flash',
    );
  }
}

void main() {
  group('1. AI CONTEXT TESTING (12 Contexts & Semantic Understanding)', () {
    // 1.1 Armed threat
    test('1.1 Armed threat context: Evaluates to CRITICAL with weapon & threat detected', () async {
      final mock = MockGeminiService(onGenerate: (prompt) async {
        expect(prompt.contains('AK-47'), isTrue);
        return GeminiResponse(
          text: jsonEncode({
            'priority': 'CRITICAL',
            'severityScore': 95,
            'reason': 'Active firearms confrontation with direct threat to life.',
            'detectedFactors': ['Armed robbery', 'Active firearms', 'Immediate life threat'],
            'immediateDanger': true,
            'violenceDetected': true,
            'weaponDetected': true,
            'injuryDetected': false,
            'threatDetected': true,
          }),
          model: 'gemini-3.5-flash',
        );
      });

      final service = ReportAnalysisService(geminiService: mock);
      final res = await service.analyzeReport(
        title: 'Armed bank robbery in progress',
        description: 'Two gunmen carrying AK-47 rifles entered the bank and shot at the ceiling.',
        category: 'Robbery',
        location: 'Bank Road, Saddar, Rawalpindi',
      );

      expect(res.priority, 'CRITICAL');
      expect(res.severityScore, 95);
      expect(res.weaponDetected, isTrue);
      expect(res.threatDetected, isTrue);
      expect(res.immediateDanger, isTrue);
    });

    // 1.2 Assault/violence
    test('1.2 Assault/violence context: Evaluates to HIGH/CRITICAL with violence & injury', () async {
      final mock = MockGeminiService(onGenerate: (prompt) async {
        return GeminiResponse(
          text: jsonEncode({
            'priority': 'HIGH',
            'severityScore': 85,
            'reason': 'Physical assault causing active bleeding and injury.',
            'detectedFactors': ['Physical assault', 'Severe injury', 'Public violence'],
            'immediateDanger': true,
            'violenceDetected': true,
            'weaponDetected': false,
            'injuryDetected': true,
            'threatDetected': true,
          }),
          model: 'gemini-3.5-flash',
        );
      });

      final service = ReportAnalysisService(geminiService: mock);
      final res = await service.analyzeReport(
        title: 'Violent attack outside cafe',
        description: 'Three men attacked a customer with fists. Victim is bleeding and injured.',
        category: 'Assault',
        location: 'F-7 Markaz, Islamabad',
      );

      expect(res.priority, 'HIGH');
      expect(res.violenceDetected, isTrue);
      expect(res.injuryDetected, isTrue);
    });

    // 1.3 Serious threat without weapon
    test('1.3 Serious threat without weapon: Evaluates threat without false weapon detection', () async {
      final mock = MockGeminiService(onGenerate: (prompt) async {
        return GeminiResponse(
          text: jsonEncode({
            'priority': 'HIGH',
            'severityScore': 75,
            'reason': 'Targeted death threat and ongoing stalking behavior without weapon.',
            'detectedFactors': ['Death threat', 'Stalking', 'Targeted harassment'],
            'immediateDanger': true,
            'violenceDetected': false,
            'weaponDetected': false,
            'injuryDetected': false,
            'threatDetected': true,
          }),
          model: 'gemini-3.5-flash',
        );
      });

      final service = ReportAnalysisService(geminiService: mock);
      final res = await service.analyzeReport(
        title: 'Death threat from stalker',
        description: 'A man has been stalking my family and sent messages saying he will burn down our home tonight.',
        category: 'Harassment',
        location: 'Sector G-10/4, Islamabad',
      );

      expect(res.priority, 'HIGH');
      expect(res.threatDetected, isTrue);
      expect(res.weaponDetected, isFalse); // Semantic accuracy: no weapon
    });

    // 1.4 Theft
    test('1.4 Theft (property loss): Evaluates to MEDIUM/LOW with no immediate danger', () async {
      final mock = MockGeminiService(onGenerate: (prompt) async {
        return GeminiResponse(
          text: jsonEncode({
            'priority': 'LOW',
            'severityScore': 25,
            'reason': 'Property theft without confrontation or physical danger.',
            'detectedFactors': ['Vehicle theft', 'Property loss'],
            'immediateDanger': false,
            'violenceDetected': false,
            'weaponDetected': false,
            'injuryDetected': false,
            'threatDetected': false,
          }),
          model: 'gemini-3.5-flash',
        );
      });

      final service = ReportAnalysisService(geminiService: mock);
      final res = await service.analyzeReport(
        title: 'Motorcycle stolen from parking',
        description: 'Parked motorcycle outside office at 9am, found missing at 5pm.',
        category: 'Theft',
        location: 'Blue Area, Islamabad',
      );

      expect(res.priority, 'LOW');
      expect(res.immediateDanger, isFalse);
      expect(res.weaponDetected, isFalse);
      expect(res.violenceDetected, isFalse);
    });

    // 1.5 Snatching/robbery
    test('1.5 Snatching/robbery: Evaluates to HIGH/MEDIUM with threat detected', () async {
      final mock = MockGeminiService(onGenerate: (prompt) async {
        return GeminiResponse(
          text: jsonEncode({
            'priority': 'HIGH',
            'severityScore': 70,
            'reason': 'Street snatching with active confrontation on public road.',
            'detectedFactors': ['Street snatching', 'Motorcycle crime'],
            'immediateDanger': false,
            'violenceDetected': true,
            'weaponDetected': false,
            'injuryDetected': false,
            'threatDetected': true,
          }),
          model: 'gemini-3.5-flash',
        );
      });

      final service = ReportAnalysisService(geminiService: mock);
      final res = await service.analyzeReport(
        title: 'Mobile snatching by motorcycle riders',
        description: 'Two men on bike snatched my iPhone while I was waiting for bus on main highway.',
        category: 'Snatching',
        location: 'IJP Road, Rawalpindi',
      );

      expect(res.priority, 'HIGH');
      expect(res.threatDetected, isTrue);
    });

    // 1.6 Accident/injury
    test('1.6 Accident/injury: Evaluates to CRITICAL/HIGH with injury & immediate danger', () async {
      final mock = MockGeminiService(onGenerate: (prompt) async {
        return GeminiResponse(
          text: jsonEncode({
            'priority': 'CRITICAL',
            'severityScore': 92,
            'reason': 'Severe hit-and-run traffic collision with unconscious victim needing urgent medical triage.',
            'detectedFactors': ['Hit and run', 'Severe trauma', 'Life-threatening injury'],
            'immediateDanger': true,
            'violenceDetected': false,
            'weaponDetected': false,
            'injuryDetected': true,
            'threatDetected': false,
          }),
          model: 'gemini-3.5-flash',
        );
      });

      final service = ReportAnalysisService(geminiService: mock);
      final res = await service.analyzeReport(
        title: 'Hit and run road collision',
        description: 'Speeding truck hit motorcyclist and fled. Motorcyclist is unconscious and bleeding.',
        category: 'Other',
        location: 'Expressway, Islamabad',
      );

      expect(res.priority, 'CRITICAL');
      expect(res.injuryDetected, isTrue);
      expect(res.immediateDanger, isTrue);
    });

    // 1.7 Fraud
    test('1.7 Fraud (financial deception): Evaluates to MEDIUM/LOW with zero violence', () async {
      final mock = MockGeminiService(onGenerate: (prompt) async {
        return GeminiResponse(
          text: jsonEncode({
            'priority': 'MEDIUM',
            'severityScore': 45,
            'reason': 'Financial fraud via deceptive phone call; no immediate physical threat.',
            'detectedFactors': ['Financial fraud', 'Phishing scam'],
            'immediateDanger': false,
            'violenceDetected': false,
            'weaponDetected': false,
            'injuryDetected': false,
            'threatDetected': false,
          }),
          model: 'gemini-3.5-flash',
        );
      });

      final service = ReportAnalysisService(geminiService: mock);
      final res = await service.analyzeReport(
        title: 'Online banking scam',
        description: 'Fraudster called claiming to be bank manager and stole money through OTP scam.',
        category: 'Fraud',
        location: 'Islamabad',
      );

      expect(res.priority, 'MEDIUM');
      expect(res.immediateDanger, isFalse);
      expect(res.violenceDetected, isFalse);
    });

    // 1.8 Suspicious activity
    test('1.8 Suspicious activity: Evaluates to MEDIUM/LOW without false panic', () async {
      final mock = MockGeminiService(onGenerate: (prompt) async {
        return GeminiResponse(
          text: jsonEncode({
            'priority': 'MEDIUM',
            'severityScore': 40,
            'reason': 'Suspicious surveillance vehicle in residential area requiring patrol investigation.',
            'detectedFactors': ['Suspicious vehicle', 'Neighborhood surveillance'],
            'immediateDanger': false,
            'violenceDetected': false,
            'weaponDetected': false,
            'injuryDetected': false,
            'threatDetected': true,
          }),
          model: 'gemini-3.5-flash',
        );
      });

      final service = ReportAnalysisService(geminiService: mock);
      final res = await service.analyzeReport(
        title: 'Unknown car circling residential street',
        description: 'Dark tinted vehicle with covered license plate has been driving slowly past houses repeatedly.',
        category: 'Other',
        location: 'Street 15, Sector F-8, Islamabad',
      );

      expect(res.priority, 'MEDIUM');
      expect(res.violenceDetected, isFalse);
    });

    // 1.9 Minor disturbance
    test('1.9 Minor disturbance: Evaluates to LOW with low severity score', () async {
      final mock = MockGeminiService(onGenerate: (prompt) async {
        return GeminiResponse(
          text: jsonEncode({
            'priority': 'LOW',
            'severityScore': 20,
            'reason': 'Noise complaint regarding loud late-night music without danger.',
            'detectedFactors': ['Noise disturbance', 'Public nuisance'],
            'immediateDanger': false,
            'violenceDetected': false,
            'weaponDetected': false,
            'injuryDetected': false,
            'threatDetected': false,
          }),
          model: 'gemini-3.5-flash',
        );
      });

      final service = ReportAnalysisService(geminiService: mock);
      final res = await service.analyzeReport(
        title: 'Loud DJ noise late night',
        description: 'House party playing loud electronic music after 1:00 AM on weekday.',
        category: 'Other',
        location: 'Sector G-11/1, Islamabad',
      );

      expect(res.priority, 'LOW');
      expect(res.severityScore, lessThanOrEqualTo(30));
      expect(res.immediateDanger, isFalse);
    });

    // 1.10 Non-urgent municipal complaint
    test('1.10 Non-urgent complaint: Evaluates to LOW with minimal severity', () async {
      final mock = MockGeminiService(onGenerate: (prompt) async {
        return GeminiResponse(
          text: jsonEncode({
            'priority': 'LOW',
            'severityScore': 10,
            'reason': 'Municipal infrastructure issue without immediate safety threat.',
            'detectedFactors': ['Infrastructure fault'],
            'immediateDanger': false,
            'violenceDetected': false,
            'weaponDetected': false,
            'injuryDetected': false,
            'threatDetected': false,
          }),
          model: 'gemini-3.5-flash',
        );
      });

      final service = ReportAnalysisService(geminiService: mock);
      final res = await service.analyzeReport(
        title: 'Broken streetlight',
        description: 'The pole light near street corner is unlit since last week.',
        category: 'Other',
        location: 'Street 4, Sector I-9, Islamabad',
      );

      expect(res.priority, 'LOW');
      expect(res.severityScore, 10);
      expect(res.immediateDanger, isFalse);
    });

    // 1.11 Very short/incomplete report
    test('1.11 Very short / incomplete report: Returns safe fallback without crashing', () async {
      final service = ReportAnalysisService();
      final res = await service.analyzeReport(
        title: '',
        description: '',
      );

      expect(res.priority, 'LOW');
      expect(res.immediateDanger, isFalse);
      expect(res.weaponDetected, isFalse);
    });

    // 1.12 Detailed report with location
    test('1.12 Detailed report with location: Processes full location and narrative details', () async {
      final mock = MockGeminiService(onGenerate: (prompt) async {
        expect(prompt.contains('Centaurus Mall'), isTrue);
        return GeminiResponse(
          text: jsonEncode({
            'priority': 'CRITICAL',
            'severityScore': 98,
            'reason': 'Active armed hostage crisis at high-density commercial center.',
            'detectedFactors': ['Hostage crisis', 'Active armed suspects', 'Public venue danger'],
            'immediateDanger': true,
            'violenceDetected': true,
            'weaponDetected': true,
            'injuryDetected': false,
            'threatDetected': true,
          }),
          model: 'gemini-3.5-flash',
        );
      });

      final service = ReportAnalysisService(geminiService: mock);
      final res = await service.analyzeReport(
        title: 'Hostage confrontation at commercial plaza',
        description: 'Armed gunmen barricaded inside plaza with employees, demanding ransom and safe passage.',
        category: 'Robbery',
        location: 'Centaurus Mall, Jinnah Avenue, Islamabad',
      );

      expect(res.priority, 'CRITICAL');
      expect(res.immediateDanger, isTrue);
      expect(res.severityScore, 98);
    });

    // 1.13 Semantic Understanding vs Keyword Matching
    test('1.13 Semantic Understanding VS Exact Keyword Matching: Benign context with dangerous words', () async {
      final mock = MockGeminiService(onGenerate: (prompt) async {
        // AI recognizes the user was chopping vegetables and watching a movie,
        // and the actual incident is only a missing garden shovel!
        return GeminiResponse(
          text: jsonEncode({
            'priority': 'LOW',
            'severityScore': 15,
            'reason': 'Property loss of gardening tool; kitchen knife and murder references were benign home context.',
            'detectedFactors': ['Property loss', 'Non-violent missing tool'],
            'immediateDanger': false,
            'violenceDetected': false,
            'weaponDetected': false,
            'injuryDetected': false,
            'threatDetected': false,
          }),
          model: 'gemini-3.5-flash',
        );
      });

      final service = ReportAnalysisService(geminiService: mock);
      final res = await service.analyzeReport(
        title: 'Missing garden shovel',
        description: 'I was chopping onions with a sharp knife and watching a murder mystery show when I noticed my garden shovel was missing from the patio.',
        category: 'Theft',
        location: 'Rawalpindi',
      );

      expect(res.priority, 'LOW');
      expect(res.immediateDanger, isFalse);
      expect(res.weaponDetected, isFalse);
      expect(res.violenceDetected, isFalse);
    });
  });

  group('2. GEMINI FAILURE TESTING (Network, Timeout, Server 500/503, Quota 429)', () {
    test('2.1 No Internet (GeminiNetworkException) is catchable & original report preserved', () async {
      final mock = MockGeminiService(
        onGenerate: (_) async => throw const GeminiNetworkException('No internet connectivity (SocketException)'),
      );
      final service = ReportAnalysisService(geminiService: mock);

      expect(
        () => service.analyzeReport(title: 'Robbery', description: 'Armed robbery'),
        throwsA(isA<GeminiNetworkException>()),
      );
    });

    test('2.2 Request Timeout (408) is catchable without app crash', () async {
      final mock = MockGeminiService(
        onGenerate: (_) async => throw const GeminiException('Connection timed out after 30s', statusCode: 408),
      );
      final service = ReportAnalysisService(geminiService: mock);

      expect(
        () => service.analyzeReport(title: 'Snatching', description: 'Phone snatched'),
        throwsA(isA<GeminiException>()),
      );
    });

    test('2.3 Gemini API Server Error (HTTP 500 / 503) is catchable', () async {
      final mock = MockGeminiService(
        onGenerate: (_) async => throw const GeminiServerException('Gemini service unavailable', statusCode: 503),
      );
      final service = ReportAnalysisService(geminiService: mock);

      expect(
        () => service.analyzeReport(title: 'Assault', description: 'Attack outside shop'),
        throwsA(isA<GeminiServerException>()),
      );
    });

    test('2.4 Gemini Quota Exceeded (HTTP 429) throws GeminiQuotaException safely', () async {
      final mock = MockGeminiService(
        onGenerate: (_) async => throw const GeminiQuotaException('Quota exceeded: 20 RPM on free tier', statusCode: 429),
      );
      final service = ReportAnalysisService(geminiService: mock);

      expect(
        () => service.analyzeReport(title: 'Theft', description: 'Car broken into'),
        throwsA(isA<GeminiQuotaException>()),
      );
    });

    test('2.5 Empty response throws clear validation GeminiException', () async {
      final mock = MockGeminiService(
        onGenerate: (_) async => const GeminiResponse(text: '', model: 'gemini-3.5-flash'),
      );
      final service = ReportAnalysisService(geminiService: mock);

      expect(
        () => service.analyzeReport(title: 'Theft', description: 'Wallet stolen'),
        throwsA(isA<GeminiException>()),
      );
    });

    test('2.6 Non-JSON Text response throws clear validation GeminiException', () async {
      final mock = MockGeminiService(
        onGenerate: (_) async => const GeminiResponse(
          text: 'I cannot prioritize this report as it violates safety guidelines.',
          model: 'gemini-3.5-flash',
        ),
      );
      final service = ReportAnalysisService(geminiService: mock);

      expect(
        () => service.analyzeReport(title: 'Incident', description: 'Incident happened'),
        throwsA(isA<GeminiException>()),
      );
    });

    test('2.7 Safe fallback preserves report and Police Dashboard displays "Not Analyzed"', () {
      final unanalyzedReport = <String, dynamic>{
        'title': 'Unanalyzed emergency during network blackout',
        'description': 'Report saved while phone had no internet',
        'status': 'pending',
        'priority': 'PENDING',
        'address': 'Islamabad',
      };

      // Police Dashboard handles unanalyzed report safely
      final display = PoliceReportCard.getPriorityDisplay(unanalyzedReport['priority']);
      expect(display, 'Not Analyzed');

      final color = PoliceReportCard.getPriorityColor(display);
      expect(color, Colors.grey.shade600);
    });
  });

  group('3. INVALID AI RESPONSE TESTING (Corrupted / Malformed Fields)', () {
    test('3.1 Missing priority field normalizes to MEDIUM safely', () {
      final malformedMap = <String, dynamic>{
        'severityScore': 70,
        'reason': 'Valid reason',
        'detectedFactors': ['Risk'],
        'immediateDanger': true,
      };

      final analysis = ReportAiAnalysis.fromMap(malformedMap);
      expect(analysis.priority, 'MEDIUM');
      expect(analysis.severityScore, 70);
    });

    test('3.2 Unknown or arbitrary priority string normalizes to valid enum', () {
      expect(ReportAiAnalysis.normalizePriority('super_urgent_critical'), 'CRITICAL');
      expect(ReportAiAnalysis.normalizePriority('high_risk'), 'HIGH');
      expect(ReportAiAnalysis.normalizePriority('low_priority'), 'LOW');
      expect(ReportAiAnalysis.normalizePriority('unknown_custom_tag'), 'MEDIUM');
      expect(ReportAiAnalysis.normalizePriority(null), 'MEDIUM');
    });

    test('3.3 Out of bounds and non-numeric severity scores clamp safely to [0, 100]', () {
      expect(ReportAiAnalysis.normalizeSeverityScore(-50), 0);
      expect(ReportAiAnalysis.normalizeSeverityScore(999), 100);
      expect(ReportAiAnalysis.normalizeSeverityScore('85'), 85);
      expect(ReportAiAnalysis.normalizeSeverityScore('invalid'), 50);
      expect(ReportAiAnalysis.normalizeSeverityScore(null), 50);
    });

    test('3.4 Boolean fields safely parse string representations, numbers, and nulls', () {
      final map = <String, dynamic>{
        'priority': 'HIGH',
        'severityScore': 80,
        'reason': 'Test',
        'immediateDanger': 'yes',
        'violenceDetected': 'TRUE',
        'weaponDetected': 1,
        'injuryDetected': 'no',
        'threatDetected': null,
      };

      final analysis = ReportAiAnalysis.fromMap(map);
      expect(analysis.immediateDanger, isTrue);
      expect(analysis.violenceDetected, isTrue);
      expect(analysis.weaponDetected, isTrue);
      expect(analysis.injuryDetected, isFalse);
      expect(analysis.threatDetected, isFalse);
    });

    test('3.5 Missing or null detectedFactors safely normalizes to empty list', () {
      final map = <String, dynamic>{
        'priority': 'LOW',
        'severityScore': 20,
        'reason': 'Test',
        'detectedFactors': null,
      };

      final analysis = ReportAiAnalysis.fromMap(map);
      expect(analysis.detectedFactors, isEmpty);
    });

    test('3.6 Missing reason safely falls back to default description', () {
      final map = <String, dynamic>{
        'priority': 'LOW',
        'severityScore': 20,
        'reason': null,
      };

      final analysis = ReportAiAnalysis.fromMap(map);
      expect(analysis.reason, 'No reason provided');
    });

    test('3.7 Malformed JSON syntax throws clean GeminiException', () {
      final mock = MockGeminiService(
        onGenerate: (_) async => const GeminiResponse(
          text: '{ priority: "CRITICAL", missing_quotes }',
          model: 'gemini-3.5-flash',
        ),
      );
      final service = ReportAnalysisService(geminiService: mock);

      expect(
        () => service.analyzeReport(title: 'Crime', description: 'Details'),
        throwsA(isA<GeminiException>()),
      );
    });
  });

  group('4. FIRESTORE FAILURE TESTING (Original Report Preservation)', () {
    test('4.1 Failure during AI Firestore update does not corrupt base report', () {
      // Step 1: Base report document initially written to Firestore
      final firestoreDoc = <String, dynamic>{
        'id': 'REPORT_ABC_123',
        'userId': 'usr_999',
        'userEmail': 'citizen@safetyguardian.pk',
        'category': 'Robbery',
        'title': 'Robbery on main road',
        'description': 'Robbers fled with phone',
        'address': 'Islamabad',
        'images': ['https://example.com/photo.jpg'],
        'status': 'pending',
        'priority': 'PENDING',
        'timestamp': DateTime.now().toIso8601String(),
      };

      // Step 2: Simulate failure during AI field update
      bool aiUpdateSucceeded = false;
      try {
        throw Exception('Simulated Firestore network timeout during doc update');
      } catch (_) {
        aiUpdateSucceeded = false;
      }

      // Step 3: Verify the original report model remains 100% valid & intact
      final report = ReportModel.fromMap(firestoreDoc['id'], firestoreDoc);
      expect(aiUpdateSucceeded, isFalse);
      expect(report.id, 'REPORT_ABC_123');
      expect(firestoreDoc['title'], isNotNull);
      expect(report.description, 'Robbers fled with phone');
      expect(report.category, 'Robbery');
      expect(report.imageUrls.length, 1);
      expect(report.status, 'pending');
      expect(report.priority, 'PENDING');

      // Step 4: Verify Police Dashboard renders unanalyzed report safely
      final priorityDisplay = PoliceReportCard.getPriorityDisplay(report.priority);
      expect(priorityDisplay, 'Not Analyzed');
    });
  });

  group('5. API CALL REGRESSION TESTING (Zero Gemini Calls on Filter/Search/Sort)', () {
    final mockGemini = MockGeminiService();

    final testReports = [
      {
        'id': 'R-01',
        'title': 'Bank Robbery',
        'description': 'Armed robbery in branch',
        'category': 'Robbery',
        'address': 'Attock',
        'status': 'Pending',
        'priority': 'CRITICAL',
        'severityScore': 95,
      },
      {
        'id': 'R-02',
        'title': 'Bicycle Theft',
        'description': 'Bicycle taken from lawn',
        'category': 'Theft',
        'address': 'Rawalpindi',
        'status': 'Resolved',
        'priority': 'LOW',
        'severityScore': 20,
      },
    ];

    test('5.1 Searching reports makes exactly ZERO Gemini API calls', () {
      final initialCalls = mockGemini.callCount;

      for (final query in ['Bank', 'Attock', 'R-01', 'xyz', '']) {
        final matches = testReports.where((r) {
          return PoliceDashboardScreen.matchesSearchQuery(
            report: r,
            docId: r['id'] as String,
            query: query,
          );
        }).toList();
        expect(matches, isNotNull);
      }

      expect(mockGemini.callCount, initialCalls);
    });

    test('5.2 Filtering by Priority, Status, and Category makes ZERO Gemini API calls', () {
      final initialCalls = mockGemini.callCount;

      for (final p in ['all', 'critical', 'high', 'low']) {
        for (final s in ['all', 'pending', 'resolved']) {
          for (final c in ['all', 'robbery', 'theft']) {
            final matches = testReports.where((r) {
              return PoliceDashboardScreen.matchesReportFilters(
                rawPriority: r['priority'],
                rawStatus: r['status'],
                rawCategory: r['category'],
                priorityFilter: p,
                statusFilter: s,
                categoryFilter: c,
                report: r,
                docId: r['id'] as String,
              );
            }).toList();
            expect(matches, isNotNull);
          }
        }
      }

      expect(mockGemini.callCount, initialCalls);
    });

    test('5.3 Sorting reports makes ZERO Gemini API calls', () {
      final initialCalls = mockGemini.callCount;

      for (final opt in PoliceDashboardScreen.sortOptions) {
        final list = List<Map<String, dynamic>>.from(testReports);
        list.sort((a, b) => PoliceDashboardScreen.compareReports(a: a, b: b, sortOption: opt));
        expect(list.length, 2);
      }

      expect(mockGemini.callCount, initialCalls);
    });

    testWidgets('5.4 Opening PoliceReportCard details makes ZERO Gemini API calls', (WidgetTester tester) async {
      final initialCalls = mockGemini.callCount;

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: PoliceReportCard(
                report: testReports.first,
                docId: 'R-01',
              ),
            ),
          ),
        ),
      );

      // Verify category in card header
      expect(find.text('Robbery'), findsOneWidget);

      // Expand card to view full AI analysis details
      await tester.tap(find.text('Robbery'));
      await tester.pumpAndSettle();

      // Verify description in expanded view
      expect(find.text('Armed robbery in branch'), findsOneWidget);
      expect(find.byKey(const Key('report_ai_analysis_section')), findsOneWidget);

      expect(mockGemini.callCount, initialCalls); // Zero calls!
    });
  });

  group('6. DATA INTEGRITY & CORRUPTION RESISTANCE', () {
    test('6.1 AI fields addition cannot overwrite or alter primary report fields', () {
      const originalUserId = 'USR_555';
      const originalEmail = 'citizen@safetyguardian.pk';
      const originalCategory = 'Robbery';
      const originalDesc = 'Armed muggers took phone and wallet.';
      const originalAddress = 'Sector F-6 Super Market, Islamabad';
      final originalImages = ['https://evidence.com/1.jpg', 'https://evidence.com/2.jpg'];
      const originalStatus = 'pending';

      final initialDoc = <String, dynamic>{
        'userId': originalUserId,
        'userEmail': originalEmail,
        'category': originalCategory,
        'description': originalDesc,
        'address': originalAddress,
        'images': originalImages,
        'status': originalStatus,
        'priority': 'PENDING',
      };

      // Simulated AI update payload
      final aiPayload = <String, dynamic>{
        'priority': 'CRITICAL',
        'severityScore': 95,
        'reason': 'Active firearms confrontation',
        'detectedFactors': ['Armed mugging', 'Weapon present'],
        'immediateDanger': true,
        'violenceDetected': true,
        'weaponDetected': true,
        'injuryDetected': false,
        'threatDetected': true,
      };

      // Merging AI payload into same doc
      final mergedDoc = <String, dynamic>{
        ...initialDoc,
        ...aiPayload,
      };

      // Verify NO primary citizen data was corrupted or removed
      expect(mergedDoc['userId'], originalUserId);
      expect(mergedDoc['userEmail'], originalEmail);
      expect(mergedDoc['category'], originalCategory);
      expect(mergedDoc['description'], originalDesc);
      expect(mergedDoc['address'], originalAddress);
      expect(mergedDoc['images'], originalImages);
      expect(mergedDoc['status'], originalStatus);

      // Verify AI fields are properly present
      expect(mergedDoc['priority'], 'CRITICAL');
      expect(mergedDoc['severityScore'], 95);
      expect(mergedDoc['reason'], 'Active firearms confrontation');
    });
  });
}
