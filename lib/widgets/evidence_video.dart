import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../services/evidence_storage.dart';

/// Video evidence on a report: a row of tiles that open each video in the
/// phone's video player or browser.
class EvidenceVideos extends StatelessWidget {
  final List<String> videos;
  final Color background;
  final Color foreground;

  /// Videos still being uploaded by the reporter's phone.
  final int pending;

  const EvidenceVideos(
    this.videos, {
    super.key,
    this.pending = 0,
    this.background = const Color(0xFFE2E8F0),
    this.foreground = const Color(0xFF0F172A),
  });

  static List<String> fromReport(Map<String, dynamic> r) => r['videos'] is List
      ? (r['videos'] as List).map((e) => e.toString()).toList()
      : const <String>[];

  static int pendingOf(Map<String, dynamic> r) {
    final p = r['videosPending'];
    return p is num && p > 0 ? p.toInt() : 0;
  }

  /// Whether a report has videos to show (or on the way).
  static bool has(Map<String, dynamic> r) =>
      fromReport(r).isNotEmpty || pendingOf(r) > 0;

  /// The video section for a report.
  static EvidenceVideos forReport(
    Map<String, dynamic> r, {
    Color background = const Color(0xFFE2E8F0),
    Color foreground = const Color(0xFF0F172A),
  }) => EvidenceVideos(
    fromReport(r),
    pending: pendingOf(r),
    background: background,
    foreground: foreground,
  );

  Future<void> _open(BuildContext context, String src) async {
    final messenger = ScaffoldMessenger.of(context);
    final url = await EvidenceStorage.playableUrl(src);
    final ok =
        url != null &&
        await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
    if (!ok) {
      messenger.showSnackBar(
        const SnackBar(content: Text("Couldn't open the video.")),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    if (videos.isEmpty && pending == 0) return const SizedBox.shrink();
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        for (var i = 0; i < videos.length; i++)
          Material(
            color: background,
            borderRadius: BorderRadius.circular(12),
            child: InkWell(
              borderRadius: BorderRadius.circular(12),
              onTap: () => _open(context, videos[i]),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 12,
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.play_circle_fill, color: foreground, size: 26),
                    const SizedBox(width: 8),
                    Text(
                      'Video ${i + 1}',
                      style: TextStyle(
                        color: foreground,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        for (var i = 0; i < pending; i++)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            decoration: BoxDecoration(
              color: background.withValues(alpha: 0.6),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: foreground,
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  'Uploading video...',
                  style: TextStyle(color: foreground.withValues(alpha: 0.8)),
                ),
              ],
            ),
          ),
      ],
    );
  }
}
