import 'dart:convert';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'priority_classifier.dart';
import 'package:flutter/foundation.dart';
import '../models/report_model.dart';
import '../models/report_ai_analysis.dart';
import 'gemini_service.dart';

/// Service responsible for semantic AI analysis of incident reports using Gemini.
class ReportAnalysisService {
  final GeminiService _geminiService;

  ReportAnalysisService({GeminiService? geminiService})
      : _geminiService = geminiService ?? GeminiService();

  /// Analyzes an incident report by its individual fields using semantic AI reasoning.
  Future<ReportAiAnalysis> analyzeReport({
    required String title,
    required String description,
    String? category,
    String? location,
  }) async {
    final cleanTitle = title.trim();
    final cleanDesc = description.trim();
    final cleanCategory = category?.trim();
    final cleanLocation = location?.trim();

    // Guard: Handle empty or uninformative descriptions safely without crashing
    if (cleanDesc.isEmpty && cleanTitle.isEmpty) {
      return ReportAiAnalysis.fallback(
        reason: 'Insufficient information: Both title and description are empty.',
        priority: 'LOW',
        severityScore: 10,
      );
    }

    final prompt = buildAnalysisPrompt(
      title: cleanTitle,
      description: cleanDesc,
      category: cleanCategory,
      location: cleanLocation,
    );

    try {
      final geminiResponse = await _geminiService.generateContent(
        prompt,
        generationConfig: const {
          'responseMimeType': 'application/json',
          'temperature': 0.1,
        },
      );

      final jsonMap = _extractAndValidateJson(geminiResponse.text);
      return ReportAiAnalysis.fromMap(jsonMap, model: geminiResponse.model);
    } on GeminiException catch (e) {
      debugPrint('[ReportAnalysisService] GeminiException: ${e.message}');
      rethrow;
    } catch (e) {
      debugPrint('[ReportAnalysisService] Unexpected error: $e');
      throw GeminiException('Failed to analyze report: $e', originalError: e);
    }
  }

  /// Runs (or re-runs) AI prioritisation for an existing Firestore report and
  /// writes the result back to `reports/{docId}`.
  ///
  /// Falls back to the on-device [PriorityClassifier] when Gemini fails so
  /// the dashboard never stays "Not Analyzed". Returns true when Gemini
  /// produced the result, false when the offline fallback was used.
  Future<bool> analyzeAndSaveReport({
    required String docId,
    required Map<String, dynamic> report,
  }) async {
    final title = (report['title'] ?? report['category'] ?? '').toString();
    final description = (report['description'] ?? '').toString();
    final category = (report['category'] ?? 'Other').toString();
    final address = (report['address'] ?? '').toString();
    final ref = FirebaseFirestore.instance.collection('reports').doc(docId);

    try {
      final analysis = await analyzeReport(
        title: title,
        description: description,
        category: category,
        location: address,
      );
      await ref.update({
        'priority': analysis.priority,
        'severityScore': analysis.severityScore,
        'reason': analysis.reason,
        'detectedFactors': analysis.detectedFactors,
        'immediateDanger': analysis.immediateDanger,
        'violenceDetected': analysis.violenceDetected,
        'weaponDetected': analysis.weaponDetected,
        'injuryDetected': analysis.injuryDetected,
        'threatDetected': analysis.threatDetected,
        'analysisSource': 'gemini',
        'priorityAnalyzedAt': FieldValue.serverTimestamp(),
      });
      return true;
    } catch (e) {
      debugPrint('[ReportAnalysisService] Falling back to offline classifier: $e');
      final fields = PriorityClassifier.offlineAnalysisFields(
        category: category,
        title: title,
        description: description,
      );
      fields['priorityAnalyzedAt'] = FieldValue.serverTimestamp();
      await ref.update(fields);
      return false;
    }
  }

  /// True when a report has no AI result yet (or only the offline estimate).
  static bool needsAnalysis(Map<String, dynamic> report) {
    final p = (report['priority'] ?? '').toString().trim().toLowerCase();
    if (p.isEmpty || p == 'pending' || p == 'not analyzed' || p == 'not_analyzed') {
      return true;
    }
    if (report['analysisSource'] == 'offline') return true;
    if (report['severityScore'] == null) return true;
    final reason = (report['reason'] ?? '').toString();
    return reason.contains('AI analysis temporarily unavailable');
  }

