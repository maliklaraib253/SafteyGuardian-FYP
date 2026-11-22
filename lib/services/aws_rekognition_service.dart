import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;

class AwsCompareResult {
  final bool success;
  final bool isMatch;
  final double similarity;
  final String? errorMessage;
  final Map<String, dynamic>? rawData;

  const AwsCompareResult({
    required this.success,
    required this.isMatch,
    required this.similarity,
    this.errorMessage,
    this.rawData,
  });

  factory AwsCompareResult.failure(String message) {
    return AwsCompareResult(
      success: false,
      isMatch: false,
      similarity: 0.0,
      errorMessage: message,
    );
  }

  factory AwsCompareResult.matched(double similarity, Map<String, dynamic> raw) {
    return AwsCompareResult(
      success: true,
      isMatch: true,
      similarity: similarity,
      rawData: raw,
    );
  }

  factory AwsCompareResult.notMatched(double similarity, Map<String, dynamic> raw) {
    return AwsCompareResult(
      success: true,
      isMatch: false,
      similarity: similarity,
      rawData: raw,
    );
  }

  @override
  String toString() =>
      'AwsCompareResult(success: $success, isMatch: $isMatch, similarity: ${similarity.toStringAsFixed(1)}%, error: $errorMessage)';
}

class AwsRekognitionService {
  // Keys are NOT stored in source code. They come from api_keys.json
  // (git-ignored) at build time:
  //   flutter run --dart-define-from-file=api_keys.json
  static const String defaultAccessKey = String.fromEnvironment('AWS_ACCESS_KEY_ID');
  static const String defaultSecretKey = String.fromEnvironment('AWS_SECRET_ACCESS_KEY');
  static const String defaultRegion = String.fromEnvironment(
    'AWS_REGION',
    defaultValue: 'us-east-1',
  );

  /// False when the app was built without the AWS keys.
  static bool get isConfigured =>
      defaultAccessKey.isNotEmpty && defaultSecretKey.isNotEmpty;

  final String accessKey;
  final String secretKey;
  final String region;
  final Dio _dio;

  AwsRekognitionService({
    this.accessKey = defaultAccessKey,
    this.secretKey = defaultSecretKey,
    this.region = defaultRegion,
    Dio? dio,
  }) : _dio = dio ?? Dio();

  /// Compares faces between two image files (e.g. CNIC photo and Live Selfie).
  Future<AwsCompareResult> compareFaceFiles({
    required File sourceFile,
    required File targetFile,
    double similarityThreshold = 65.0,
  }) async {
    try {
      final sourceBytes = await sourceFile.readAsBytes();
      final targetBytes = await targetFile.readAsBytes();
      return compareFaces(
        sourceBytes: sourceBytes,
        targetBytes: targetBytes,
        similarityThreshold: similarityThreshold,
      );
    } catch (e) {
      return AwsCompareResult.failure('Failed to read image files: $e');
    }
  }

  /// Compares selfie against multiple reference candidates (e.g. full CNIC photo and high-res cropped portrait)
  /// and returns the best matching result.
  Future<AwsCompareResult> compareWithBestReference({
    required List<File> referenceFiles,
    required File targetFile,
    double similarityThreshold = 65.0,
  }) async {
    AwsCompareResult? bestResult;

    for (final refFile in referenceFiles) {
      if (!await refFile.exists()) continue;
      final result = await compareFaceFiles(
        sourceFile: refFile,
        targetFile: targetFile,
        similarityThreshold: similarityThreshold,
      );

      if (result.success) {
        if (bestResult == null || result.similarity > bestResult.similarity) {
          bestResult = result;
        }
        if (result.isMatch) {
          return result;
        }
      } else {
        bestResult ??= result;
      }
    }

    return bestResult ?? AwsCompareResult.failure('No valid reference images found.');
  }

