import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import 'widgets.dart';

// The launch screen, continued: the phone's own splash (logo on sand) gives way to this one
// with the logo in the same place, so nothing jumps; the app's name, the tagline and a slim
// loader come in under it, and after a moment it fades into the map.

/// How long the splash stays after the app has started
const splashHold = Duration(milliseconds: 2400);
const _fade = Duration(milliseconds: 450);

class SplashGate extends StatefulWidget {
  const SplashGate({super.key, required this.child, this.hold = splashHold});

  final Widget child;
  final Duration hold;

  @override
  State<SplashGate> createState() => _SplashGateState();
}

class _SplashGateState extends State<SplashGate> {
  bool _leaving = false;
  bool _gone = false;

  @override
  void initState() {
    super.initState();
    Future<void>.delayed(widget.hold, () {
      if (mounted) setState(() => _leaving = true);
    });
  }

  @override
  Widget build(BuildContext context) => Stack(
    children: [
      widget.child,
      if (!_gone)
        IgnorePointer(
          ignoring: _leaving,
          child: AnimatedOpacity(
            opacity: _leaving ? 0 : 1,
            duration: _fade,
            curve: Curves.easeOut,
            onEnd: () => setState(() => _gone = true),
            child: const SplashScreen(),
          ),
        ),
    ],
  );
}

class SplashScreen extends StatelessWidget {
  const SplashScreen({super.key});

  // The phone's splash draws the logo 168 pt wide in the middle (LaunchScreen.storyboard)
  static const _logo = 168.0;

  @override
  Widget build(BuildContext context) => Material(
    key: const Key('splash'),
    color: L360Colors.sand50,
    child: Stack(
      children: [
        Center(
          child: Image.asset('assets/images/logo.png', width: _logo, height: _logo),
        ),
        // Under the logo: the name, the tagline and the loader, easing in
        Center(
          child: Padding(
            padding: const EdgeInsets.only(top: _logo + 40),
            child: TweenAnimationBuilder<double>(
              tween: Tween(begin: 0, end: 1),
              duration: const Duration(milliseconds: 700),
              curve: Curves.easeOutCubic,
              builder: (context, t, child) => Opacity(
                opacity: t,
                child: Transform.translate(offset: Offset(0, 12 * (1 - t)), child: child),
              ),
              child: const Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  BrandName(fontSize: 30, textAlign: TextAlign.center),
                  SizedBox(height: 6),
                  Text(
                    'Explore without Limits',
                    style: TextStyle(
                      fontSize: 14,
                      letterSpacing: 0.4,
                      fontWeight: FontWeight.w500,
                      color: L360Colors.sand600,
                    ),
                  ),
                  SizedBox(height: 28),
                  _Loader(),
                ],
              ),
            ),
          ),
        ),
        // Credits at the bottom, as on the sign-in page
        Positioned(
          left: 24,
          right: 24,
          bottom: MediaQuery.paddingOf(context).bottom + 24,
          child: const Text(
            'Jendela Cakra Digital · Makopala Univ. Budi Luhur',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 11, color: L360Colors.sand400, letterSpacing: 0.3),
          ),
        ),
      ],
    ),
  );
}

/// A slim rounded bar with a segment sweeping across it
class _Loader extends StatefulWidget {
  const _Loader();

  @override
  State<_Loader> createState() => _LoaderState();
}

class _LoaderState extends State<_Loader> with SingleTickerProviderStateMixin {
  late final _sweep = AnimationController(vsync: this, duration: const Duration(milliseconds: 1300))..repeat();

  @override
  void dispose() {
    _sweep.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ClipRRect(
    key: const Key('splash-loader'),
    borderRadius: BorderRadius.circular(2),
    child: SizedBox(
      width: 132,
      height: 3,
      child: ColoredBox(
        color: L360Colors.sand200,
        child: AnimatedBuilder(
          animation: _sweep,
          builder: (_, _) {
            // The segment eases from left to right, entering and leaving the bar
            final t = Curves.easeInOutCubic.transform(_sweep.value);
            return FractionallySizedBox(widthFactor: 1, child: CustomPaint(painter: _SweepPainter(t)));
          },
        ),
      ),
    ),
  );
}

class _SweepPainter extends CustomPainter {
  _SweepPainter(this.t);
  final double t;

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width * 0.38;
    final x = -w + (size.width + w) * t;
    final rect = Rect.fromLTWH(x, 0, w, size.height);
    canvas.drawRRect(
      RRect.fromRectAndRadius(rect, const Radius.circular(2)),
      Paint()
        ..shader = const LinearGradient(
          colors: [Color(0x00284A1B), L360Colors.forest700, L360Colors.ember500],
          stops: [0, 0.55, 1],
        ).createShader(rect),
    );
  }

  @override
  bool shouldRepaint(_SweepPainter old) => old.t != t;
}
