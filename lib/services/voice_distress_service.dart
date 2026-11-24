import 'dart:async';
import 'dart:io' show Platform;
import 'dart:math' as math;
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:speech_to_text/speech_to_text.dart' as stt;
import 'package:permission_handler/permission_handler.dart';

/// Categories of detected verbal distress
enum VoiceDistressCategory {
  helpCry,
  threat,
  verbalAbuse,
  screaming,
}

/// Result of voice distress analysis
class VoiceDistressResult {
  final bool isDistress;
  final VoiceDistressCategory? category;
  final String matchedKeyword;
  final String rawText;
  final double confidence;
  final DateTime timestamp;
  final String description;

  const VoiceDistressResult({
    required this.isDistress,
    this.category,
    this.matchedKeyword = '',
    this.rawText = '',
    this.confidence = 0.0,
    required this.timestamp,
    this.description = '',
  });

  static VoiceDistressResult safe(String text) => VoiceDistressResult(
        isDistress: false,
        rawText: text,
        confidence: 0.0,
        timestamp: DateTime.now(),
        description: 'Normal speech',
      );
}

/// Lexical and acoustic analyzer for distress, threat, and abuse detection.
/// Supports Urdu, Roman Urdu, and English keywords.
class VoiceDistressAnalyzer {
  // 1. Distress & Help Cries (Urdu, Roman Urdu, English)
  static final List<String> helpKeywords = [
    // Roman Urdu
    'bachao',
    'bachao mujhe',
    'madad',
    'madad karo',
    'choro mujhe',
    'chodo mujhe',
    'chhor do',
    'chhoro',
    'door raho',
    'dur raho',
    'haath mat lagao',
    'hath mat lagao',
    'police ko bulao',
    'police bulao',
    'police',
    'rokain',
    'ruko',
    'mujhe jane do',
    'mar jayega',
    // English
    'help',
    'help me',
    'save me',
    'someone help',
    'let me go',
    'leave me alone',
    'dont touch me',
    'don\'t touch me',
    'stop it',
    'call police',
    'call 911',
    'call 15',
    'get away',
    // Urdu Script
    'بچاؤ',
    'مدد',
    'پولیس',
    'چھوڑو',
    'دور رہو',
    'مجھے جانے دو',
    'روکو',
  ];

  // 2. Physical Threats, Robbery & Violence (Dhamkiyan)
  static final List<String> threatKeywords = [
    // Roman Urdu
    'maar dunga',
    'maar dungi',
    'mar dunga',
    'mar daalo',
    'mar dalo',
    'khatam kar dunga',
    'jaan se maar',
    'goli maar',
    'goli chalao',
    'chaku maar',
    'chaku nikal',
    'pistol nikal',
    'phone de',
    'phone nikal',
    'bag nikal',
    'loot lo',
    'chheen lo',
    'cheen lo',
    'hathiyar nikal',
    // English
    'i will kill you',
    'ill kill you',
    'i will hurt you',
    'kill you',
    'shoot you',
    'give me your phone',
    'give me the money',
    'give me everything',
    'stab you',
    'i will shoot',
    'i will shoot you',
    // Urdu Script
    'مار دوں گا',
    'مار دوں گی',
    'ختم کر دوں گا',
    'جان سے مار',
    'گولی مار',
    'گولی چلاؤ',
    'چاقو',
    'لوٹ لو',
  ];

  // 3. Verbal Abuse, Harassment & Slurs (Galian)
  static final List<String> abuseKeywords = [
    // Roman Urdu / Punjabi
    'kutta',
    'kutte',
    'kutti',
    'kameena',
    'kamina',
    'kamine',
    'harami',
    'haramzaday',
    'haramzade',
    'haramzada',
    'bhenchod',
    'behenchod',
    'madarchod',
    'gandu',
    'gaandu',
    'chutiya',
    'chutiye',
    'saala',
    'saale',
    'bhadway',
    'bhadwe',
    'bhadwa',
    'kanjar',
    'kanjri',
    'gashti',
    'randi',
    'dallay',
    'dalla',
    'ullu ke pathay',
    // English
    'fuck',
    'fucking',
    'fucker',
    'motherfucker',
    'bitch',
    'bastard',
    'asshole',
    'bullshit',
    'shut up',
    // Urdu Script
    'کتا',
    'کتے',
    'کمینہ',
    'حرامی',
    'حرامزادے',
    'بہن چود',
    'مادر چود',
    'چوتیا',
    'سالا',
    'بھڑوے',
    'کنجر',
    'رنڈی',
  ];

