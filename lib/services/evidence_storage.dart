import 'dart:io';
import 'dart:typed_data';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:dio/dio.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart' show ValueNotifier;
import 'package:image_picker/image_picker.dart';

/// Uploads report evidence and verification selfies.
///
/// Private mode (Firebase Storage): turned on by adding
///   "USE_FIREBASE_STORAGE": "true"
/// to api_keys.json once the project is on the Blaze plan and storage.rules
/// are published. Pictures go to reports/{uid}/... and the report stores the
/// gs:// address, so only the reporter, police and admins can open them.
///
/// Default (free plan): pictures go to ImgBB as before. If private mode is on
/// but Storage fails, it also falls back to ImgBB so reporting never breaks.
class EvidenceStorage {
  EvidenceStorage._();

  static const String _imgbbApiKey = String.fromEnvironment('IMGBB_API_KEY');
  static const bool useFirebaseStorage = bool.fromEnvironment(
    'USE_FIREBASE_STORAGE',
  );

  static Future<String?> upload(
    XFile file,
    String uid, {
    String folder = 'evidence',
  }) async {
    if (!useFirebaseStorage) return _uploadToImgBB(file);
    try {
      final bytes = await file.readAsBytes();
      final name =
          '${DateTime.now().millisecondsSinceEpoch}_${bytes.length % 100000}.jpg';
      final ref = FirebaseStorage.instance.ref('reports/$uid/$folder/$name');
      await ref
          .putData(
            bytes,
            SettableMetadata(
              contentType: 'image/jpeg',
              customMetadata: {'owner': uid, 'kind': folder},
            ),
          )
          .timeout(const Duration(seconds: 25));
      return 'gs://${ref.bucket}/${ref.fullPath}';
    } catch (e) {
      debugPrint('[EvidenceStorage] Firebase Storage upload failed: $e');
      return _uploadToImgBB(file);
    }
  }

  static Future<String?> _uploadToImgBB(XFile file) async {
    if (_imgbbApiKey.isEmpty) {
      debugPrint(
        '[EvidenceStorage] IMGBB_API_KEY missing: run with '
        '--dart-define-from-file=api_keys.json',
      );
      return null;
    }
    try {
      final bytes = await file.readAsBytes();
      final form = FormData.fromMap({
        'image': MultipartFile.fromBytes(bytes, filename: file.name),
      });
      final res = await Dio()
          .post('https://api.imgbb.com/1/upload?key=$_imgbbApiKey', data: form)
          .timeout(const Duration(seconds: 40));
      if (res.statusCode == 200) return res.data['data']['url'] as String?;
    } catch (e) {
      debugPrint('[EvidenceStorage] ImgBB fallback failed: $e');
    }
    return null;
  }

  // ---------------------------------------------------------------- videos

  static const String _cloudName = String.fromEnvironment(
    'CLOUDINARY_CLOUD_NAME',
  );
  static const String _uploadPreset = String.fromEnvironment(
    'CLOUDINARY_UPLOAD_PRESET',
  );

  /// Largest video accepted (free Cloudinary accounts allow 100 MB).
  static const int maxVideoBytes = 100 * 1024 * 1024;

  /// Whether a place to upload videos is set up.
  static bool get canUploadVideos =>
      useFirebaseStorage || (_cloudName.isNotEmpty && _uploadPreset.isNotEmpty);

