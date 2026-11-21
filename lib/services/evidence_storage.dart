import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:flutter/foundation.dart';
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
