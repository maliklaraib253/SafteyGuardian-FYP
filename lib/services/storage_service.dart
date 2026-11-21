import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:firebase_storage/firebase_storage.dart';

class StorageService {
  final FirebaseStorage _storage = FirebaseStorage.instance;

  // Upload single image for incident reports
  Future<String?> uploadImage(File image, String userId) async {
    try {
      String fileName = '$userId/${DateTime.now().millisecondsSinceEpoch}.jpg';
      Reference ref = _storage.ref().child('reports/$fileName');
      await ref.putFile(image);
      String url = await ref.getDownloadURL();
      return url;
    } catch (e) {
      debugPrint('Upload error: $e');
      return null;
    }
  }

  // Upload multiple images
  Future<List<String>> uploadImages(List<File> images, String userId) async {
    List<String> urls = [];
    for (File image in images) {
      String? url = await uploadImage(image, userId);
      if (url != null) {
        urls.add(url);
      }
    }
    return urls;
  }

  // Upload private identity document (CNIC) to protected path
  Future<String?> uploadIdentityDocument(File file, String userId) async {
    try {
      String fileName = 'cnic_ref_${DateTime.now().millisecondsSinceEpoch}.jpg';
      Reference ref = _storage.ref().child('users/$userId/identity/$fileName');
      await ref.putFile(
        file,
        SettableMetadata(
          contentType: 'image/jpeg',
          customMetadata: {'userId': userId, 'category': 'identity'},
        ),
      );
      return await ref.getDownloadURL();
    } catch (e) {
      debugPrint('Identity upload error: $e');
      return null;
    }
  }
}