  /// Normalizes incoming text:
  /// - Lowercases
  /// - Removes extra punctuation
  /// - Collapses multiple repeated characters (e.g. "bachaaaao" -> "bachao")
  static String normalizeText(String input) {
    if (input.trim().isEmpty) return '';
    String text = input.toLowerCase().trim();

    // Replace common separators with spaces
    text = text.replaceAll(RegExp(r'[^\w\s\u0600-\u06FF]'), ' ');

    // Collapse multiple whitespace
    text = text.replaceAll(RegExp(r'\s+'), ' ').trim();

    // Collapse 3 or more repeated characters to 1 (e.g., "baaaachaaao" -> "bachao")
    text = text.replaceAllMapped(
      RegExp(r'(\w)\1{2,}'),
      (match) => match.group(1) ?? '',
    );

    return text;
  }

  /// Analyzes a spoken phrase and checks against categorized safety dictionaries
  static VoiceDistressResult analyze(String phrase) {
    final normalized = normalizeText(phrase);
    if (normalized.isEmpty) {
      return VoiceDistressResult.safe(phrase);
    }

    // 1. Check Threat keywords (Highest Priority)
    for (final threat in threatKeywords) {
      if (_matchesKeyword(normalized, threat)) {
        return VoiceDistressResult(
          isDistress: true,
          category: VoiceDistressCategory.threat,
          matchedKeyword: threat,
          rawText: phrase,
          confidence: 0.95,
          timestamp: DateTime.now(),
          description: 'Life Threat / Aggression Detected: "$threat"',
        );
      }
    }

    // 2. Check Help Cry keywords
    for (final help in helpKeywords) {
      if (_matchesKeyword(normalized, help)) {
        return VoiceDistressResult(
          isDistress: true,
          category: VoiceDistressCategory.helpCry,
          matchedKeyword: help,
          rawText: phrase,
          confidence: 0.92,
          timestamp: DateTime.now(),
          description: 'Emergency Distress Cry Detected: "$help"',
        );
      }
    }

    // 3. Check Verbal Abuse / Harassment keywords
    for (final abuse in abuseKeywords) {
      if (_matchesKeyword(normalized, abuse)) {
        return VoiceDistressResult(
          isDistress: true,
          category: VoiceDistressCategory.verbalAbuse,
          matchedKeyword: abuse,
          rawText: phrase,
          confidence: 0.88,
          timestamp: DateTime.now(),
          description: 'Verbal Abuse / Harassment Detected: "$abuse"',
        );
      }
    }

    return VoiceDistressResult.safe(phrase);
  }

  /// Check if the normalized string contains the target keyword
  /// Handles both whole words and multi-word phrases.
  static bool _matchesKeyword(String text, String keyword) {
    final cleanKeyword = normalizeText(keyword);
    if (cleanKeyword.isEmpty) return false;

    // Multi-word phrase check (e.g. "maar dunga", "help me")
    if (cleanKeyword.contains(' ')) {
      return text.contains(cleanKeyword);
    }

    // Single-word check with word boundary logic
    final words = text.split(' ');
    for (final w in words) {
      if (w == cleanKeyword) return true;
      // Allow prefix/suffix variations (e.g. "bachaooo")
      if (w.startsWith(cleanKeyword) && w.length <= cleanKeyword.length + 2) {
        return true;
      }
    }

    return false;
  }
}

/// Service managing real-time speech-to-text listening, sound level updates,
/// and automated distress trigger dispatching.
///
/// While monitoring it keeps the on-device speech recogniser running
/// continuously (restarting it whenever the OS ends a session), analyses every
/// partial transcript for distress keywords, and watches the real microphone
/// level for sustained screaming.
class VoiceDistressService {
  static final VoiceDistressService _instance = VoiceDistressService._internal();
  factory VoiceDistressService() => _instance;
  VoiceDistressService._internal();

  static const MethodChannel _audioChannel =
      MethodChannel('com.safetyguardian/call_guard');

  final stt.SpeechToText _speech = stt.SpeechToText();

  bool _isInitialized = false;
  bool _isListening = false;
  bool _shouldKeepListening = false;
  Timer? _restartTimer;
  int _consecutiveErrors = 0;
  String? _localeId;

  // Adaptive scream detection state
  double _baseline = 0;
  double _variance = 1;
  bool _baselineReady = false;
  int _sampleCount = 0;
  DateTime? _loudSince;
  DateTime _lastScreamAt = DateTime.fromMillisecondsSinceEpoch(0);
  double _minLevel = double.infinity;
  double _maxLevel = double.negativeInfinity;

  /// How long the voice must stay far above the room baseline to count as a scream.
  static const Duration screamDuration = Duration(milliseconds: 1300);