  /// Compares faces between two byte buffers.
  Future<AwsCompareResult> compareFaces({
    required List<int> sourceBytes,
    required List<int> targetBytes,
    double similarityThreshold = 65.0,
  }) async {
    if (accessKey.isEmpty || secretKey.isEmpty) {
      return AwsCompareResult.failure(
        'AWS keys missing: start the app with '
        '--dart-define-from-file=api_keys.json',
      );
    }
    try {
      // Optimize image size to ensure snappy upload (< 1.5MB per image)
      final optimizedSource = _optimizeImageBytes(sourceBytes);
      final optimizedTarget = _optimizeImageBytes(targetBytes);

      final host = 'rekognition.$region.amazonaws.com';
      final endpoint = 'https://$host/';

      final now = DateTime.now().toUtc();
      final year = now.year.toString().padLeft(4, '0');
      final month = now.month.toString().padLeft(2, '0');
      final day = now.day.toString().padLeft(2, '0');
      final hour = now.hour.toString().padLeft(2, '0');
      final minute = now.minute.toString().padLeft(2, '0');
      final second = now.second.toString().padLeft(2, '0');
      final dateStamp = '$year$month$day';
      final amzDate = '${dateStamp}T$hour$minute${second}Z';

      // NOTE: We pass SimilarityThreshold: 0.0 to AWS Rekognition so it never drops
      // legitimate matches. We then apply [similarityThreshold] (default 65.0%) in Dart.
      final payloadMap = {
        'SourceImage': {'Bytes': base64Encode(optimizedSource)},
        'TargetImage': {'Bytes': base64Encode(optimizedTarget)},
        'SimilarityThreshold': 0.0,
      };

      final payloadString = jsonEncode(payloadMap);
      final payloadBytes = utf8.encode(payloadString);
      final payloadHash = sha256.convert(payloadBytes).toString();

      final canonicalHeaders = 'content-type:application/x-amz-json-1.1\n'
          'host:$host\n'
          'x-amz-content-sha256:$payloadHash\n'
          'x-amz-date:$amzDate\n'
          'x-amz-target:RekognitionService.CompareFaces\n';
      const signedHeaders = 'content-type;host;x-amz-content-sha256;x-amz-date;x-amz-target';

      final canonicalRequest = 'POST\n/\n\n$canonicalHeaders\n$signedHeaders\n$payloadHash';
      final canonicalRequestHash = sha256.convert(utf8.encode(canonicalRequest)).toString();

      final credentialScope = '$dateStamp/$region/rekognition/aws4_request';
      final stringToSign = 'AWS4-HMAC-SHA256\n$amzDate\n$credentialScope\n$canonicalRequestHash';

      List<int> hmacSha256(List<int> key, String msg) {
        return Hmac(sha256, key).convert(utf8.encode(msg)).bytes;
      }

      final kSecret = utf8.encode('AWS4$secretKey');
      final kDate = hmacSha256(kSecret, dateStamp);
      final kRegion = hmacSha256(kDate, region);
      final kService = hmacSha256(kRegion, 'rekognition');
      final kSigning = hmacSha256(kService, 'aws4_request');

      final signature = Hmac(sha256, kSigning).convert(utf8.encode(stringToSign)).toString();

      final authHeader = 'AWS4-HMAC-SHA256 Credential=$accessKey/$credentialScope, '
          'SignedHeaders=$signedHeaders, Signature=$signature';

      debugPrint('[AwsRekognition] Sending CompareFaces request to $region...');

      final response = await _dio.post(
        endpoint,
        data: Stream.fromIterable([payloadBytes]),
        options: Options(
          headers: {
            'Host': host,
            'Content-Type': 'application/x-amz-json-1.1',
            'X-Amz-Target': 'RekognitionService.CompareFaces',
            'x-amz-date': amzDate,
            'x-amz-content-sha256': payloadHash,
            'Authorization': authHeader,
            'Content-Length': payloadBytes.length,
          },
          validateStatus: (status) => true,
          sendTimeout: const Duration(seconds: 15),
          receiveTimeout: const Duration(seconds: 15),
        ),
      );

      final statusCode = response.statusCode ?? 0;
      final responseData = response.data;

      Map<String, dynamic> json;
      if (responseData is Map<String, dynamic>) {
        json = responseData;
      } else if (responseData is String) {
        try {
          json = jsonDecode(responseData) as Map<String, dynamic>;
        } catch (_) {
          return AwsCompareResult.failure('Invalid server response ($statusCode): $responseData');
        }
      } else {
        return AwsCompareResult.failure('Unexpected server response type ($statusCode)');
      }

      if (statusCode != 200) {
        final errorType = json['__type'] ?? json['Code'] ?? 'UnknownAWSException';
        final errorMsg = json['message'] ?? json['Message'] ?? 'Unknown error';

        debugPrint('[AwsRekognition] AWS Error ($statusCode): $errorType - $errorMsg');

        if (errorType.toString().contains('InvalidParameterException')) {
          return AwsCompareResult.failure(
            'Chehra wazeh nahi hai ya ID card / selfie mein chehra detect nahi hua.',
          );
        }
        return AwsCompareResult.failure('$errorType: $errorMsg');
      }

      // Successful 200 response
      final faceMatches = json['FaceMatches'] as List<dynamic>? ?? [];
      final unmatchedFaces = json['UnmatchedFaces'] as List<dynamic>? ?? [];

      debugPrint(
        '[AwsRekognition] Success! Matches: ${faceMatches.length}, Unmatched: ${unmatchedFaces.length}',
      );

      if (faceMatches.isNotEmpty) {
        final bestMatch = faceMatches.first as Map<String, dynamic>;
        final similarity = (bestMatch['Similarity'] as num?)?.toDouble() ?? 0.0;
        final isMatched = similarity >= similarityThreshold;

        debugPrint('[AwsRekognition] Best Match Similarity: ${similarity.toStringAsFixed(2)}%');
        if (isMatched) {
          return AwsCompareResult.matched(similarity, json);
        } else {
          return AwsCompareResult.notMatched(similarity, json);
        }
      } else {
        debugPrint('[AwsRekognition] No matching faces found between source and target images.');
        return AwsCompareResult.notMatched(0.0, json);
      }
    } catch (e, stack) {
      debugPrint('[AwsRekognition] Exception during compareFaces: $e\n$stack');
      return AwsCompareResult.failure('AWS Rekognition error: $e');
    }
  }

  /// Downscales image if it exceeds 1600px width/height or 2MB in size.
  List<int> _optimizeImageBytes(List<int> bytes) {
    if (bytes.length < 1024 * 1024) {
      return bytes; // Smaller than 1MB, no resizing needed
    }
    try {
      final decoded = img.decodeImage(Uint8List.fromList(bytes));
      if (decoded == null) return bytes;

      if (decoded.width <= 1600 && decoded.height <= 1600 && bytes.length <= 2 * 1024 * 1024) {
        return bytes;
      }

      final resized = img.copyResize(
        decoded,
        width: decoded.width > decoded.height ? 1600 : null,
        height: decoded.height >= decoded.width ? 1600 : null,
      );
      return img.encodeJpg(resized, quality: 85);
    } catch (e) {
      debugPrint('[AwsRekognition] Image resize warning: $e');
      return bytes;
    }
  }
}
