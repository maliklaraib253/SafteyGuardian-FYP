// ignore_for_file: avoid_print
import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:safety_guardian/models/report_model.dart';
import 'package:safety_guardian/services/gemini_service.dart';
import 'package:safety_guardian/services/report_analysis_service.dart';

void main() {
  String getApiKey() {
    String apiKey = const String.fromEnvironment('GEMINI_API_KEY');
    if (apiKey.isEmpty) {
      apiKey = Platform.environment['GEMINI_API_KEY'] ?? '';
    }
    if (apiKey.isEmpty) {
      final localKeyFile = File('api_keys.json');
      if (localKeyFile.existsSync()) {
        try {
          final json = jsonDecode(localKeyFile.readAsStringSync());
          if (json is Map && json['GEMINI_API_KEY'] != null) {
            apiKey = json['GEMINI_API_KEY'].toString().trim();
          }
        } catch (_) {}
      }
    }
    return apiKey;
  }

  group('ReportAnalysisService Semantic Tests', () {
    late ReportAnalysisService analysisService;
    final apiKey = getApiKey();

    setUp(() {
      analysisService = ReportAnalysisService(
        geminiService: GeminiService(apiKey: apiKey),
      );
    });

    test('Safely handles empty description with fallback analysis', () async {
      final result = await analysisService.analyzeReport(
        title: '',
        description: '',
      );

      expect(result.priority, 'LOW');
      expect(result.severityScore, lessThanOrEqualTo(20));
      expect(result.immediateDanger, isFalse);
      expect(result.weaponDetected, isFalse);
    });

    test('Case 1: Armed threat (User Example) -> CRITICAL or HIGH', () async {
      if (apiKey.isEmpty) {
        print('Skipping live test: No API key found.');
        return;
      }

      print('\n======================================================');
      print('TEST CASE 1: Armed Threat on Way Home');
      print('Description: "Two armed people stopped me on my way home and threatened to kill me."');
      print('======================================================');

      try {
        final result = await analysisService.analyzeReport(
          title: 'Threat on way home',
          category: 'Other', // Notice category is generic, AI must infer from semantics
          description: 'Two armed people stopped me on my way home and threatened to kill me.',
          location: 'Sector G-9, Islamabad',
        );

        print('DEBUG OUTPUT:');
        print('Priority:          ${result.priority}');
        print('Severity Score:    ${result.severityScore}/100');
        print('Reason:            ${result.reason}');
        print('Detected Factors:  ${result.detectedFactors}');
        print('Immediate Danger:  ${result.immediateDanger}');
        print('Violence Detected: ${result.violenceDetected}');
        print('Weapon Detected:   ${result.weaponDetected}');
        print('Injury Detected:   ${result.injuryDetected}');
        print('Threat Detected:   ${result.threatDetected}');
        print('Analyzed By Model: ${result.model}');
        print('======================================================\n');

        expect(result.priority == 'CRITICAL' || result.priority == 'HIGH', isTrue);
        expect(result.weaponDetected, isTrue);
        expect(result.threatDetected, isTrue);
        expect(result.severityScore, greaterThanOrEqualTo(70));
      } on GeminiQuotaException catch (e) {
        print('Skipping live assertion due to Google Free-Tier 20 RPM limit: $e');
      }
    });

    test('Case 2: Non-violent property theft -> MEDIUM or LOW', () async {
      if (apiKey.isEmpty) return;

      print('\n======================================================');
      print('TEST CASE 2: Non-violent Property Theft');
      print('Description: "Someone broke my car window overnight and took my work laptop from the front seat."');
      print('======================================================');

      try {
        final result = await analysisService.analyzeReport(
          title: 'Laptop stolen from vehicle',
          category: 'Theft',
          description: 'Someone broke my car window overnight and took my work laptop from the front seat.',
          location: 'Parking area, Blue Area, Islamabad',
        );

        print('DEBUG OUTPUT:');
        print('Priority:          ${result.priority}');
        print('Severity Score:    ${result.severityScore}/100');
        print('Reason:            ${result.reason}');
        print('Detected Factors:  ${result.detectedFactors}');
        print('Immediate Danger:  ${result.immediateDanger}');
        print('Weapon Detected:   ${result.weaponDetected}');
        print('Threat Detected:   ${result.threatDetected}');
        print('======================================================\n');

        expect(result.priority == 'MEDIUM' || result.priority == 'LOW', isTrue);
        expect(result.weaponDetected, isFalse);
        expect(result.immediateDanger, isFalse);
      } on GeminiQuotaException catch (e) {
        print('Skipping live assertion due to Google Free-Tier 20 RPM limit: $e');
      }
    });

    test('Case 3: Minor Noise Disturbance -> LOW', () async {
      if (apiKey.isEmpty) return;

      print('\n======================================================');
      print('TEST CASE 3: Minor Noise Complaint');
      print('Description: "Loud music playing from neighbor\'s backyard after midnight."');
      print('======================================================');

      try {
        final result = await analysisService.analyzeReport(
          title: 'Loud music complaint',
          category: 'Other',
          description: "Loud music playing from neighbor's backyard after midnight.",
          location: 'F-10/2, Islamabad',
        );

        print('DEBUG OUTPUT:');
        print('Priority:          ${result.priority}');
        print('Severity Score:    ${result.severityScore}/100');
        print('Reason:            ${result.reason}');
        print('Detected Factors:  ${result.detectedFactors}');
        print('Immediate Danger:  ${result.immediateDanger}');
        print('Violence Detected: ${result.violenceDetected}');
        print('Weapon Detected:   ${result.weaponDetected}');
        print('======================================================\n');

        expect(result.priority, 'LOW');
        expect(result.severityScore, lessThanOrEqualTo(40));
        expect(result.weaponDetected, isFalse);
        expect(result.violenceDetected, isFalse);
      } on GeminiQuotaException catch (e) {
        print('Skipping live assertion due to Google Free-Tier 20 RPM limit: $e');
      }
    });

    test('Case 4: Reusing existing ReportModel instance', () async {
      if (apiKey.isEmpty) return;

      final existingReport = ReportModel(
        id: 'RPT_TEST_001',
        userId: 'user_123',
        userEmail: 'citizen@safety.pk',
        category: 'Robbery',
        description: 'Masked man holding a knife forced cashier to hand over store cash register.',
        latitude: 33.6844,
        longitude: 73.0479,
        address: 'Commercial Market, Rawalpindi',
        imageUrls: [],
        timestamp: DateTime.now(),
        status: 'pending',
        priority: 'medium',
      );

      try {
        final result = await analysisService.analyzeReportModel(existingReport);

        expect(result.priority == 'CRITICAL' || result.priority == 'HIGH', isTrue);
        expect(result.weaponDetected, isTrue);
      } on GeminiQuotaException catch (e) {
        print('Skipping live assertion due to Google Free-Tier 20 RPM limit: $e');
      }
    });
  });
}
