import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:iconsax/iconsax.dart';
import 'package:cloud_firestore/cloud_firestore.dart';

import '../services/auth_service.dart';
import '../services/sos_service.dart';
import '../theme/app_theme.dart';
import '../theme/responsive.dart';
import '../widgets/app_logo.dart';

/// Citizen home — "Calm Shield" layout.
/// Phone: single column + bottom navigation.
/// Tablet / web (>= 720 px): navigation rail, SOS + activity side by side,
/// 3-column feature grid.
class CitizenHomeScreen extends StatefulWidget {
  const CitizenHomeScreen({super.key});

  @override
  State<CitizenHomeScreen> createState() => _CitizenHomeScreenState();
}

class _CitizenHomeScreenState extends State<CitizenHomeScreen> {
  final SosService _sosService = SosService();
  int _contactCount = 0;

  @override
  void initState() {
    super.initState();
    _loadContactCount();
    // Ask for SMS, phone and location once, up front, so an SOS never has to
    // stop and ask during an emergency.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _sosService.requestPermissions().catchError((_) => false);
      // Older accounts: add their (hashed) email/CNIC to the signup registry.
      AuthService().ensureRegistryForCurrentUser();
    });
  }

  Future<void> _loadContactCount() async {
    try {
      await _sosService.loadContacts();
      if (!mounted) return;
      setState(() => _contactCount = _sosService.trustedContacts.length);
    } catch (_) {}
  }

  /// Opens a route and refreshes the contact count when the user comes back
  /// (they may have added or removed trusted contacts).
  Future<void> _open(String route, {Object? arguments}) async {
    await Navigator.pushNamed(context, route, arguments: arguments);
    if (mounted) _loadContactCount();
  }

  void _onNavTap(int index) {
    switch (index) {
      case 1:
        _open('/my-reports');
        break;
      case 2:
        _open('/contacts');
        break;
      case 3:
        _open('/settings');
        break;
    }
  }

  static const _destinations = [
    (Iconsax.home_2, 'Home'),
    (Iconsax.document_text, 'Reports'),
    (Iconsax.people, 'Contacts'),
    (Iconsax.setting_2, 'Settings'),
  ];

  @override
  Widget build(BuildContext context) {
    final wide = MediaQuery.sizeOf(context).width >= 720;
    final content = SafeArea(
      bottom: false,
      child: _HomeBody(wide: wide, contactCount: _contactCount, onOpen: _open),
    );

    if (wide) {
      return Scaffold(
        body: Row(
          children: [
            NavigationRail(
              selectedIndex: 0,
              onDestinationSelected: _onNavTap,
              labelType: NavigationRailLabelType.all,
              minWidth: 84,
              leading: Padding(
                padding: const EdgeInsets.only(top: 12, bottom: 20),
                child: const AppLogoBadge(size: 44),
              ),
              destinations: [
                for (final d in _destinations)
                  NavigationRailDestination(
                    icon: Icon(d.$1),
                    label: Text(d.$2),
                  ),
              ],
            ),
            const VerticalDivider(
              width: 1,
              thickness: 1,
              color: AppColors.border,
            ),
            Expanded(child: content),
          ],
        ),
      );
    }

    return Scaffold(
      body: content,
      bottomNavigationBar: DecoratedBox(
        decoration: const BoxDecoration(
          border: Border(top: BorderSide(color: AppColors.border)),
        ),
        child: NavigationBar(
          selectedIndex: 0,
          onDestinationSelected: _onNavTap,
          destinations: [
            for (final d in _destinations)
              NavigationDestination(icon: Icon(d.$1), label: d.$2),
          ],
        ),
      ),
    );
  }
}

class _HomeBody extends StatelessWidget {
  final bool wide;
  final int contactCount;
  final Future<void> Function(String route, {Object? arguments}) onOpen;

  const _HomeBody({
    required this.wide,
    required this.contactCount,
    required this.onOpen,
  });

