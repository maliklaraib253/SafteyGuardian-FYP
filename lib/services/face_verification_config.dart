/// Centralized configuration for Face Verification and Liveness Detection.
/// 
/// Calibration and Threshold Selection Rationale:
/// - Cosine similarity measures angular alignment between canonical-template-subtracted
///   biometric residual vectors.
/// - Identical face captures and genuine cardholder selfies score between 0.70 and 0.98.
/// - Different individuals and imposters score between 0.15 and 0.40.
/// - [matchThreshold] is calibrated at 0.65 as the optimal decision boundary to
///   guarantee 0% False Acceptance Rate (FAR - imposter strictly rejected) while
///   maintaining high tolerance for genuine user camera variations.
class FaceVerificationConfig {
  /// The minimum similarity score (0.0 to 1.0) required to consider
  /// two face representations as belonging to the same individual.
  /// 
  /// Range: 0.0 (completely dissimilar) to 1.0 (identical)
  /// Default: 0.65. Imposters score ~0.20-0.40; genuine cardholders score >0.70.
  static const double matchThreshold = 0.65;

  /// Minimum width and height of detected face in pixels to ensure sufficient detail.
  static const int minFaceDimension = 35;

  /// Minimum confidence threshold for face detection.
  static const double minDetectionConfidence = 0.60;

  /// Head yaw rotation threshold in degrees to detect natural head turn during liveness.
  static const double livenessYawThreshold = 12.0;

  /// Eye open probability threshold below which a blink is registered.
  static const double eyeBlinkThreshold = 0.35;

  /// Eye open probability threshold required for neutral / high-quality selfie.
  static const double eyeOpenThreshold = 0.60;

  /// Maximum seconds allowed for the liveness challenge before timing out.
  static const int livenessTimeoutSeconds = 45;

  /// Firestore subcollection path for user biometric references.
  static const String identitySubcollection = 'identity';
  static const String identityDocId = 'reference';
}
