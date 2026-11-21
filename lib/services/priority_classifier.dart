class PriorityClassifier {
  static const Map<String, int> _categoryScores = {
    'Murder': 8,
    'Snatching': 6,
    'Robbery': 5,
    'Harassment': 4,
    'Corruption': 3,
    'Traffic Violation': 2,
    'Other': 1,
  };

  static const List<String> _highUrgencyKeywords = [
    'knife', 'gun', 'weapon', 'armed', 'pistol', 'blood', 'bleeding',
    'stab', 'shot', 'shoot', 'kill', 'murder', 'dying', 'unconscious',
    'attack', 'attacking', 'assault', 'rape', 'kidnap', 'abduct',
    'hostage', 'trapped', 'help me', 'save me', 'emergency',
  ];

  static const List<String> _timeSensitiveKeywords = [
    'right now', 'happening now', 'currently', 'just now', 'moments ago',
    'in progress', 'as we speak', 'this moment',
  ];

  static const List<String> _mediumUrgencyKeywords = [
    'stole', 'stolen', 'robbed', 'threatened', 'threat', 'followed',
    'following', 'chased', 'harass', 'groping', 'touched', 'inappropriate',
    'broke in', 'broke into', 'break-in', 'snatched', 'mugged',
  ];

  static const List<String> _lowUrgencyKeywords = [
    'noise', 'noisy', 'loud music', 'complaint', 'yesterday', 'last week',
    'last month', 'a while ago', 'minor', 'parking', 'littering',
    'suspicious behavior', 'concerned about',
  ];

  static String classify({
    required String category,
    required String title,
    required String description,
  }) {
    int score = _categoryScores[category] ?? 1;

    final text = '${title.toLowerCase()} ${description.toLowerCase()}';

    for (final keyword in _highUrgencyKeywords) {
      if (text.contains(keyword)) score += 3;
    }

    for (final keyword in _timeSensitiveKeywords) {
      if (text.contains(keyword)) score += 2;
    }

    for (final keyword in _mediumUrgencyKeywords) {
      if (text.contains(keyword)) score += 1;
    }

    for (final keyword in _lowUrgencyKeywords) {
      if (text.contains(keyword)) score -= 2;
    }

    if (score >= 7) return 'high';
    if (score >= 3) return 'medium';
    return 'low';
  }

  /// Numeric 0-100 score used for sorting when Gemini is unavailable.
  static int score({
    required String category,
    required String title,
    required String description,
  }) {
    final p = classify(category: category, title: title, description: description);
    final text = '${title.toLowerCase()} ${description.toLowerCase()}';
    final weapon = ['knife', 'gun', 'pistol', 'weapon', 'armed', 'shot', 'stab']
        .any(text.contains);
    switch (p) {
      case 'high':
        return weapon ? 85 : 72;
      case 'medium':
        return 50;
      default:
        return 22;
    }
  }

  /// Firestore fields matching the Gemini analysis schema, produced offline.
  static Map<String, dynamic> offlineAnalysisFields({
    required String category,
    required String title,
    required String description,
  }) {
    final text = '${title.toLowerCase()} ${description.toLowerCase()}';
    bool has(List<String> words) => words.any(text.contains);

    final weapon = has(['knife', 'gun', 'pistol', 'weapon', 'armed', 'chaku', 'goli']);
    final injury = has(['blood', 'bleeding', 'injur', 'hurt', 'unconscious', 'dying']);
    final violence = has(['attack', 'assault', 'beat', 'hit', 'stab', 'shot', 'rape', 'kidnap']);
    final threat = has(['threat', 'kill', 'maar', 'follow', 'stalk', 'blackmail']);
    final now = has(['right now', 'happening now', 'currently', 'in progress', 'abhi']);

    final level = classify(category: category, title: title, description: description);
    String priority = level.toUpperCase();
    if (level == 'high' && (weapon || injury) && now) priority = 'CRITICAL';

    final factors = <String>[
      if (weapon) 'Weapon mentioned',
      if (injury) 'Possible injury',
      if (violence) 'Violence described',
      if (threat) 'Threat described',
      if (now) 'Ongoing incident',
      'Category: $category',
    ];

    return {
      'priority': priority,
      'severityScore': priority == 'CRITICAL'
          ? 92
          : score(category: category, title: title, description: description),
      'reason':
          'Preliminary on-device keyword assessment (AI service was unavailable). Re-run AI analysis for a full review.',
      'detectedFactors': factors.take(5).toList(),
      'immediateDanger': priority == 'CRITICAL' || (now && (weapon || violence)),
      'violenceDetected': violence,
      'weaponDetected': weapon,
      'injuryDetected': injury,
      'threatDetected': threat,
      'analysisSource': 'offline',
    };
  }
}
