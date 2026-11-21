import 'dart:io' show Platform;
import 'package:dio/dio.dart';

/// Base exception for all Gemini API related errors.
class GeminiException implements Exception {
  final String message;
  final int? statusCode;
  final dynamic originalError;

  const GeminiException(this.message, {this.statusCode, this.originalError});

  @override
  String toString() => 'GeminiException: $message (statusCode: $statusCode)';
}

/// Thrown when the Gemini API key is missing or invalid.
class GeminiAuthException extends GeminiException {
  const GeminiAuthException(super.message, {super.statusCode, super.originalError});
}

/// Thrown when API quota or rate limits are reached (HTTP 429).
class GeminiQuotaException extends GeminiException {
  const GeminiQuotaException(super.message, {super.statusCode, super.originalError});
}

/// Thrown when internet connection or host resolution fails.
class GeminiNetworkException extends GeminiException {
  const GeminiNetworkException(super.message, {super.statusCode, super.originalError});
}

/// Thrown when Gemini servers encounter an internal error (HTTP 5xx).
class GeminiServerException extends GeminiException {
  const GeminiServerException(super.message, {super.statusCode, super.originalError});
}

/// Structured response from Gemini.
class GeminiResponse {
  final String text;
  final String model;
  final int? promptTokens;
  final int? candidateTokens;
  final int? totalTokens;

  const GeminiResponse({
    required this.text,
    required this.model,
    this.promptTokens,
    this.candidateTokens,
    this.totalTokens,
  });
}

/// Result of testing the Gemini connection.
class GeminiTestResult {
  final bool success;
  final String message;
  final GeminiResponse? response;
  final GeminiException? error;

  const GeminiTestResult({
    required this.success,
    required this.message,
    this.response,
    this.error,
  });

  @override
  String toString() => success
      ? 'GeminiTestResult(SUCCESS: "$message")'
      : 'GeminiTestResult(FAILED: "$message")';
}

/// Service to interact with the Google Gemini API.
class GeminiService {
  final String? _injectedApiKey;
  final String model;
  final Dio _dio;

  static const String defaultModel = 'gemini-3.5-flash';
  static const String alternateModel = 'gemini-3.8-flash';
  static const String _baseUrl = 'https://generativelanguage.googleapis.com/v1beta';

  GeminiService({
    String? apiKey,
    this.model = defaultModel,
    Dio? dio,
  })  : _injectedApiKey = apiKey,
        _dio = dio ??
            Dio(
              BaseOptions(
                connectTimeout: const Duration(seconds: 15),
                receiveTimeout: const Duration(seconds: 30),
                headers: {'Content-Type': 'application/json'},
              ),
            );

  /// Resolves the API key securely in the following order:
  /// 1. Constructor injected key
  /// 2. --dart-define=GEMINI_API_KEY=... / --dart-define-from-file=api_keys.json
  /// 3. Platform environment variable GEMINI_API_KEY (in CLI/test runners)
  String get apiKey {
    final injectedKey = _injectedApiKey;
    if (injectedKey != null) {
      return injectedKey.trim();
    }

    const compileTimeKey = String.fromEnvironment('GEMINI_API_KEY');
    if (compileTimeKey.trim().isNotEmpty) {
      return compileTimeKey.trim();
    }

    try {
      final envKey = Platform.environment['GEMINI_API_KEY'];
      if (envKey != null && envKey.trim().isNotEmpty) {
        return envKey.trim();
      }
    } catch (_) {
      // Platform.environment is not accessible on web
    }

    return '';
  }

  /// Verifies that an API key is configured.
  bool get hasApiKey => apiKey.isNotEmpty;

