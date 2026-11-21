import 'dart:io';
import 'dart:math' as math;

import 'dart:ui' show Rect;

import 'package:flutter/foundation.dart';
import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';
import 'package:image/image.dart' as img;
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';

import 'aws_rekognition_service.dart';
import 'face_service.dart';

/// Result of running face blurring on one photo.
class FaceBlurResult {
  final XFile file;
  final int facesFound;
  final bool processed;

  const FaceBlurResult({
    required this.file,
    required this.facesFound,
    required this.processed,
  });
}

/// Detects faces on-device with ML Kit and blurs them (pixelate + gaussian
/// blur inside an oval) before a photo leaves the phone.
class FaceBlurService {
  static final FaceDetector _detector = FaceDetector(
    options: FaceDetectorOptions(
      performanceMode: FaceDetectorMode.accurate,
      minFaceSize: 0.05, // also catch small faces in the background
    ),
  );

  /// Backwards-compatible helper: returns only the (possibly blurred) file.
  static Future<XFile> blurFaces(XFile input) async {
    final result = await blurFacesWithResult(input);
    return result.file;
  }

  /// Blurs every detected face. Returns the original file when no face is
  /// found or processing fails, so callers can always upload `result.file`.
  static Future<FaceBlurResult> blurFacesWithResult(XFile input) async {
    try {
      final faces = await _detector.processImage(
        InputImage.fromFilePath(input.path),
      );
      if (faces.isEmpty) {
        return FaceBlurResult(file: input, facesFound: 0, processed: true);
      }

      final rects = <double>[];
      for (final f in faces) {
        final b = f.boundingBox;
        rects.addAll([b.left, b.top, b.width, b.height]);
      }

      final bytes = await input.readAsBytes();
      // Heavy pixel work runs in a background isolate so the UI stays smooth.
      final Uint8List? out = await compute(_blurInIsolate, _BlurJob(bytes, rects));
      if (out == null) {
        return FaceBlurResult(file: input, facesFound: faces.length, processed: false);
      }

      final dir = await getTemporaryDirectory();
      final path = '${dir.path}/blurred_${DateTime.now().microsecondsSinceEpoch}.jpg';
      await File(path).writeAsBytes(out);
      return FaceBlurResult(file: XFile(path), facesFound: faces.length, processed: true);
    } catch (e) {
      debugPrint('[FaceBlurService] blur failed: $e');
      return FaceBlurResult(file: input, facesFound: 0, processed: false);
    }
  }
}

/// Result of blurring the account owner's face in one evidence photo.
class OwnerBlurResult {
  /// File to upload: the blurred copy, or the untouched original.
  final XFile file;

  /// Number of faces seen in the photo.
  final int facesInPhoto;

  /// True when the owner's face was found and blurred.
  final bool ownerBlurred;

  /// False when the check could not run at all.
  final bool checked;

  /// Short human-readable explanation (shown under the preview thumbnail).
  final String detail;

  const OwnerBlurResult({
    required this.file,
    required this.facesInPhoto,
    required this.ownerBlurred,
    required this.checked,
    this.detail = '',
  });
}

/// Blurs only the account owner's face in evidence photos.
class OwnerFaceBlur {
  OwnerFaceBlur._();

  /// AWS similarity (%) needed to treat a face as the owner. Same person is
  /// usually 95-100%; an old CNIC photo vs today's face can be ~75-90%.
  static const double _awsMatchThreshold = 70.0;

  /// On-device similarity needed when there is only one face in the photo.
  static const double _localSingleThreshold = 0.55;

  /// On-device: with 2+ faces, the best face is the owner if it beats the
  /// runner-up by this margin and reaches [_localMinScore].
  static const double _localMargin = 0.12;
  static const double _localMinScore = 0.35;