  // Stream controllers for UI updates
  final StreamController<double> _soundLevelController =
      StreamController<double>.broadcast();
  final StreamController<VoiceDistressResult> _distressEventController =
      StreamController<VoiceDistressResult>.broadcast();
  final StreamController<String> _liveTranscriptionController =
      StreamController<String>.broadcast();

  Stream<double> get soundLevelStream => _soundLevelController.stream;
  Stream<VoiceDistressResult> get distressEventStream =>
      _distressEventController.stream;
  Stream<String> get liveTranscriptionStream =>
      _liveTranscriptionController.stream;

  bool get isListening => _isListening;
  bool get isInitialized => _isInitialized;
  bool get isMonitoring => _shouldKeepListening;

  /// Initialize the SpeechToText engine with microphone permission check
  Future<bool> initialize() async {
    if (_isInitialized) return true;

    try {
      final micStatus = await Permission.microphone.request();
      if (!micStatus.isGranted) {
        debugPrint('[VoiceDistressService] Microphone permission not granted: $micStatus');
        return false;
      }
      if (!kIsWeb && Platform.isIOS) {
        final speechStatus = await Permission.speech.request();
        if (!speechStatus.isGranted) {
          debugPrint('[VoiceDistressService] Speech permission not granted: $speechStatus');
          return false;
        }
      }

      _isInitialized = await _speech.initialize(
        onStatus: _handleStatus,
        onError: _handleError,
      );
      if (_isInitialized) {
        _localeId = await _pickLocale();
      }
      return _isInitialized;
    } catch (e) {
      debugPrint('[VoiceDistressService] Initialization error: $e');
      return false;
    }
  }

  /// Prefer Urdu (Pakistan) when the device has it, otherwise English.
  Future<String?> _pickLocale() async {
    try {
      final locales = await _speech.locales();
      for (final id in ['ur_PK', 'ur-PK', 'en_PK', 'en-PK', 'en_IN', 'en-IN']) {
        if (locales.any((l) => l.localeId == id)) return id;
      }
      final system = await _speech.systemLocale();
      return system?.localeId;
    } catch (_) {
      return null;
    }
  }

  void _handleStatus(String status) {
    debugPrint('[VoiceDistressService] Speech status: $status');
    if (status == 'listening') {
      _isListening = true;
      _consecutiveErrors = 0;
    } else if (status == 'notListening' || status == 'done') {
      _isListening = false;
      _scheduleRestart();
    }
  }

  void _handleError(dynamic error) {
    final msg = (error?.errorMsg ?? error).toString();
    debugPrint('[VoiceDistressService] Speech error: $msg');
    _isListening = false;
    if (msg.contains('permission')) {
      _shouldKeepListening = false;
      return;
    }
    // "no match" / "speech timeout" just mean silence: restart quickly.
    final silence = msg.contains('no_match') || msg.contains('speech_timeout');
    if (!silence) _consecutiveErrors++;
    _scheduleRestart();
  }

  void _scheduleRestart() {
    if (!_shouldKeepListening) return;
    _restartTimer?.cancel();
    // Short pause between sessions; longer after real errors.
    final delayMs =
        (800 * (1 << _consecutiveErrors.clamp(0, 4))).clamp(800, 10000);
    _restartTimer = Timer(Duration(milliseconds: delayMs), _startSession);
  }

  /// Android's recogniser beeps every time a listening session starts and
  /// ends, and sessions restart every few seconds in silence. The sounds stay
  /// muted for the whole time monitoring is on (the native side leaves music
  /// alone while the user is playing media) and come back when it stops.
  /// No-op on iOS.
  Future<void> _setBeepMuted(bool muted) async {
    if (kIsWeb || !Platform.isAndroid) return;
    try {
      await _audioChannel.invokeMethod('setBeepMuted', {'muted': muted});
    } catch (_) {}
  }

  Future<void> _startSession() async {
    if (!_shouldKeepListening || _speech.isListening) return;
    await _setBeepMuted(true);
    try {
      await _speech.listen(
        onResult: (result) => _handleWords(result.recognizedWords),
        onSoundLevelChange: _handleSoundLevel,
        listenOptions: stt.SpeechListenOptions(
          localeId: _localeId,
          listenFor: const Duration(minutes: 1),
          pauseFor: const Duration(seconds: 30),
          listenMode: stt.ListenMode.dictation,
          partialResults: true,
          cancelOnError: false,
          onDevice: false,
        ),
      );
      _isListening = true;
    } catch (e) {
      debugPrint('[VoiceDistressService] listen failed: $e');
      _isListening = false;
      _consecutiveErrors++;
      _scheduleRestart();
    }
  }

