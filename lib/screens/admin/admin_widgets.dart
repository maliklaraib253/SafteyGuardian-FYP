import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';

import '../../theme/app_theme.dart';

/// Small shared pieces used by the admin portal pages.

String adminFormatDate(dynamic value, {bool withTime = true}) {
  DateTime? d;
  if (value is Timestamp) d = value.toDate();
  if (value is DateTime) d = value;
  if (value is String) d = DateTime.tryParse(value);
  if (d == null) return '-';
  const months = [
    'Jan',
    'Feb',
    'Mar',
    'Apr',
    'May',
    'Jun',
    'Jul',
    'Aug',
    'Sep',
    'Oct',
    'Nov',
    'Dec',
  ];
  final date = '${d.day} ${months[d.month - 1]} ${d.year}';
  if (!withTime) return date;
  final h = d.hour % 12 == 0 ? 12 : d.hour % 12;
  final m = d.minute.toString().padLeft(2, '0');
  return '$date, $h:$m ${d.hour < 12 ? 'AM' : 'PM'}';
}

DateTime? adminToDate(dynamic value) {
  if (value is Timestamp) return value.toDate();
  if (value is DateTime) return value;
  if (value is String) return DateTime.tryParse(value);
  return null;
}

/// 'in_progress' / 'In Progress' -> 'in progress'
String adminStatusOf(Map<String, dynamic> r) =>
    (r['status'] ?? 'pending').toString().toLowerCase().replaceAll('_', ' ');

String adminPriorityOf(Map<String, dynamic> r) {
  final p = (r['priority'] ?? '').toString().toUpperCase().trim();
  if (p.isEmpty || p == 'PENDING') return 'UNRATED';
  return p;
}

Color adminStatusColor(String status) {
  switch (status) {
    case 'resolved':
      return AppColors.success;
    case 'rejected':
      return AppColors.danger;
    case 'in progress':
      return AppColors.primary;
    default:
      return AppColors.warning;
  }
}

Color adminPriorityColor(String priority) {
  switch (priority) {
    case 'CRITICAL':
      return AppColors.dangerDark;
    case 'HIGH':
      return AppColors.danger;
    case 'MEDIUM':
      return AppColors.warning;
    case 'LOW':
      return AppColors.success;
    default:
      return AppColors.textSubtle;
  }
}

/// Shows only the last 4 digits of a CNIC, e.g. *****-***4567-1.
String adminMaskCnic(String cnic) {
  final d = cnic.replaceAll(RegExp(r'[^0-9]'), '');
  if (d.isEmpty) return '-';
  if (d.length != 13) return '*' * d.length;
  return '*****-***${d.substring(8, 12)}-${d.substring(12)}';
}

String adminTitleCase(String s) => s
    .split(' ')
    .where((w) => w.isNotEmpty)
    .map((w) => w[0].toUpperCase() + w.substring(1))
    .join(' ');

class AdminChip extends StatelessWidget {
  final String label;
  final Color color;
  final IconData? icon;
  const AdminChip({
    super.key,
    required this.label,
    required this.color,
    this.icon,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: color.withValues(alpha: 0.35)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, size: 12, color: color),
            const SizedBox(width: 4),
          ],
          Text(
            label,
            style: TextStyle(
              fontSize: 11.5,
              fontWeight: FontWeight.w600,
              color: color,
            ),
          ),
        ],
      ),
    );
  }
}

class AdminCard extends StatelessWidget {
  final Widget child;
  final EdgeInsetsGeometry padding;
  const AdminCard({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(16),
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: padding,
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppColors.border),
      ),
      child: child,
    );
  }
}

class AdminStatCard extends StatelessWidget {
  final String label;
  final String value;
  final IconData icon;
  final Color color;
  final String? hint;
  const AdminStatCard({
    super.key,
    required this.label,
    required this.value,
    required this.icon,
    required this.color,
    this.hint,
  });

