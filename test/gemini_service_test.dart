// ignore_for_file: avoid_print
import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:safety_guardian/services/gemini_service.dart';

void main() {
  group('GeminiService Connection Tests', () {
    test('Throws GeminiAuthException when API key is missing', () async {
      final service = GeminiService(apiKey: '');
      expect(service.hasApiKey, isFalse);

      final result = await service.testConnection();
      expect(result.success, isFalse);
      expect(result.error, isA<GeminiAuthException>());
    });

    test('Reports failure when an invalid API key is provided', () async {
      final service = GeminiService(apiKey: 'AIzaSy_INVALID_KEY_FOR_TESTING_123456');
      final result = await service.testConnection();
      expect(result.success, isFalse);
      expect(result.error, isA<GeminiAuthException>());
    });

    test('Successfully connects to Gemini and receives test response', () async {
      // 1. Check if key provided via --dart-define or Platform env
      String apiKey = const String.fromEnvironment('GEMINI_API_KEY');
      if (apiKey.isEmpty) {
        apiKey = Platform.environment['GEMINI_API_KEY'] ?? '';
      }

      // 2. Fallback to local git-ignored api_keys.json if present
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

      if (apiKey.isEmpty) {
        // Skip live network call if no key is configured in this test environment
        print('Skipping live Gemini test: No API key found via --dart-define or api_keys.json');
        return;
      }

      final service = GeminiService(apiKey: apiKey);
      expect(service.hasApiKey, isTrue);

      final result = await service.testConnection();

      print('-----------------------------------------');
      print('Gemini Test Result:');
      print('Success: ${result.success}');
      print('Message: ${result.message}');
      print('Model:   ${result.response?.model}');
      print('Tokens:  ${result.response?.totalTokens}');
      print('-----------------------------------------');

      if (!result.success && result.error is GeminiQuotaException) {
        print('Note: Free-tier 20 RPM quota was reached on live Google endpoint: ${result.message}');
        expect(result.error, isA<GeminiQuotaException>());
        return;
      }

      expect(result.success, isTrue, reason: 'Gemini connection failed: ${result.message}');
      expect(
        result.message.toLowerCase(),
        contains('gemini connection successful'),
      );
    });
  });
}