  /// Turns reference pictures of the owner (verification selfie, CNIC photo)
  /// into upright, resized JPEG bytes ONCE, so they can be reused for every
  /// evidence photo without re-reading or re-encoding them.
  static Future<List<Uint8List>> prepareReferences(List<File> files) async {
    final out = <Uint8List>[];
    for (final f in files) {
      try {
        if (!await f.exists()) continue;
        final prepared = await compute(_prepareUpright, await f.readAsBytes());
        if (prepared != null) out.add(prepared.bytes);
      } catch (e) {
        debugPrint('[OwnerBlur] could not prepare reference ${f.path}: $e');
      }
    }
    return out;
  }

  /// Runs [blurOwnerFace] on all [photos] in parallel (max 3 at a time).
  static Future<List<OwnerBlurResult>> blurOwnerFaceInAll(
    List<XFile> photos, {
    required List<Uint8List> ownerReferences,
    List<double>? ownerEmbedding,
  }) async {
    final results = List<OwnerBlurResult?>.filled(photos.length, null);
    for (var start = 0; start < photos.length; start += 3) {
      final end = (start + 3).clamp(0, photos.length);
      await Future.wait([
        for (var i = start; i < end; i++)
          blurOwnerFace(
            photos[i],
            ownerReferences: ownerReferences,
            ownerEmbedding: ownerEmbedding,
          ).then((r) => results[i] = r),
      ]);
    }
    return results.cast<OwnerBlurResult>();
  }

