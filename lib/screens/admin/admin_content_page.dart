import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';

import '../../services/admin_access.dart';
import '../../theme/app_theme.dart';
import 'admin_widgets.dart';

/// Extra Legal Resource Hub content (law guides and self-defence videos)
/// stored in `app_content/legal_hub`. The app shows these after its built-in
/// items, so new material can be published without releasing a new version.
class AdminContentPage extends StatefulWidget {
  const AdminContentPage({super.key});

  static DocumentReference<Map<String, dynamic>> get doc =>
      FirebaseFirestore.instance.collection('app_content').doc('legal_hub');

  static const categories = [
    'Rights',
    'Complaints',
    'Self-Defense',
    'Evidence',
    'Laws',
  ];

  static const levels = ['Beginner', 'Intermediate', 'Advanced'];

  @override
  State<AdminContentPage> createState() => _AdminContentPageState();
}

class _AdminContentPageState extends State<AdminContentPage> {
  List<Map<String, dynamic>> _list(Map<String, dynamic>? d, String key) {
    final raw = d?[key];
    if (raw is! List) return [];
    return raw
        .whereType<Map>()
        .map((e) => Map<String, dynamic>.from(e))
        .toList();
  }

  Future<void> _save(
    String key,
    List<Map<String, dynamic>> items,
    String action,
    String title,
  ) async {
    try {
      await AdminContentPage.doc.set({
        key: items,
        'updatedAt': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));
      await AdminAccess.log(action, target: title);
      if (mounted)
        adminToast(
          context,
          'Saved. Users see it next time they open the Legal Hub.',
        );
    } catch (e) {
      if (mounted) adminToast(context, adminErrorText(e), error: true);
    }
  }

  Future<void> _editGuide(List<Map<String, dynamic>> all, [int? index]) async {
    final result = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (_) => _GuideDialog(initial: index == null ? null : all[index]),
    );
    if (result == null) return;
    final items = [...all];
    if (index == null) {
      items.add(result);
    } else {
      items[index] = result;
    }
    await _save(
      'guides',
      items,
      index == null ? 'Added legal guide' : 'Edited legal guide',
      result['title'].toString(),
    );
  }

  Future<void> _editVideo(List<Map<String, dynamic>> all, [int? index]) async {
    final result = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (_) => _VideoDialog(initial: index == null ? null : all[index]),
    );
    if (result == null) return;
    final items = [...all];
    if (index == null) {
      items.add(result);
    } else {
      items[index] = result;
    }
    await _save(
      'videos',
      items,
      index == null ? 'Added self-defence video' : 'Edited self-defence video',
      result['title'].toString(),
    );
  }

  Future<void> _remove(
    String key,
    List<Map<String, dynamic>> all,
    int index,
  ) async {
    final title = (all[index]['title'] ?? '').toString();
    final ok = await adminConfirm(
      context,
      title: 'Remove item',
      message: 'Remove "$title" from the Legal Hub?',
      confirmLabel: 'Remove',
      danger: true,
    );
    if (!ok) return;
    final items = [...all]..removeAt(index);
    await _save(
      key,
      items,
      key == 'guides' ? 'Removed legal guide' : 'Removed self-defence video',
      title,
    );
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
      stream: AdminContentPage.doc.snapshots(),
      builder: (context, snap) {
        if (snap.hasError) return AdminError(error: snap.error);
        if (!snap.hasData) {
          return const Center(child: CircularProgressIndicator());
        }
        final data = snap.data!.data();
        final guides = _list(data, 'guides');
        final videos = _list(data, 'videos');
        return ListView(
          padding: const EdgeInsets.all(16),
          children: [
            const AdminCard(
              child: Text(
                'Items added here appear in the citizen app\'s Legal Resource '
                'Hub after the built-in guides and techniques.',
                style: TextStyle(color: AppColors.textMuted),
              ),
            ),
            const SizedBox(height: 16),
            _header('Legal guides', Icons.gavel, () => _editGuide(guides)),
            if (guides.isEmpty) _none('No extra guides yet.'),
            for (var i = 0; i < guides.length; i++)
              _itemTile(
                icon: Icons.description_outlined,
                title: (guides[i]['title'] ?? '').toString(),
                subtitle:
                    '${guides[i]['category'] ?? ''} · ${guides[i]['description'] ?? ''}',
                onEdit: () => _editGuide(guides, i),
                onRemove: () => _remove('guides', guides, i),
              ),
            const SizedBox(height: 24),
            _header(
              'Self-defence videos',
              Icons.ondemand_video,
              () => _editVideo(videos),
            ),
            if (videos.isEmpty) _none('No extra videos yet.'),
            for (var i = 0; i < videos.length; i++)
              _itemTile(
                icon: Icons.play_circle_outline,
                title: (videos[i]['title'] ?? '').toString(),
                subtitle:
                    '${videos[i]['level'] ?? ''} · ${videos[i]['url'] ?? ''}',
                onEdit: () => _editVideo(videos, i),
                onRemove: () => _remove('videos', videos, i),
              ),
          ],
        );
      },
    );
  }

  Widget _header(String text, IconData icon, VoidCallback onAdd) => Padding(
    padding: const EdgeInsets.only(bottom: 10),
    child: Row(
      children: [
        Icon(icon, size: 18, color: AppColors.primary),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            text,
            style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
          ),
        ),
        FilledButton.tonalIcon(
          onPressed: onAdd,
          icon: const Icon(Icons.add, size: 18),
          label: const Text('Add'),
        ),
      ],
    ),
  );

  Widget _none(String text) => AdminCard(
    child: Text(text, style: const TextStyle(color: AppColors.textMuted)),
  );

  Widget _itemTile({
    required IconData icon,
    required String title,
    required String subtitle,
    required VoidCallback onEdit,
    required VoidCallback onRemove,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: AdminCard(
        padding: const EdgeInsets.fromLTRB(14, 6, 6, 6),
        child: Row(
          children: [
            Icon(icon, color: AppColors.primary),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                  Text(
                    subtitle,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 12.5,
                      color: AppColors.textMuted,
                    ),
                  ),
                ],
              ),
            ),
            IconButton(
              tooltip: 'Edit',
              icon: const Icon(Icons.edit_outlined),
              onPressed: onEdit,
            ),
            IconButton(
              tooltip: 'Remove',
              icon: const Icon(Icons.delete_outline, color: AppColors.danger),
              onPressed: onRemove,
            ),
          ],
        ),
      ),
    );
  }
}