  /// Reuses the existing [ReportModel] to run semantic AI prioritization.
  Future<ReportAiAnalysis> analyzeReportModel(ReportModel report) {
    return analyzeReport(
      title: report.category,
      description: report.description,
      category: report.category,
      location: report.address,
    );
  }

  /// Builds a structured prompt instructing Gemini to perform contextual semantic analysis.
  static String buildAnalysisPrompt({
    required String title,
    required String description,
    String? category,
    String? location,
  }) {
    return '''
You are an expert law enforcement intelligence and public safety triage AI for the SafetyGuardian emergency platform.
Analyze the following citizen incident report using deep semantic understanding, contextual reasoning, threat assessment, and real-world risk evaluation.

CRITICAL INSTRUCTIONS:
1. Do NOT rely on simplistic keyword checks. Understand the full human meaning, implicit context, severity of harm, and active risk to human life.
2. Evaluate if there is an active/recent threat, weapon presence (firearms, knives, bludgeons, etc.), physical or sexual violence, injury or bleeding, hostage situation, or vulnerable victims.
3. Determine priority strictly into one of four tiers:
   - "CRITICAL": Active life-threatening danger, ongoing violent crime, armed assault, hostage/kidnapping, severe injury, immediate dispatch required.
   - "HIGH": Serious crime, weapon threat, robbery, severe harassment, domestic violence, significant physical risk, urgent attention needed.
   - "MEDIUM": Property crime, burglary without confrontation, fraud, corruption, theft, non-violent harassment, moderate safety concerns.
   - "LOW": Noise complaints, minor disturbances, parking issues, non-urgent infrastructure or traffic violations, historical minor disputes.
4. "severityScore": An integer from 0 (completely benign/trivial) to 100 (catastrophic immediate life-or-death emergency).
5. "detectedFactors": A concise list of 2-5 key situational factors identified (e.g. "Armed threat", "Death threat", "Property loss", "Physical injury").
6. Booleans: Accurately evaluate immediateDanger, violenceDetected, weaponDetected, injuryDetected, threatDetected based on the context.

Report Details:
- Title: ${title.isEmpty ? 'Untitled Report' : title}
- Category: ${category != null && category.isNotEmpty ? category : 'Unspecified'}
- Description: ${description.isEmpty ? 'No description provided.' : description}
${location != null && location.isNotEmpty ? '- Location: $location' : ''}

Respond ONLY with valid JSON conforming exactly to this schema:
{
  "priority": "CRITICAL" | "HIGH" | "MEDIUM" | "LOW",
  "severityScore": <integer 0-100>,
  "reason": "<clear concise 1-2 sentence explanation of the assessment>",
  "detectedFactors": ["<factor1>", "<factor2>"],
  "immediateDanger": <true or false>,
  "violenceDetected": <true or false>,
  "weaponDetected": <true or false>,
  "injuryDetected": <true or false>,
  "threatDetected": <true or false>
}
''';
  }

  /// Extracts and validates JSON from Gemini response, stripping markdown fences if present.
  static Map<String, dynamic> _extractAndValidateJson(String rawText) {
    var cleaned = rawText.trim();
    if (cleaned.startsWith('```json')) {
      cleaned = cleaned.substring(7);
    } else if (cleaned.startsWith('```')) {
      cleaned = cleaned.substring(3);
    }
    if (cleaned.endsWith('```')) {
      cleaned = cleaned.substring(0, cleaned.length - 3);
    }
    cleaned = cleaned.trim();

    dynamic decoded;
    try {
      decoded = jsonDecode(cleaned);
    } catch (e) {
      throw GeminiException('Gemini returned invalid non-JSON output: $cleaned', originalError: e);
    }

    if (decoded is! Map<String, dynamic>) {
      throw GeminiException('Expected JSON object from Gemini, got ${decoded.runtimeType}');
    }

    // Required fields validation
    final requiredKeys = [
      'priority',
      'severityScore',
      'reason',
      'detectedFactors',
      'immediateDanger',
      'violenceDetected',
      'weaponDetected',
      'injuryDetected',
      'threatDetected',
    ];

    for (final key in requiredKeys) {
      if (!decoded.containsKey(key)) {
        throw GeminiException('Gemini JSON response is missing required key: "$key"');
      }
    }

    return decoded;
  }
}