  @override
  Widget build(BuildContext context) {
    final user = FirebaseAuth.instance.currentUser;
    final pad = Responsive.pagePadding(context);

    const features = <_Feature>[
      _Feature(
        Iconsax.document_upload,
        'Report incident',
        'Photos, video & location',
        '/report',
      ),
      _Feature(
        Iconsax.document_text,
        'My reports',
        'Track their status',
        '/my-reports',
      ),
      _Feature(
        Iconsax.routing_2,
        'Companion mode',
        'Trip & fall monitoring',
        '/companion',
      ),
      _Feature(
        Iconsax.microphone_2,
        'Distress detection',
        'Listens for cries for help',
        '/distress',
      ),
      _Feature(
        Iconsax.camera,
        'Evidence capture',
        'Audio, video & location',
        '/evidence',
      ),
      _Feature(Iconsax.book_1, 'Legal help', 'Know your rights', '/legal'),
    ];

    final sosCard = _SosCard(
      onTap: () => onOpen('/sos'),
      onHeld: () => onOpen('/sos', arguments: 'activate'),
    );
    final activity = _ActivityCard(user: user, onOpen: onOpen);

    return ListView(
      padding: EdgeInsets.fromLTRB(pad, 16, pad, 24),
      children: [
        _Header(user: user, onOpen: onOpen),
        const SizedBox(height: 14),
        _ProtectedBadge(count: contactCount, onTap: () => onOpen('/contacts')),
        const SizedBox(height: 16),
        if (wide)
          IntrinsicHeight(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(child: sosCard),
                const SizedBox(width: 16),
                Expanded(child: activity),
              ],
            ),
          )
        else
          sosCard,
        const SizedBox(height: 24),
        const _SectionTitle('Quick actions'),
        const SizedBox(height: 12),
        LayoutBuilder(
          builder: (context, c) {
            final cols = c.maxWidth >= 640 ? 3 : 2;
            const gap = 12.0;
            final tileWidth = (c.maxWidth - gap * (cols - 1)) / cols;
            return Wrap(
              spacing: gap,
              runSpacing: gap,
              children: [
                for (final f in features)
                  SizedBox(
                    width: tileWidth,
                    child: _FeatureTile(
                      feature: f,
                      onTap: () => onOpen(f.route),
                    ),
                  ),
              ],
            );
          },
        ),
        if (!wide) ...[const SizedBox(height: 24), activity],
      ],
    );
  }
}

class _Header extends StatelessWidget {
  final User? user;
  final Future<void> Function(String route, {Object? arguments}) onOpen;
  const _Header({required this.user, required this.onOpen});

  String _greeting() {
    final h = DateTime.now().hour;
    if (h < 12) return 'Good morning';
    if (h < 17) return 'Good afternoon';
    return 'Good evening';
  }