List<String> _lines(String text) => text
    .split('\n')
    .map((l) => l.trim().replaceFirst(RegExp(r'^[•\-\*]\s*'), ''))
    .where((l) => l.isNotEmpty)
    .toList();

class _GuideDialog extends StatefulWidget {
  final Map<String, dynamic>? initial;
  const _GuideDialog({this.initial});

  @override
  State<_GuideDialog> createState() => _GuideDialogState();
}

class _GuideDialogState extends State<_GuideDialog> {
  final _form = GlobalKey<FormState>();
  late final _title = TextEditingController(
    text: (widget.initial?['title'] ?? '').toString(),
  );
  late final _description = TextEditingController(
    text: (widget.initial?['description'] ?? '').toString(),
  );
  late final _points = TextEditingController(
    text: (widget.initial?['points'] is List)
        ? (widget.initial!['points'] as List).join('\n')
        : '',
  );
  late final _helplines = TextEditingController(
    text: (widget.initial?['steps'] is List)
        ? (widget.initial!['steps'] as List).join('\n')
        : '',
  );
  late String _category =
      AdminContentPage.categories.contains(widget.initial?['category'])
      ? widget.initial!['category'] as String
      : 'Laws';

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(
        widget.initial == null ? 'Add legal guide' : 'Edit legal guide',
      ),
      content: SizedBox(
        width: 480,
        child: Form(
          key: _form,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextFormField(
                  controller: _title,
                  decoration: const InputDecoration(labelText: 'Title'),
                  validator: (v) =>
                      (v ?? '').trim().isEmpty ? 'Title is required' : null,
                ),
                DropdownButtonFormField<String>(
                  // ignore: deprecated_member_use
                  value: _category,
                  decoration: const InputDecoration(labelText: 'Category'),
                  items: [
                    for (final c in AdminContentPage.categories)
                      DropdownMenuItem(value: c, child: Text(c)),
                  ],
                  onChanged: (v) => setState(() => _category = v ?? 'Laws'),
                ),
                TextFormField(
                  controller: _description,
                  maxLines: 2,
                  decoration: const InputDecoration(
                    labelText: 'Short description',
                  ),
                  validator: (v) => (v ?? '').trim().isEmpty
                      ? 'Description is required'
                      : null,
                ),
                TextFormField(
                  controller: _points,
                  maxLines: 6,
                  decoration: const InputDecoration(
                    labelText: 'Key points (one per line)',
                  ),
                  validator: (v) =>
                      _lines(v ?? '').isEmpty ? 'Add at least one point' : null,
                ),
                TextFormField(
                  controller: _helplines,
                  maxLines: 3,
                  decoration: const InputDecoration(
                    labelText:
                        'Helplines / next steps (one per line, optional)',
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () {
            if (!(_form.currentState?.validate() ?? false)) return;
            Navigator.pop(context, {
              'title': _title.text.trim(),
              'category': _category,
              'description': _description.text.trim(),
              'points': _lines(_points.text),
              'steps': _lines(_helplines.text),
            });
          },
          child: const Text('Save'),
        ),
      ],
    );
  }
}

