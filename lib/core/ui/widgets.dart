import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';

import '../theme/app_theme.dart';

/// Frosted panel that floats over the map
class GlassPanel extends StatelessWidget {
  const GlassPanel({super.key, required this.child, this.padding = EdgeInsets.zero, this.radius = L360.radius});

  final Widget child;
  final EdgeInsetsGeometry padding;
  final double radius;

  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: BoxDecoration(borderRadius: BorderRadius.circular(radius), boxShadow: L360.shadow),
    child: ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 18, sigmaY: 18),
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: 0.82),
            borderRadius: BorderRadius.circular(radius),
            border: Border.all(color: Colors.white.withValues(alpha: 0.6), width: 0.8),
          ),
          child: Padding(padding: padding, child: child),
        ),
      ),
    ),
  );
}

/// Round frosted map button (44 pt), with a light tap haptic
class MapIconButton extends StatelessWidget {
  const MapIconButton({super.key, required this.tooltip, required this.onPressed, required this.child});

  final String tooltip;
  final VoidCallback onPressed;
  final Widget child;

  @override
  Widget build(BuildContext context) => GlassPanel(
    radius: L360.touch / 2,
    child: SizedBox.square(
      dimension: L360.touch,
      child: IconButton(
        tooltip: tooltip,
        padding: EdgeInsets.zero,
        iconSize: 22,
        color: L360Colors.ink,
        onPressed: () {
          HapticFeedback.lightImpact();
          onPressed();
        },
        icon: child,
      ),
    ),
  );
}

/// Small uppercase heading above a group of settings
class SectionLabel extends StatelessWidget {
  const SectionLabel(this.text, {super.key, this.trailing});

  final String text;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(4, 0, 4, 8),
    child: Row(
      children: [
        Text(
          text.toUpperCase(),
          style: const TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.w700,
            letterSpacing: 0.9,
            color: L360Colors.sand500,
          ),
        ),
        const Spacer(),
        ?trailing,
      ],
    ),
  );
}

/// Inset grouped list, like iOS Settings: rows separated by hairlines in one rounded card
class GroupedSection extends StatelessWidget {
  const GroupedSection({super.key, this.title, required this.children, this.footer});

  final String? title;
  final List<Widget> children;
  final String? footer;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 24),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (title != null) SectionLabel(title!),
        Card(
          clipBehavior: Clip.antiAlias,
          child: Column(
            children: [
              for (var i = 0; i < children.length; i++) ...[if (i > 0) const Divider(indent: 56), children[i]],
            ],
          ),
        ),
        if (footer != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 8, 4, 0),
            child: Text(footer!, style: Theme.of(context).textTheme.bodySmall),
          ),
      ],
    ),
  );
}

/// Rounded square icon used at the start of grouped rows
class TileIcon extends StatelessWidget {
  const TileIcon(this.icon, {super.key, this.color = L360Colors.forest700, this.background = L360Colors.forest50});

  final IconData icon;
  final Color color;
  final Color background;

  @override
  Widget build(BuildContext context) => Container(
    width: 30,
    height: 30,
    decoration: BoxDecoration(color: background, borderRadius: BorderRadius.circular(8)),
    child: Icon(icon, size: 18, color: color),
  );
}

/// Pill badge (plan, role, S.O.S)
class Pill extends StatelessWidget {
  const Pill(this.label, {super.key, required this.background, required this.foreground, this.icon});

  final String label;
  final Color background;
  final Color foreground;
  final IconData? icon;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
    decoration: BoxDecoration(color: background, borderRadius: BorderRadius.circular(20)),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (icon != null) ...[Icon(icon, size: 13, color: foreground), const SizedBox(width: 4)],
        Text(
          label,
          style: TextStyle(color: foreground, fontWeight: FontWeight.w700, fontSize: 12),
        ),
      ],
    ),
  );
}

/// Inline error message with an icon
class ErrorBanner extends StatelessWidget {
  const ErrorBanner(this.message, {super.key});

  final String message;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(12),
    decoration: BoxDecoration(
      color: L360Colors.brick50,
      borderRadius: BorderRadius.circular(L360.radiusSmall),
      border: Border.all(color: const Color(0xFFF6BDB7)),
    ),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Icon(Icons.error_outline, size: 20, color: L360Colors.brick500),
        const SizedBox(width: 10),
        Expanded(
          child: Text(message, style: const TextStyle(color: L360Colors.brick600)),
        ),
      ],
    ),
  );
}

/// Button that shows a spinner while busy
class BusyButton extends StatelessWidget {
  const BusyButton({super.key, required this.label, required this.busy, required this.onPressed});

  final String label;
  final bool busy;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) => FilledButton(
    onPressed: busy ? null : onPressed,
    child: busy
        ? const SizedBox.square(dimension: 20, child: CircularProgressIndicator(strokeWidth: 2.2, color: Colors.white))
        : Text(label),
  );
}

/// Reports its child's size after layout (e.g. so a sheet can be as tall as its content)
class MeasureSize extends SingleChildRenderObjectWidget {
  const MeasureSize({super.key, required this.onChange, required super.child});

  final ValueChanged<Size> onChange;

  @override
  RenderObject createRenderObject(BuildContext context) => RenderMeasureSize(onChange);

  @override
  void updateRenderObject(BuildContext context, RenderMeasureSize renderObject) => renderObject.onChange = onChange;
}

class RenderMeasureSize extends RenderProxyBox {
  RenderMeasureSize(this.onChange);

  ValueChanged<Size> onChange;
  Size? _last;

  @override
  void performLayout() {
    super.performLayout();
    final size = this.size;
    if (size == _last) return;
    _last = size;
    WidgetsBinding.instance.addPostFrameCallback((_) => onChange(size));
  }
}