  /// Sends a prompt to Gemini and receives the generated text.
  Future<GeminiResponse> generateContent(
    String prompt, {
    Map<String, dynamic>? generationConfig,
    String? overrideModel,
  }) async {
    final key = apiKey;
    if (key.isEmpty) {
      throw const GeminiAuthException(
        'Gemini API key is not configured. Provide it via --dart-define=GEMINI_API_KEY=... '
        'or via api_keys.json, or pass it to GeminiService(apiKey: ...).',
      );
    }

    final targetModel = overrideModel ?? model;
    final endpoint = '$_baseUrl/models/$targetModel:generateContent?key=$key';
    final payload = <String, dynamic>{
      'contents': [
        {
          'parts': [
            {'text': prompt}
          ]
        }
      ],
      'generationConfig': ?generationConfig,
    };

    int attempt = 0;
    const maxAttempts = 3;

    while (true) {
      attempt++;
      try {
        final response = await _dio.post(
          endpoint,
          data: payload,
        );

        final data = response.data;
        if (data is! Map<String, dynamic>) {
          throw GeminiException(
            'Unexpected response format from Gemini API.',
            statusCode: response.statusCode,
          );
        }

        final candidates = data['candidates'] as List<dynamic>?;
        if (candidates == null || candidates.isEmpty) {
          final promptFeedback = data['promptFeedback'];
          throw GeminiException(
            'No candidate generated by Gemini. Feedback: $promptFeedback',
            statusCode: response.statusCode,
          );
        }

        final firstCandidate = candidates.first as Map<String, dynamic>;
        final content = firstCandidate['content'] as Map<String, dynamic>?;
        final parts = content?['parts'] as List<dynamic>?;

        if (parts == null || parts.isEmpty) {
          throw GeminiException(
            'Gemini returned an empty content part.',
            statusCode: response.statusCode,
          );
        }

        final text = parts.first['text'] as String? ?? '';
        final usage = data['usageMetadata'] as Map<String, dynamic>?;

        return GeminiResponse(
          text: text.trim(),
          model: targetModel,
          promptTokens: usage?['promptTokenCount'] as int?,
          candidateTokens: usage?['candidatesTokenCount'] as int?,
          totalTokens: usage?['totalTokenCount'] as int?,
        );
      } on DioException catch (dioErr) {
        final statusCode = dioErr.response?.statusCode;
        if ((statusCode == 503 || statusCode == 429) && attempt < maxAttempts) {
          // Wait with backoff before retrying
          await Future.delayed(Duration(milliseconds: 1500 * attempt));
          continue;
        }
        if (statusCode == 503 && overrideModel == null) {
          // Try alternate model
          try {
            return await generateContent(
              prompt,
              generationConfig: generationConfig,
              overrideModel: alternateModel,
            );
          } catch (_) {}
        }
        throw _handleDioError(dioErr);
      } catch (e) {
        if (e is GeminiException) rethrow;
        throw GeminiException('Unexpected error invoking Gemini: $e', originalError: e);
      }
    }
  }

  /// Sends the official test prompt to verify connection with Gemini:
  /// "Respond with exactly: Gemini connection successful"
  Future<GeminiTestResult> testConnection() async {
    const testPrompt = 'Respond with exactly: Gemini connection successful';
    try {
      final res = await generateContent(testPrompt);
      return GeminiTestResult(
        success: true,
        message: res.text,
        response: res,
      );
    } on GeminiException catch (e) {
      return GeminiTestResult(
        success: false,
        message: e.message,
        error: e,
      );
    } catch (e) {
      final geminiErr = GeminiException('Unexpected error: $e', originalError: e);
      return GeminiTestResult(
        success: false,
        message: geminiErr.message,
        error: geminiErr,
      );
    }
  }

  /// Maps DioException to appropriate typed GeminiException.
  GeminiException _handleDioError(DioException error) {
    final statusCode = error.response?.statusCode;
    final responseData = error.response?.data;
    String apiErrorMessage = '';

    if (responseData is Map<String, dynamic> && responseData.containsKey('error')) {
      final errObj = responseData['error'];
      if (errObj is Map<String, dynamic> && errObj.containsKey('message')) {
        apiErrorMessage = errObj['message'].toString();
      }
    } else if (responseData != null) {
      apiErrorMessage = responseData.toString();
    }

    if (statusCode == 400 || statusCode == 401 || statusCode == 403) {
      return GeminiAuthException(
        apiErrorMessage.isNotEmpty
            ? 'Gemini authentication/permission error: $apiErrorMessage'
            : 'Invalid Gemini API key or unauthorized access (HTTP $statusCode).',
        statusCode: statusCode,
        originalError: error,
      );
    }

    if (statusCode == 404) {
      return GeminiException(
        apiErrorMessage.isNotEmpty
            ? 'Gemini model not found: $apiErrorMessage'
            : 'Model "$model" was not found (HTTP 404).',
        statusCode: statusCode,
        originalError: error,
      );
    }

    if (statusCode == 429) {
      return GeminiQuotaException(
        apiErrorMessage.isNotEmpty
            ? 'Gemini rate/quota limit reached: $apiErrorMessage'
            : 'Gemini API quota exceeded or rate limit reached (HTTP 429). Please wait before retrying.',
        statusCode: statusCode,
        originalError: error,
      );
    }

    if (statusCode != null && statusCode >= 500) {
      return GeminiServerException(
        apiErrorMessage.isNotEmpty
            ? 'Gemini server error: $apiErrorMessage'
            : 'Gemini service temporarily unavailable (HTTP $statusCode).',
        statusCode: statusCode,
        originalError: error,
      );
    }

    if (error.type == DioExceptionType.connectionTimeout ||
        error.type == DioExceptionType.sendTimeout ||
        error.type == DioExceptionType.receiveTimeout ||
        error.type == DioExceptionType.connectionError) {
      return GeminiNetworkException(
        'Unable to connect to Gemini API. Check internet connectivity: ${error.message}',
        statusCode: statusCode,
        originalError: error,
      );
    }

    return GeminiException(
      apiErrorMessage.isNotEmpty
          ? apiErrorMessage
          : (error.message ?? 'Unknown network error communicating with Gemini API.'),
      statusCode: statusCode,
      originalError: error,
    );
  }
}