class _VideoDialog extends StatefulWidget {
  final Map<String, dynamic>? initial;
  const _VideoDialog({this.initial});

  @override
  State<_VideoDialog> createState() => _VideoDialogState();
}

class _VideoDialogState extends State<_VideoDialog> {
  final _form = GlobalKey<FormState>();
  late final _title = TextEditingController(
    text: (widget.initial?['title'] ?? '').toString(),
  );
  late final _url = TextEditingController(
    text: (widget.initial?['url'] ?? '').toString(),
  );
  late final _steps = TextEditingController(
    text: (widget.initial?['steps'] is List)
        ? (widget.initial!['steps'] as List).join('\n')
        : '',
  );
  late String _level =
      AdminContentPage.levels.contains(widget.initial?['level'])
      ? widget.initial!['level'] as String
      : 'Beginner';

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.initial == null ? 'Add video' : 'Edit video'),
      content: SizedBox(
        width: 480,
        child: Form(
          key: _form,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextFormField(
                  controller: _title,
                  decoration: const InputDecoration(
                    labelText: 'Technique name',
                  ),
                  validator: (v) =>
                      (v ?? '').trim().isEmpty ? 'Title is required' : null,
                ),
                DropdownButtonFormField<String>(
                  // ignore: deprecated_member_use
                  value: _level,
                  decoration: const InputDecoration(labelText: 'Level'),
                  items: [
                    for (final l in AdminContentPage.levels)
                      DropdownMenuItem(value: l, child: Text(l)),
                  ],
                  onChanged: (v) => setState(() => _level = v ?? 'Beginner'),
                ),
                TextFormField(
                  controller: _url,
                  keyboardType: TextInputType.url,
                  decoration: const InputDecoration(
                    labelText: 'YouTube link',
                    hintText: 'https://www.youtube.com/watch?v=...',
                  ),
                  validator: (v) {
                    final s = (v ?? '').trim().toLowerCase();
                    if (!s.startsWith('https://')) {
                      return 'Paste a full https:// link';
                    }
                    if (!s.contains('youtube.com') && !s.contains('youtu.be')) {
                      return 'Only YouTube links are allowed';
                    }
                    return null;
                  },
                ),
                TextFormField(
                  controller: _steps,
                  maxLines: 5,
                  decoration: const InputDecoration(
                    labelText: 'Steps (one per line)',
                  ),
                  validator: (v) =>
                      _lines(v ?? '').isEmpty ? 'Add at least one step' : null,
                ),
              ],
            ),
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () {
            if (!(_form.currentState?.validate() ?? false)) return;
            Navigator.pop(context, {
              'title': _title.text.trim(),
              'level': _level,
              'url': _url.text.trim(),
              'steps': _lines(_steps.text),
            });
          },
          child: const Text('Save'),
        ),
      ],
    );
  }
}