  /// Uploads a video recorded with Evidence Capture (or any gallery video).
  /// Private Firebase Storage when enabled, otherwise Cloudinary (free plan,
  /// unsigned upload preset). [onProgress] gets 0..1.
  static Future<String?> uploadVideo(
    XFile file,
    String uid, {
    void Function(double)? onProgress,
  }) async {
    final size = await file.length();
    if (size > maxVideoBytes) {
      debugPrint('[EvidenceStorage] video too large: $size bytes');
      return null;
    }
    if (useFirebaseStorage) {
      try {
        final ref = FirebaseStorage.instance.ref(
          'reports/$uid/video/${DateTime.now().millisecondsSinceEpoch}.mp4',
        );
        final task = ref.putFile(
          File(file.path),
          SettableMetadata(
            contentType: 'video/mp4',
            customMetadata: {'owner': uid, 'kind': 'video'},
          ),
        );
        task.snapshotEvents.listen((s) {
          if (s.totalBytes > 0)
            onProgress?.call(s.bytesTransferred / s.totalBytes);
        });
        await task;
        return 'gs://${ref.bucket}/${ref.fullPath}';
      } catch (e) {
        debugPrint('[EvidenceStorage] video to Firebase Storage failed: $e');
      }
    }
    if (_cloudName.isEmpty || _uploadPreset.isEmpty) {
      debugPrint(
        '[EvidenceStorage] no video host: add CLOUDINARY_CLOUD_NAME and '
        'CLOUDINARY_UPLOAD_PRESET to api_keys.json',
      );
      return null;
    }
    try {
      final form = FormData.fromMap({
        'file': await MultipartFile.fromFile(file.path, filename: file.name),
        'upload_preset': _uploadPreset,
        'folder': 'safetyguardian/reports',
      });
      final res = await Dio().post(
        'https://api.cloudinary.com/v1_1/$_cloudName/video/upload',
        data: form,
        onSendProgress: (sent, total) {
          if (total > 0) onProgress?.call(sent / total);
        },
      );
      return res.data['secure_url'] as String?;
    } catch (e) {
      debugPrint('[EvidenceStorage] Cloudinary video upload failed: $e');
      return null;
    }
  }

  /// Progress text for background video uploads (null when idle).
  static final ValueNotifier<String?> videoStatus = ValueNotifier(null);

  /// Uploads a report's videos after the report is saved and adds each link
  /// to the report as soon as it is ready, so police see the first video
  /// without waiting for the rest.
  static Future<void> uploadReportVideos(
    DocumentReference<Map<String, dynamic>> report,
    List<XFile> videos,
    String uid,
  ) async {
    var done = 0;
    var failed = 0;
    for (var i = 0; i < videos.length; i++) {
      final label = 'Uploading video ${i + 1} of ${videos.length}';
      videoStatus.value = '$label...';
      final url = await uploadVideo(
        videos[i],
        uid,
        onProgress: (p) => videoStatus.value = '$label (${(p * 100).round()}%)',
      );
      try {
        await report.update({
          if (url != null) 'videos': FieldValue.arrayUnion([url]),
          'videosPending': FieldValue.increment(-1),
        });
      } catch (e) {
        debugPrint('[EvidenceStorage] saving video link failed: $e');
      }
      if (url != null) {
        done++;
      } else {
        failed++;
      }
    }
    try {
      await report.update({'videosPending': FieldValue.delete()});
    } catch (_) {}
    videoStatus.value = failed == 0
        ? '✓ ${done == 1 ? 'Video' : '$done videos'} uploaded.'
        : '✓ $done uploaded, $failed failed (check the internet connection).';
  }

  /// A link the phone can open for a stored video.
  static Future<String?> playableUrl(String src) async {
    if (!src.startsWith('gs://')) return src;
    try {
      return await FirebaseStorage.instance.refFromURL(src).getDownloadURL();
    } catch (e) {
      debugPrint('[EvidenceStorage] video link failed: $e');
      return null;
    }
  }

  // Downloaded pictures are kept in memory so lists don't download twice.
  static final Map<String, Future<Uint8List?>> _cache = {};

  /// Bytes of a gs:// picture, downloaded with the signed-in user's rights.
  static Future<Uint8List?> load(String gsUrl) {
    return _cache.putIfAbsent(gsUrl, () async {
      try {
        return await FirebaseStorage.instance
            .refFromURL(gsUrl)
            .getData(15 * 1024 * 1024);
      } catch (e) {
        debugPrint('[EvidenceStorage] download failed: $e');
        _cache.remove(gsUrl);
        return null;
      }
    });
  }

  /// Deletes a stored picture (used when an admin deletes a report).
  static Future<void> delete(String url) async {
    if (!url.startsWith('gs://')) return;
    try {
      await FirebaseStorage.instance.refFromURL(url).delete();
    } catch (e) {
      debugPrint('[EvidenceStorage] delete failed: $e');
    }
  }
}
