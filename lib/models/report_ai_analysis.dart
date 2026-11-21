/// Strongly-typed model representing the semantic AI analysis of an incident report.
class ReportAiAnalysis {
  final String priority; // 'CRITICAL', 'HIGH', 'MEDIUM', 'LOW'
  final int severityScore; // 0 - 100
  final String reason;
  final List<String> detectedFactors;
  final bool immediateDanger;
  final bool violenceDetected;
  final bool weaponDetected;
  final bool injuryDetected;
  final bool threatDetected;
  final DateTime analyzedAt;
  final String? model;

  const ReportAiAnalysis({
    required this.priority,
    required this.severityScore,
    required this.reason,
    required this.detectedFactors,
    required this.immediateDanger,
    required this.violenceDetected,
    required this.weaponDetected,
    required this.injuryDetected,
    required this.threatDetected,
    required this.analyzedAt,
    this.model,
  });

  /// Validates and normalizes priority string to one of the 4 allowed values.
  static String normalizePriority(String? input) {
    if (input == null) return 'MEDIUM';
    final upper = input.trim().toUpperCase();
    if (upper == 'CRITICAL' || upper == 'HIGH' || upper == 'MEDIUM' || upper == 'LOW') {
      return upper;
    }
    // Handle edge cases
    if (upper.contains('CRIT')) return 'CRITICAL';
    if (upper.contains('HIGH')) return 'HIGH';
    if (upper.contains('MED')) return 'MEDIUM';
    if (upper.contains('LOW')) return 'LOW';
    return 'MEDIUM';
  }

  /// Clamps severity score safely between 0 and 100.
  static int normalizeSeverityScore(dynamic input) {
    if (input is num) {
      return input.toInt().clamp(0, 100);
    }
    if (input is String) {
      final parsed = int.tryParse(input.trim());
      if (parsed != null) return parsed.clamp(0, 100);
    }
    return 50;
  }

  /// Parses boolean with fallback.
  static bool _parseBool(dynamic val, [bool fallback = false]) {
    if (val is bool) return val;
    if (val is String) {
      final lower = val.toLowerCase().trim();
      if (lower == 'true' || lower == 'yes' || lower == '1') return true;
      if (lower == 'false' || lower == 'no' || lower == '0') return false;
    }
    if (val is num) return val != 0;
    return fallback;
  }

  /// Constructs from validated JSON map returned by Gemini.
  factory ReportAiAnalysis.fromMap(Map<String, dynamic> map, {String? model}) {
    final factorsRaw = map['detectedFactors'];
    final factors = <String>[];
    if (factorsRaw is List) {
      for (final item in factorsRaw) {
        if (item != null) factors.add(item.toString().trim());
      }
    }

    return ReportAiAnalysis(
      priority: normalizePriority(map['priority']?.toString()),
      severityScore: normalizeSeverityScore(map['severityScore']),
      reason: (map['reason'] ?? 'No reason provided').toString().trim(),
      detectedFactors: factors,
      immediateDanger: _parseBool(map['immediateDanger']),
      violenceDetected: _parseBool(map['violenceDetected']),
      weaponDetected: _parseBool(map['weaponDetected']),
      injuryDetected: _parseBool(map['injuryDetected']),
      threatDetected: _parseBool(map['threatDetected']),
      analyzedAt: DateTime.now(),
      model: model,
    );
  }

  /// Creates a safe fallback analysis when AI is unavailable or input is minimal.
  factory ReportAiAnalysis.fallback({
    String reason = 'Automated initial classification (offline fallback)',
    String priority = 'MEDIUM',
    int severityScore = 50,
  }) {
    return ReportAiAnalysis(
      priority: normalizePriority(priority),
      severityScore: severityScore.clamp(0, 100),
      reason: reason,
      detectedFactors: const ['Preliminary review'],
      immediateDanger: priority.toUpperCase() == 'CRITICAL',
      violenceDetected: false,
      weaponDetected: false,
      injuryDetected: false,
      threatDetected: false,
      analyzedAt: DateTime.now(),
      model: 'fallback',
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'priority': priority,
      'severityScore': severityScore,
      'reason': reason,
      'detectedFactors': detectedFactors,
      'immediateDanger': immediateDanger,
      'violenceDetected': violenceDetected,
      'weaponDetected': weaponDetected,
      'injuryDetected': injuryDetected,
      'threatDetected': threatDetected,
      'analyzedAt': analyzedAt.toIso8601String(),
      if (model != null) 'model': model,
    };
  }

  @override
  String toString() {
    return 'ReportAiAnalysis(priority: $priority, score: $severityScore, '
        'immediateDanger: $immediateDanger, weapon: $weaponDetected, '
        'violence: $violenceDetected, threat: $threatDetected, injury: $injuryDetected, '
        'reason: "$reason", factors: $detectedFactors)';
  }
}
