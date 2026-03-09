import 'dart:math' as math;
import 'package:flutter/material.dart';

/// A warm, friendly loading indicator used throughout the app.
///
/// Two modes:
///   - Normal (default): a softly floating receipt icon with an animated shadow.
///   - Compact: three gently pulsing dots — suitable for inline / button usage.
class LoadingIndicator extends StatefulWidget {
  final String? message;
  final double size;
  final bool compact;
  final Color? color;

  const LoadingIndicator({
    super.key,
    this.message,
    this.size = 48,
    this.compact = false,
    this.color,
  });

  @override
  State<LoadingIndicator> createState() => _LoadingIndicatorState();
}

class _LoadingIndicatorState extends State<LoadingIndicator>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: Duration(milliseconds: widget.compact ? 1200 : 1300),
    )..repeat();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (widget.compact) return _buildDots(context);
    return _buildFloatingIcon(context);
  }

  // ─── Normal mode: floating receipt icon ──────────────────────

  Widget _buildFloatingIcon(BuildContext context) {
    final color =
        widget.color ?? Theme.of(context).colorScheme.primary;

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        AnimatedBuilder(
          animation: _controller,
          builder: (context, child) {
            final t = _controller.value;
            final float = math.sin(t * 2 * math.pi) * 6;
            final scale = 1.0 + math.sin(t * 2 * math.pi) * 0.05;
            final shadowOpacity = 0.18 - math.sin(t * 2 * math.pi) * 0.08;
            final shadowSpread = 12.0 + math.sin(t * 2 * math.pi) * 4;

            return Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Transform.translate(
                  offset: Offset(0, float),
                  child: Transform.scale(
                    scale: scale,
                    child: Icon(
                      Icons.receipt_long_outlined,
                      size: widget.size,
                      color: color,
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                Container(
                  width: shadowSpread * 2,
                  height: 6,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(3),
                    color: color.withValues(alpha: shadowOpacity),
                  ),
                ),
              ],
            );
          },
        ),
        if (widget.message != null) ...[
          const SizedBox(height: 20),
          Text(
            widget.message!,
            textAlign: TextAlign.center,
            textDirection: TextDirection.rtl,
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w500,
              color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.7),
            ),
          ),
        ],
      ],
    );
  }

  // ─── Compact mode: three pulsing dots ────────────────────────

  Widget _buildDots(BuildContext context) {
    final color =
        widget.color ?? Theme.of(context).colorScheme.primary;
    final dotSize = widget.size * 0.28;

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: List.generate(3, (i) {
        return AnimatedBuilder(
          animation: _controller,
          builder: (context, _) {
            final phase = (_controller.value - i * 0.15) % 1.0;
            final bounce = math.sin(phase * 2 * math.pi).clamp(0.0, 1.0);
            final scale = 0.6 + bounce * 0.4;
            final opacity = 0.35 + bounce * 0.65;

            return Padding(
              padding: EdgeInsets.symmetric(horizontal: dotSize * 0.3),
              child: Transform.scale(
                scale: scale,
                child: Opacity(
                  opacity: opacity,
                  child: Container(
                    width: dotSize,
                    height: dotSize,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: color,
                    ),
                  ),
                ),
              ),
            );
          },
        );
      }),
    );
  }
}