  void _handleWords(String words) {
    if (words.trim().isEmpty) return;
    _liveTranscriptionController.add(words);
    final analysis = VoiceDistressAnalyzer.analyze(words);
    if (analysis.isDistress) {
      _distressEventController.add(analysis);
    }
  }

  /// Converts raw recogniser levels (dB, range differs per platform) into a
  /// 0..1 value for the UI and runs adaptive scream detection.
  void _handleSoundLevel(double level) {
    _minLevel = math.min(_minLevel, level);
    _maxLevel = math.max(_maxLevel, level);
    final range = (_maxLevel - _minLevel).abs();
    final normalized = range < 0.5 ? 0.0 : ((level - _minLevel) / range).clamp(0.0, 1.0);
    _soundLevelController.add(normalized);

    // Running mean/variance of the room level (slow so a scream stands out).
    _sampleCount++;
    if (!_baselineReady) {
      _baseline = level;
      _variance = 1;
      _baselineReady = true;
      return;
    }
    final std = math.sqrt(_variance).clamp(0.5, 20.0);
    final isLoud = _sampleCount > 30 && level > _baseline + 3.0 * std && normalized > 0.8;

    if (!isLoud) {
      const alpha = 0.03;
      final diff = level - _baseline;
      _baseline += alpha * diff;
      _variance = (1 - alpha) * (_variance + alpha * diff * diff);
      _loudSince = null;
      return;
    }

    final now = DateTime.now();
    _loudSince ??= now;
    if (now.difference(_loudSince!) >= screamDuration &&
        now.difference(_lastScreamAt).inSeconds > 10) {
      _lastScreamAt = now;
      _loudSince = null;
      _distressEventController.add(VoiceDistressResult(
        isDistress: true,
        category: VoiceDistressCategory.screaming,
        matchedKeyword: 'scream',
        rawText: '',
        confidence: 0.75,
        timestamp: now,
        description: 'Screaming / sustained shouting detected',
      ));
    }
  }

  /// Starts continuous real-time voice monitoring.
  Future<bool> startMonitoring({
    Function(VoiceDistressResult)? onDistress,
    Function(double)? onSoundLevel,
    Function(String)? onTranscription,
  }) async {
    final ok = await initialize();
    if (!ok) return false;

    _shouldKeepListening = true;
    _consecutiveErrors = 0;
    _baselineReady = false;
    _sampleCount = 0;
    _minLevel = double.infinity;
    _maxLevel = double.negativeInfinity;
    await _startSession();
    return true;
  }

  /// Listens for one short session (used by the "Speak to Test" chip).
  /// If continuous monitoring is already running this is a no-op.
  Future<bool> listenOnce() async {
    if (_shouldKeepListening && _speech.isListening) return true;
    final ok = await initialize();
    if (!ok) return false;
    if (_speech.isListening) return true;

    try {
      await _speech.listen(
        onResult: (result) => _handleWords(result.recognizedWords),
        onSoundLevelChange: _handleSoundLevel,
        listenOptions: stt.SpeechListenOptions(
          localeId: _localeId,
          listenFor: const Duration(seconds: 6),
          pauseFor: const Duration(seconds: 3),
          listenMode: stt.ListenMode.confirmation,
          partialResults: true,
          cancelOnError: true,
        ),
      );
      _isListening = true;
      return true;
    } catch (e) {
      debugPrint('[VoiceDistressService] listenOnce failed: $e');
      _isListening = false;
      return false;
    }
  }

  /// Stop monitoring voice
  Future<void> stopMonitoring() async {
    _shouldKeepListening = false;
    _restartTimer?.cancel();
    _restartTimer = null;
    try {
      if (_speech.isListening) {
        await _speech.stop();
      }
    } catch (e) {
      debugPrint('[VoiceDistressService] Stop error: $e');
    }
    _isListening = false;
    _soundLevelController.add(0.0);
    await _setBeepMuted(false);
  }

  /// Simulate a spoken phrase (used for test simulation buttons and automated tests)
  VoiceDistressResult simulateSpokenPhrase(String phrase) {
    _liveTranscriptionController.add(phrase);
    final result = VoiceDistressAnalyzer.analyze(phrase);
    if (result.isDistress) {
      _distressEventController.add(result);
    }
    return result;
  }

  /// Dispose service resources
  void dispose() {
    _shouldKeepListening = false;
    _restartTimer?.cancel();
    _restartTimer = null;
    _speech.stop();
    _soundLevelController.close();
    _distressEventController.close();
    _liveTranscriptionController.close();
  }
}
