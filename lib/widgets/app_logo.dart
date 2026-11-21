import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// The Safety Guardian mark: an outlined shield with "SG" inside.
/// Drawn in code so it stays sharp at any size and needs no image asset.
class AppLogo extends StatelessWidget {
  /// Height of the shield. Width is 60/72 of it.
  final double size;
  final Color color;

  const AppLogo({super.key, this.size = 48, this.color = Colors.white});

  @override
  Widget build(BuildContext context) {
    final width = size * 60 / 72;
    return Semantics(
      label: 'Safety Guardian logo',
      child: SizedBox(
        width: width,
        height: size,
        child: CustomPaint(
          painter: _ShieldPainter(color),
          child: Center(
            child: Padding(
              padding: EdgeInsets.only(bottom: size * 0.06),
              child: Text(
                'SG',
                textScaler: TextScaler.noScaling,
                style: TextStyle(
                  color: color,
                  fontSize: size * 0.32,
                  fontWeight: FontWeight.w700,
                  letterSpacing: size * 0.008,
                  height: 1,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Logo inside the blue rounded square, as on the app icon.
class AppLogoBadge extends StatelessWidget {
  final double size;
  const AppLogoBadge({super.key, this.size = 52});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: AppColors.primary,
        borderRadius: BorderRadius.circular(size * 0.28),
      ),
      alignment: Alignment.center,
      child: AppLogo(size: size * 0.6),
    );
  }
}

class _ShieldPainter extends CustomPainter {
  final Color color;
  _ShieldPainter(this.color);

  @override
  void paint(Canvas canvas, Size size) {
    // Shield drawn in a 60 x 72 box, inset so the stroke stays inside.
    final stroke = size.height * 0.05;
    final sx = (size.width - stroke) / 60;
    final sy = (size.height - stroke) / 72;
    final o = stroke / 2;
    Offset p(double x, double y) => Offset(o + x * sx, o + y * sy);

    final path = Path()
      ..moveTo(p(30, 0).dx, p(30, 0).dy)
      ..lineTo(p(60, 10).dx, p(60, 10).dy)
      ..lineTo(p(60, 34).dx, p(60, 34).dy)
      ..cubicTo(
        p(60, 54).dx,
        p(60, 54).dy,
        p(46, 66).dx,
        p(46, 66).dy,
        p(30, 72).dx,
        p(30, 72).dy,
      )
      ..cubicTo(
        p(14, 66).dx,
        p(14, 66).dy,
        p(0, 54).dx,
        p(0, 54).dy,
        p(0, 34).dx,
        p(0, 34).dy,
      )
      ..lineTo(p(0, 10).dx, p(0, 10).dy)
      ..close();

    canvas.drawPath(
      path,
      Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = stroke
        ..strokeJoin = StrokeJoin.round,
    );
  }

  @override
  bool shouldRepaint(_ShieldPainter old) => old.color != color;
}

/// Branded splash shown while the app starts and checks the signed-in user.
/// Matches the native splash (blue background, shield, name) so the hand-off
/// from the system splash is seamless.
class BrandSplash extends StatelessWidget {
  const BrandSplash({super.key});

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      backgroundColor: AppColors.primary,
      body: SafeArea(
        child: Column(
          children: [
            Spacer(),
            AppLogo(size: 128),
            SizedBox(height: 24),
            Text(
              'Safety Guardian',
              style: TextStyle(
                color: Colors.white,
                fontSize: 25,
                fontWeight: FontWeight.w700,
                letterSpacing: -0.3,
              ),
            ),
            SizedBox(height: 6),
            Text(
              'Your safety, one tap away',
              style: TextStyle(color: Color(0xBFFFFFFF), fontSize: 13.5),
            ),
            Spacer(),
            SizedBox(
              width: 22,
              height: 22,
              child: CircularProgressIndicator(
                strokeWidth: 2.2,
                color: Colors.white,
              ),
            ),
            SizedBox(height: 40),
          ],
        ),
      ),
    );
  }
}
