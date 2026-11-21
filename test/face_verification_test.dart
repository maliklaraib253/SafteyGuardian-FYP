import 'dart:math';
import 'package:flutter_test/flutter_test.dart';
import 'package:safety_guardian/services/face_service.dart';
import 'package:safety_guardian/services/face_verification_config.dart';

void main() {
  group('FaceVerificationConfig Tests', () {
    test('Config parameters are initialized within sensible security limits', () {
      expect(FaceVerificationConfig.matchThreshold, greaterThanOrEqualTo(0.65));
      expect(FaceVerificationConfig.matchThreshold, lessThanOrEqualTo(0.85));
      expect(FaceVerificationConfig.minFaceDimension, greaterThan(20));
      expect(FaceVerificationConfig.livenessYawThreshold, greaterThan(5.0));
      expect(FaceVerificationConfig.identitySubcollection, equals('identity'));
      expect(FaceVerificationConfig.identityDocId, equals('reference'));
    });
  });

  group('FaceService Biometric Similarity Tests', () {
    List<double> generateMockUnitVector(int seed, {double perturbation = 0.0}) {
      final random = Random(seed);
      final List<double> vec = [];
      for (int i = 0; i < 128; i++) {
        double val = random.nextDouble() * 2.0 - 1.0;
        if (perturbation > 0.0) {
          val += (Random().nextDouble() * 2.0 - 1.0) * perturbation;
        }
        vec.add(val);
      }
      // Normalize to unit length
      double normSq = 0.0;
      for (final v in vec) {
        normSq += v * v;
      }
      final norm = sqrt(normSq);
      return vec.map((v) => v / norm).toList();
    }

    test('Identical face embeddings produce similarity score of 1.0 (VERIFIED)', () {
      final embeddingA = generateMockUnitVector(42);
      final embeddingB = List<double>.from(embeddingA);

      final similarity = FaceService.compareEmbeddings(embeddingA, embeddingB);
      expect(similarity, closeTo(1.0, 0.001));
      expect(similarity >= FaceVerificationConfig.matchThreshold, isTrue);
    });

    test('Same person with minor lighting/angle variation is VERIFIED', () {
      final embeddingA = generateMockUnitVector(100);
      // Small perturbation simulating natural variation of same person
      final embeddingSamePerson = generateMockUnitVector(100, perturbation: 0.15);

      final similarity = FaceService.compareEmbeddings(embeddingA, embeddingSamePerson);
      expect(similarity, greaterThan(FaceVerificationConfig.matchThreshold));
    });

    test('Different individuals produce similarity below threshold (FAILED/REJECTED)', () {
      final person1 = generateMockUnitVector(101);
      final person2 = generateMockUnitVector(999); // completely different individual

      final similarity = FaceService.compareEmbeddings(person1, person2);
      expect(similarity, lessThan(FaceVerificationConfig.matchThreshold));
    });

    test('Orthogonal embeddings produce 0.0 similarity', () {
      final vecA = List<double>.filled(128, 0.0);
      final vecB = List<double>.filled(128, 0.0);
      vecA[0] = 1.0;
      vecB[1] = 1.0;

      final similarity = FaceService.compareEmbeddings(vecA, vecB);
      expect(similarity, equals(0.0));
      expect(similarity >= FaceVerificationConfig.matchThreshold, isFalse);
    });

    test('Invalid or empty vectors gracefully yield 0.0 similarity', () {
      expect(FaceService.compareEmbeddings([], []), equals(0.0));
      expect(FaceService.compareEmbeddings([1.0, 0.0], [1.0]), equals(0.0));
    });
  });
}