  @override
  Widget build(BuildContext context) {
    final u = user;
    return StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
      stream: u == null
          ? null
          : FirebaseFirestore.instance
                .collection('users')
                .doc(u.uid)
                .snapshots(),
      builder: (context, snap) {
        final stored = (snap.data?.data()?['name'] ?? '').toString().trim();
        final display = (u?.displayName ?? '').trim();
        final fallback = display.isNotEmpty
            ? display
            : (u?.email ?? 'there').split('@').first;
        final name = stored.isNotEmpty ? stored : fallback;
        final first = name.split(' ').first;
        final initials = name
            .split(RegExp(r'\s+'))
            .where((p) => p.isNotEmpty)
            .take(2)
            .map((p) => p[0].toUpperCase())
            .join();

        return Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    _greeting(),
                    style: const TextStyle(
                      fontSize: 14,
                      color: AppColors.textMuted,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    first,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 24,
                      fontWeight: FontWeight.w700,
                      letterSpacing: -0.4,
                    ),
                  ),
                ],
              ),
            ),
            _CircleButton(
              key: const Key('home_notifications_button'),
              tooltip: 'Report updates',
              icon: Iconsax.notification,
              onTap: () => onOpen('/my-reports'),
            ),
            const SizedBox(width: 10),
            Tooltip(
              message: 'Profile',
              child: InkWell(
                key: const Key('home_profile_button'),
                customBorder: const CircleBorder(),
                onTap: () => onOpen('/profile'),
                child: CircleAvatar(
                  radius: 22,
                  backgroundColor: AppColors.primary,
                  child: Text(
                    initials.isEmpty ? '?' : initials,
                    style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.w700,
                      fontSize: 15,
                    ),
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

class _CircleButton extends StatelessWidget {
  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;
  const _CircleButton({
    super.key,
    required this.icon,
    required this.tooltip,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: Material(
        color: AppColors.surface,
        shape: const CircleBorder(side: BorderSide(color: AppColors.border)),
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: onTap,
          child: SizedBox(
            width: 44,
            height: 44,
            child: Icon(icon, size: 20, color: AppColors.text),
          ),
        ),
      ),
    );
  }
}

class _ProtectedBadge extends StatelessWidget {
  final int count;
  final VoidCallback onTap;
  const _ProtectedBadge({required this.count, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final ok = count > 0;
    final bg = ok ? AppColors.successSoft : AppColors.warningSoft;
    final fg = ok ? AppColors.success : AppColors.warning;
    final label = ok
        ? 'Protected · $count trusted contact${count == 1 ? '' : 's'} ready'
        : 'Add trusted contacts so SOS can reach someone';
    return Align(
      alignment: Alignment.centerLeft,
      child: Material(
        color: bg,
        borderRadius: BorderRadius.circular(999),
        child: InkWell(
          borderRadius: BorderRadius.circular(999),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  ok ? Iconsax.shield_tick : Iconsax.warning_2,
                  size: 16,
                  color: fg,
                ),
                const SizedBox(width: 6),
                Flexible(
                  child: Text(
                    label,
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: fg,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Big SOS button: tap opens the SOS screen, holding for 3 seconds
/// opens it and starts the alert immediately.
class _SosCard extends StatefulWidget {
  final VoidCallback onTap;
  final VoidCallback onHeld;
  const _SosCard({required this.onTap, required this.onHeld});

  @override
  State<_SosCard> createState() => _SosCardState();
}

class _SosCardState extends State<_SosCard>
    with SingleTickerProviderStateMixin {
  late final AnimationController _hold;

  @override
  void initState() {
    super.initState();
    _hold =
        AnimationController(vsync: this, duration: const Duration(seconds: 3))
          ..addStatusListener((s) {
            if (s == AnimationStatus.completed) {
              _hold.reset();
              widget.onHeld();
            }
          });
  }

  @override
  void dispose() {
    _hold.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final size = Responsive.value<double>(context, phone: 156, tablet: 176);
    return Container(
      padding: const EdgeInsets.fromLTRB(20, 24, 20, 20),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(AppRadius.xl),
        border: Border.all(color: AppColors.border),
      ),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Semantics(
            button: true,
            label: 'SOS. Tap to open, hold for 3 seconds to send an alert',
            child: GestureDetector(
              key: const Key('home_sos_button'),
              onTap: widget.onTap,
              onLongPressStart: (_) => _hold.forward(from: 0),
              onLongPressEnd: (_) {
                if (_hold.status != AnimationStatus.completed) _hold.reverse();
              },
              child: AnimatedBuilder(
                animation: _hold,
                builder: (context, _) {
                  return SizedBox(
                    width: size + 24,
                    height: size + 24,
                    child: Stack(
                      alignment: Alignment.center,
                      children: [
                        Container(
                          width: size + 24,
                          height: size + 24,
                          decoration: const BoxDecoration(
                            shape: BoxShape.circle,
                            color: AppColors.dangerSoft,
                          ),
                        ),
                        SizedBox(
                          width: size + 20,
                          height: size + 20,
                          child: CircularProgressIndicator(
                            value: _hold.value,
                            strokeWidth: 5,
                            color: AppColors.dangerDark,
                            backgroundColor: Colors.transparent,
                          ),
                        ),
                        Transform.scale(
                          scale: 1 - _hold.value * 0.04,
                          child: Container(
                            width: size,
                            height: size,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: AppColors.danger,
                              boxShadow: [
                                BoxShadow(
                                  color: AppColors.danger.withValues(
                                    alpha: 0.28,
                                  ),
                                  blurRadius: 24,
                                  offset: const Offset(0, 10),
                                ),
                              ],
                            ),
                            child: Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                const Text(
                                  'SOS',
                                  style: TextStyle(
                                    color: Colors.white,
                                    fontSize: 36,
                                    fontWeight: FontWeight.w800,
                                    letterSpacing: 1.5,
                                  ),
                                ),
                                const SizedBox(height: 2),
                                Text(
                                  _hold.isAnimating
                                      ? 'Keep holding…'
                                      : 'tap to start',
                                  style: TextStyle(
                                    color: Colors.white.withValues(alpha: 0.9),
                                    fontSize: 13,
                                    fontWeight: FontWeight.w500,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ],
                    ),
                  );
                },
              ),
            ),
          ),
          const SizedBox(height: 16),
          const Text(
            'Alerts your trusted contacts and police with your live location',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 13.5,
              color: AppColors.textMuted,
              height: 1.4,
            ),
          ),
        ],
      ),
    );
  }
}

class _Feature {
  final IconData icon;
  final String title;
  final String subtitle;
  final String route;
  const _Feature(this.icon, this.title, this.subtitle, this.route);
}

class _FeatureTile extends StatelessWidget {
  final _Feature feature;
  final VoidCallback onTap;
  const _FeatureTile({required this.feature, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Material(
      color: AppColors.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(18),
        side: const BorderSide(color: AppColors.border),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(18),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 36,
                height: 36,
                decoration: BoxDecoration(
                  color: AppColors.primarySoft,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(feature.icon, size: 19, color: AppColors.primary),
              ),
              const SizedBox(height: 12),
              Text(
                feature.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: 14.5,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                feature.subtitle,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: 12,
                  color: AppColors.textMuted,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SectionTitle extends StatelessWidget {
  final String text;
  const _SectionTitle(this.text);

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
    );
  }
}

/// Latest report + totals, live from Firestore.
class _ActivityCard extends StatelessWidget {
  final User? user;
  final Future<void> Function(String route, {Object? arguments}) onOpen;
  const _ActivityCard({required this.user, required this.onOpen});

  static DateTime? _date(Map<String, dynamic> r) {
    for (final key in ['timestamp', 'createdAt', 'date']) {
      final v = r[key];
      if (v is Timestamp) return v.toDate();
      if (v is String) {
        final d = DateTime.tryParse(v);
        if (d != null) return d;
      }
    }
    return null;
  }

  static String _ago(DateTime? d) {
    if (d == null) return '';
    final diff = DateTime.now().difference(d);
    if (diff.inMinutes < 1) return 'just now';
    if (diff.inMinutes < 60) return '${diff.inMinutes} min ago';
    if (diff.inHours < 24) return '${diff.inHours} h ago';
    if (diff.inDays < 7) return '${diff.inDays} d ago';
    return '${d.day}/${d.month}/${d.year}';
  }

  static (String, Color, Color) _statusStyle(String s) {
    switch (s) {
      case 'resolved':
      case 'closed':
        return ('Resolved', AppColors.successSoft, AppColors.success);
      case 'in progress':
      case 'investigating':
      case 'assigned':
        return ('In progress', AppColors.primarySoft, AppColors.primary);
      case 'rejected':
      case 'withdrawn':
        return (
          s[0].toUpperCase() + s.substring(1),
          AppColors.divider,
          AppColors.textMuted,
        );
      default:
        return ('Pending', AppColors.warningSoft, AppColors.warning);
    }
  }

  @override
  Widget build(BuildContext context) {
    final u = user;
    return StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
      stream: u == null
          ? null
          : FirebaseFirestore.instance
                .collection('reports')
                .where('userId', isEqualTo: u.uid)
                .snapshots(),
      builder: (context, snap) {
        final docs = [...?snap.data?.docs];
        docs.sort((a, b) {
          final da = _date(a.data()) ?? DateTime(1970);
          final db = _date(b.data()) ?? DateTime(1970);
          return db.compareTo(da);
        });
        String st(Map<String, dynamic> r) => (r['status'] ?? 'pending')
            .toString()
            .toLowerCase()
            .replaceAll('_', ' ');
        final total = docs.length;
        final pending = docs.where((d) => st(d.data()) == 'pending').length;
        final resolved = docs.where((d) => st(d.data()) == 'resolved').length;
        final latest = docs.isEmpty ? null : docs.first.data();

        Widget latestRow() {
          final r = latest!;
          final (label, bg, fg) = _statusStyle(st(r));
          final title = (r['title'] ?? '').toString().trim();
          final category = (r['category'] ?? '').toString().trim();
          return Row(
            children: [
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: AppColors.primarySoft,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: const Icon(
                  Iconsax.document_text,
                  size: 20,
                  color: AppColors.primary,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title.isNotEmpty
                          ? title
                          : (category.isNotEmpty
                                ? category
                                : 'Incident report'),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 14.5,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      _ago(_date(r)),
                      style: const TextStyle(
                        fontSize: 12,
                        color: AppColors.textMuted,
                      ),
                    ),
                  ],
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 5,
                ),
                decoration: BoxDecoration(
                  color: bg,
                  borderRadius: BorderRadius.circular(999),
                ),
                child: Text(
                  label,
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: fg,
                  ),
                ),
              ),
            ],
          );
        }

        return Material(
          color: AppColors.surface,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppRadius.xl),
            side: const BorderSide(color: AppColors.border),
          ),
          child: InkWell(
            borderRadius: BorderRadius.circular(AppRadius.xl),
            onTap: () => onOpen('/my-reports'),
            child: Padding(
              padding: const EdgeInsets.all(18),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Row(
                    children: [
                      Expanded(child: _SectionTitle('Recent report')),
                      Text(
                        'See all',
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          color: AppColors.primary,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  if (latest == null)
                    const Text(
                      'No reports yet. When you report an incident, its progress shows up here.',
                      style: TextStyle(
                        fontSize: 13.5,
                        color: AppColors.textMuted,
                        height: 1.4,
                      ),
                    )
                  else
                    latestRow(),
                  const SizedBox(height: 16),
                  const Divider(),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      _Stat(value: '$total', label: 'Reports'),
                      _Stat(value: '$pending', label: 'Pending'),
                      _Stat(value: '$resolved', label: 'Resolved'),
                    ],
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

class _Stat extends StatelessWidget {
  final String value;
  final String label;
  const _Stat({required this.value, required this.label});

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Column(
        children: [
          Text(
            value,
            style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 2),
          Text(
            label,
            style: const TextStyle(fontSize: 12, color: AppColors.textMuted),
          ),
        ],
      ),
    );
  }
}
