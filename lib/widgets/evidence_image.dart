import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../services/evidence_storage.dart';

/// Shows a report picture from either protected Firebase Storage (gs://, new
/// reports) or a normal web link (older reports).
class EvidenceImage extends StatelessWidget {
  final String src;
  final double? width;
  final double? height;
  final BoxFit fit;
  final Color placeholderColor;

  const EvidenceImage(
    this.src, {
    super.key,
    this.width,
    this.height,
    this.fit = BoxFit.cover,
    this.placeholderColor = const Color(0xFFE2E8F0),
  });

  Widget _box(Widget child) => Container(
    width: width,
    height: height,
    color: placeholderColor,
    alignment: Alignment.center,
    child: child,
  );

  Widget _broken() => _box(const Icon(Icons.broken_image, color: Colors.grey));

  @override
  Widget build(BuildContext context) {
    if (!src.startsWith('gs://')) {
      return Image.network(
        src,
        width: width,
        height: height,
        fit: fit,
        errorBuilder: (_, _, _) => _broken(),
      );
    }
    return FutureBuilder<Uint8List?>(
      future: EvidenceStorage.load(src),
      builder: (context, snap) {
        if (snap.connectionState != ConnectionState.done) {
          return _box(
            const SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
          );
        }
        final bytes = snap.data;
        if (bytes == null || bytes.isEmpty) return _broken();
        return Image.memory(
          bytes,
          width: width,
          height: height,
          fit: fit,
          errorBuilder: (_, _, _) => _broken(),
        );
      },
    );
  }
}