  /// Blurs ONLY the account owner's face in [evidence]; every other face is
  /// left exactly as it was.
  ///
  /// [ownerReferences]: prepared pictures of the owner (see
  /// [prepareReferences]). Each is compared with the evidence photo through
  /// AWS Rekognition CompareFaces, and every face that matches any reference
  /// is blurred. If AWS cannot be reached, the on-device embeddings of the
  /// detected faces are compared with [ownerEmbedding] instead.
  static Future<OwnerBlurResult> blurOwnerFace(
    XFile evidence, {
    required List<Uint8List> ownerReferences,
    List<double>? ownerEmbedding,
  }) async {
    try {
      final original = await evidence.readAsBytes();
      // Upright (EXIF rotation baked in), max 1600px. AWS boxes, ML Kit boxes
      // and the blur all use these same pixels.
      final prepared = await compute(_prepareUpright, original);
      if (prepared == null) {
        return OwnerBlurResult(
          file: evidence,
          facesInPhoto: 0,
          ownerBlurred: false,
          checked: false,
          detail: 'Could not read photo',
        );
      }

      final dir = await getTemporaryDirectory();
      final stamp =
          '${DateTime.now().microsecondsSinceEpoch}_${evidence.path.hashCode.abs()}';
      final preparedFile = File('${dir.path}/evidence_upright_$stamp.jpg');
      await preparedFile.writeAsBytes(prepared.bytes, flush: true);

      final faces = await FaceBlurService._detector.processImage(
        InputImage.fromFilePath(preparedFile.path),
      );
      debugPrint('[OwnerBlur] ${faces.length} face(s) in evidence photo');

      final boxes = <Rect>[];
      bool awsWorked = false;
      double bestAws = 0;
      String? awsError;

      // 1. Cloud match against every reference picture of the owner.
      for (var refIndex = 0; refIndex < ownerReferences.length; refIndex++) {
        final ref = ownerReferences[refIndex];
        // Ask AWS for every face down to 40% so the preview can show how
        // close the best face was; only faces >= _awsMatchThreshold are
        // treated as the owner.
        final aws = await AwsRekognitionService().compareFaces(
          sourceBytes: ref,
          targetBytes: prepared.bytes,
          similarityThreshold: 40,
        );
        if (!aws.success) {
          awsError = aws.errorMessage;
          debugPrint('[OwnerBlur] AWS failed for reference $refIndex: ${aws.errorMessage}');
          // "Chehra..." = InvalidParameter: no face found by AWS. That is a
          // real answer, not an outage.
          if ((aws.errorMessage ?? '').contains('Chehra')) awsWorked = true;
          continue;
        }
        awsWorked = true;
        final matches = (aws.rawData?['FaceMatches'] as List?) ?? const [];
        for (final m in matches) {
          final sim = ((m as Map)['Similarity'] as num?)?.toDouble() ?? 0;
          if (sim > bestAws) bestAws = sim;
          final box = (m['Face'] as Map?)?['BoundingBox'] as Map?;
          if (sim < _awsMatchThreshold || box == null) continue;
          boxes.add(Rect.fromLTWH(
            ((box['Left'] as num?) ?? 0).toDouble() * prepared.width,
            ((box['Top'] as num?) ?? 0).toDouble() * prepared.height,
            ((box['Width'] as num?) ?? 0).toDouble() * prepared.width,
            ((box['Height'] as num?) ?? 0).toDouble() * prepared.height,
          ));
        }
        debugPrint('[OwnerBlur] AWS best match ${bestAws.toStringAsFixed(1)}% (${matches.length} compared)');
      }

      String detail;
      // 2. On-device fallback when AWS could not be used.
      if (!awsWorked) {
        debugPrint('[OwnerBlur] cloud check unavailable: $awsError');
        if (ownerEmbedding == null || faces.isEmpty) {
          detail = faces.isEmpty
              ? 'No faces found'
              : 'Face check unavailable (${awsError ?? 'no reference'})';
        } else {
          final scored = <MapEntry<Face, double>>[];
          for (final f in faces) {
            final emb = await FaceService.embeddingForFace(prepared.bytes, f);
            scored.add(MapEntry(f, FaceService.compareEmbeddings(ownerEmbedding, emb)));
          }
          scored.sort((a, b) => b.value.compareTo(a.value));
          final best = scored.first;
          final runnerUp = scored.length > 1 ? scored[1].value : -1.0;
          final isOwner = scored.length == 1
              ? best.value >= _localSingleThreshold
              : best.value >= _localMinScore && best.value - runnerUp >= _localMargin;
          debugPrint('[OwnerBlur] on-device best ${best.value.toStringAsFixed(2)}, runner-up ${runnerUp.toStringAsFixed(2)}');
          if (isOwner) boxes.add(best.key.boundingBox);
          detail = isOwner
              ? 'Matched on device (${(best.value * 100).round()}%)'
              : 'Cloud check failed, phone check: no match '
                    '(best ${(best.value * 100).round()}%). ${awsError ?? ''}';
        }
      } else {
        detail = boxes.isNotEmpty
            ? 'Matched you (${bestAws.toStringAsFixed(0)}%)'
            : (faces.isEmpty && bestAws == 0
                ? 'No faces found'
                : 'You are not in this photo (best ${bestAws.toStringAsFixed(0)}%)');
      }

      // Drop duplicate boxes (selfie and CNIC matching the same face).
      final unique = <Rect>[];
      for (final r in boxes) {
        final dup = unique.any((u) {
          final i = u.intersect(r);
          if (i.width <= 0 || i.height <= 0) return false;
          return i.width * i.height > 0.5 * r.width * r.height;
        });
        if (!dup) unique.add(r);
      }

      if (unique.isEmpty) {
        try {
          await preparedFile.delete();
        } catch (_) {}
        return OwnerBlurResult(
          file: evidence,
          facesInPhoto: faces.length,
          ownerBlurred: false,
          // Only a cloud (AWS) answer counts as a real check; the phone-only
          // fallback is too weak to say "you are not in this photo".
          checked: awsWorked,
          detail: detail,
        );
      }

      final rects = <double>[
        for (final r in unique) ...[r.left, r.top, r.width, r.height],
      ];
      final out = await compute(_blurInIsolate, _BlurJob(prepared.bytes, rects));
      if (out == null) {
        return OwnerBlurResult(
          file: evidence,
          facesInPhoto: faces.length,
          ownerBlurred: false,
          checked: false,
          detail: 'Blur failed',
        );
      }
      final path = '${dir.path}/owner_blurred_$stamp.jpg';
      await File(path).writeAsBytes(out, flush: true);
      try {
        await preparedFile.delete();
      } catch (_) {}
      return OwnerBlurResult(
        file: XFile(path),
        facesInPhoto: faces.isEmpty ? unique.length : faces.length,
        ownerBlurred: true,
        checked: true,
        detail: detail,
      );
    } catch (e) {
      debugPrint('[OwnerBlur] failed: $e');
      return OwnerBlurResult(
        file: evidence,
        facesInPhoto: 0,
        ownerBlurred: false,
        checked: false,
        detail: 'Error: $e',
      );
    }
  }
}

