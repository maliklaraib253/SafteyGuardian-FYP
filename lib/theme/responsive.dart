import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

import '../services/admin_access.dart';
import 'app_theme.dart';

/// Breakpoints (logical pixels) used across the app.
class Breakpoints {
  Breakpoints._();
  static const double tablet = 600;
  static const double desktop = 1024;

  /// Widest a citizen (phone-first) screen grows to.
  static const double citizenMaxWidth = 960;

  /// Widest the police dashboard grows to.
  static const double policeMaxWidth = 1280;
}

class Responsive {
  Responsive._();

  static double width(BuildContext context) => MediaQuery.sizeOf(context).width;

  static bool isPhone(BuildContext context) =>
      width(context) < Breakpoints.tablet;
  static bool isTablet(BuildContext context) =>
      width(context) >= Breakpoints.tablet &&
      width(context) < Breakpoints.desktop;
  static bool isDesktop(BuildContext context) =>
      width(context) >= Breakpoints.desktop;

  /// Picks a value for the current screen size.
  static T value<T>(
    BuildContext context, {
    required T phone,
    T? tablet,
    T? desktop,
  }) {
    if (isDesktop(context)) return desktop ?? tablet ?? phone;
    if (isTablet(context)) return tablet ?? phone;
    return phone;
  }

  /// Horizontal page padding: 16 on small phones, 20 on phones, 28 on tablets.
  static double pagePadding(BuildContext context) {
    final w = width(context);
    if (w < 360) return 16;
    if (w < Breakpoints.tablet) return 20;
    return 28;
  }

  /// Grid columns for tiles of at least [minTileWidth] px.
  static int gridColumns(
    BuildContext context, {
    double minTileWidth = 160,
    int max = 4,
  }) {
    final available = width(context) - pagePadding(context) * 2;
    return (available / minTileWidth).floor().clamp(2, max);
  }
}

/// Wraps the whole app (MaterialApp.builder):
/// * keeps text scaling within a range the layouts are designed for,
/// * on tablets, desktops and the web, centres the app in a readable
///   column instead of stretching phone layouts across a wide screen.
///   Police accounts get a wider canvas for the dashboard.
class ResponsiveAppShell extends StatelessWidget {
  final Widget child;
  const ResponsiveAppShell({super.key, required this.child});

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    final clamped = media.copyWith(
      textScaler: media.textScaler.clamp(
        minScaleFactor: 0.85,
        maxScaleFactor: 1.3,
      ),
    );

    return MediaQuery(
      data: clamped,
      child: ValueListenableBuilder<Set<String>>(
        valueListenable: AdminAccess.knownAdmins,
        builder: (context, _, _) => StreamBuilder<User?>(
          stream: FirebaseAuth.instance.authStateChanges(),
          builder: (context, snapshot) {
            final email = snapshot.data?.email;
            // Police and admins get the wide canvas for their dashboards.
            final isPolice =
                email?.contains('@police.gov.pk') == true ||
                AdminAccess.isKnownAdmin(email);
            final maxWidth = isPolice
                ? Breakpoints.policeMaxWidth
                : Breakpoints.citizenMaxWidth;
            final screenWidth = clamped.size.width;
            if (screenWidth <= maxWidth) return child;

            return ColoredBox(
              color: AppColors.border,
              child: Center(
                child: ConstrainedBox(
                  constraints: BoxConstraints(maxWidth: maxWidth),
                  child: MediaQuery(
                    // Screens inside see the column width, so their own
                    // breakpoints (grid columns, rails) react correctly.
                    data: clamped.copyWith(
                      size: Size(maxWidth, clamped.size.height),
                    ),
                    child: ClipRect(child: child),
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}

/// Centres page content and caps its width; use inside scroll views.
class ContentWidth extends StatelessWidget {
  final Widget child;
  final double maxWidth;
  const ContentWidth({super.key, required this.child, this.maxWidth = 720});

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: maxWidth),
        child: child,
      ),
    );
  }
}