  @override
  Widget build(BuildContext context) {
    return AdminCard(
      child: Row(
        children: [
          Container(
            width: 42,
            height: 42,
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.10),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Icon(icon, color: color, size: 22),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  value,
                  style: const TextStyle(
                    fontSize: 22,
                    fontWeight: FontWeight.w700,
                    color: AppColors.text,
                  ),
                ),
                Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 12.5,
                    color: AppColors.textMuted,
                  ),
                ),
                if (hint != null)
                  Text(
                    hint!,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 11,
                      color: AppColors.textSubtle,
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class AdminEmpty extends StatelessWidget {
  final IconData icon;
  final String title;
  final String? message;
  const AdminEmpty({
    super.key,
    required this.icon,
    required this.title,
    this.message,
  });

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 44, color: AppColors.textSubtle),
            const SizedBox(height: 10),
            Text(
              title,
              textAlign: TextAlign.center,
              style: const TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w600,
                color: AppColors.text,
              ),
            ),
            if (message != null) ...[
              const SizedBox(height: 4),
              Text(
                message!,
                textAlign: TextAlign.center,
                style: const TextStyle(color: AppColors.textMuted),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class AdminError extends StatelessWidget {
  final Object? error;
  const AdminError({super.key, this.error});

  @override
  Widget build(BuildContext context) {
    final text = error.toString();
    final denied = text.contains('permission-denied');
    return AdminEmpty(
      icon: Icons.error_outline,
      title: denied ? 'Access denied by security rules' : 'Could not load data',
      message: denied
          ? 'Publish the latest firestore.rules and make sure this account is in the admins collection.'
          : text,
    );
  }
}

/// Search box used at the top of list pages.
class AdminSearchField extends StatelessWidget {
  final String hint;
  final ValueChanged<String> onChanged;
  const AdminSearchField({
    super.key,
    required this.hint,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return TextField(
      onChanged: onChanged,
      decoration: InputDecoration(
        hintText: hint,
        prefixIcon: const Icon(Icons.search, size: 20),
        isDense: true,
        filled: true,
        fillColor: AppColors.surface,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: AppColors.border),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: AppColors.border),
        ),
      ),
    );
  }
}

/// Yes/no confirmation. Returns true when confirmed.
Future<bool> adminConfirm(
  BuildContext context, {
  required String title,
  required String message,
  String confirmLabel = 'Confirm',
  bool danger = false,
}) async {
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(title),
      content: Text(message),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx, false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          style: FilledButton.styleFrom(
            backgroundColor: danger ? AppColors.danger : AppColors.primary,
          ),
          onPressed: () => Navigator.pop(ctx, true),
          child: Text(confirmLabel),
        ),
      ],
    ),
  );
  return ok == true;
}

/// Asks for a single piece of text (e.g. a reason). Returns null on cancel.
Future<String?> adminAskText(
  BuildContext context, {
  required String title,
  required String label,
  String confirmLabel = 'Save',
  String initial = '',
  bool mustFill = true,
  int maxLines = 3,
  bool danger = false,
}) async {
  final controller = TextEditingController(text: initial);
  String? error;
  final result = await showDialog<String>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setLocal) => AlertDialog(
        title: Text(title),
        content: SizedBox(
          width: 420,
          child: TextField(
            controller: controller,
            autofocus: true,
            maxLines: maxLines,
            decoration: InputDecoration(
              labelText: label,
              errorText: error,
              border: const OutlineInputBorder(),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: danger ? AppColors.danger : AppColors.primary,
            ),
            onPressed: () {
              final text = controller.text.trim();
              if (mustFill && text.isEmpty) {
                setLocal(() => error = 'Please fill this in');
                return;
              }
              Navigator.pop(ctx, text);
            },
            child: Text(confirmLabel),
          ),
        ],
      ),
    ),
  );
  // Not disposed here: the dialog's closing animation may still use it.
  return result;
}

void adminToast(BuildContext context, String message, {bool error = false}) {
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(
      backgroundColor: error ? AppColors.danger : AppColors.success,
      content: Text(message),
    ),
  );
}

/// Friendly text for Firebase errors shown to the admin.
String adminErrorText(Object e) {
  final s = e.toString();
  if (s.contains('permission-denied')) {
    return 'Not allowed by the security rules. Publish the latest rules.';
  }
  if (s.contains('unavailable') || s.contains('network')) {
    return 'No connection. Check the internet and try again.';
  }
  return s.replaceFirst(RegExp(r'^\[[^\]]*\]\s*'), '');
}