class _Upright {
  final Uint8List bytes;
  final int width;
  final int height;
  const _Upright(this.bytes, this.width, this.height);
}

_Upright? _prepareUpright(Uint8List bytes) {
  img.Image? image = img.decodeImage(bytes);
  if (image == null) return null;
  image = img.bakeOrientation(image);
  const maxSide = 1600;
  if (image.width > maxSide || image.height > maxSide) {
    image = img.copyResize(
      image,
      width: image.width >= image.height ? maxSide : null,
      height: image.height > image.width ? maxSide : null,
    );
  }
  return _Upright(
    Uint8List.fromList(img.encodeJpg(image, quality: 90)),
    image.width,
    image.height,
  );
}

class _BlurJob {
  final Uint8List bytes;
  final List<double> rects; // [left, top, width, height] * n
  const _BlurJob(this.bytes, this.rects);
}

Uint8List? _blurInIsolate(_BlurJob job) {
  img.Image? image = img.decodeImage(job.bytes);
  if (image == null) return null;
  image = img.bakeOrientation(image);

  for (var i = 0; i + 3 < job.rects.length; i += 4) {
    final left = job.rects[i];
    final top = job.rects[i + 1];
    final width = job.rects[i + 2];
    final height = job.rects[i + 3];

    // Pad the box so hair, ears and chin are covered as well.
    final padX = width * 0.25;
    final padY = height * 0.30;
    final x1 = (left - padX).clamp(0, image.width - 1).toInt();
    final y1 = (top - padY).clamp(0, image.height - 1).toInt();
    final x2 = (left + width + padX).clamp(0, image.width - 1).toInt();
    final y2 = (top + height + padY).clamp(0, image.height - 1).toInt();
    final w = x2 - x1;
    final h = y2 - y1;
    if (w < 4 || h < 4) continue;

    // Strong, irreversible blur: pixelate first, then smooth the blocks.
    var region = img.copyCrop(image, x: x1, y: y1, width: w, height: h);
    region = img.pixelate(region, size: math.max(6, w ~/ 10));
    region = img.gaussianBlur(region, radius: math.max(4, w ~/ 14));

    // Paste back inside an oval with a soft edge.
    final cx = w / 2, cy = h / 2;
    final rx = w / 2, ry = h / 2;
    for (var y = 0; y < h; y++) {
      for (var x = 0; x < w; x++) {
        final dx = (x - cx) / rx;
        final dy = (y - cy) / ry;
        final d = dx * dx + dy * dy;
        if (d > 1.0) continue;
        final src = region.getPixel(x, y);
        if (d < 0.85) {
          image.setPixel(x1 + x, y1 + y, src);
        } else {
          // Feather the outer 15% of the oval.
          final t = ((1.0 - d) / 0.15).clamp(0.0, 1.0);
          final dst = image.getPixel(x1 + x, y1 + y);
          image.setPixelRgb(
            x1 + x,
            y1 + y,
            (src.r * t + dst.r * (1 - t)).round(),
            (src.g * t + dst.g * (1 - t)).round(),
            (src.b * t + dst.b * (1 - t)).round(),
          );
        }
      }
    }
  }

  return Uint8List.fromList(img.encodeJpg(image, quality: 88));
}
