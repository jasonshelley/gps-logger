import 'package:flutter/material.dart';

import 'theme.dart';

/// A pill showing an angler's catch count in their colour.
class AnglerCount extends StatelessWidget {
  const AnglerCount(this.angler, this.count, {super.key, this.dense = false});
  final String angler;
  final int count;
  final bool dense;

  @override
  Widget build(BuildContext context) {
    final c = anglerColor(angler);
    final t = Theme.of(context).textTheme;
    final faded = count == 0;
    return Container(
      padding: EdgeInsets.symmetric(horizontal: dense ? 8 : 10, vertical: dense ? 3 : 5),
      decoration: BoxDecoration(
        color: c.withValues(alpha: faded ? 0.06 : 0.16),
        borderRadius: BorderRadius.circular(99),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Container(
          width: dense ? 7 : 8,
          height: dense ? 7 : 8,
          decoration: BoxDecoration(color: faded ? c.withValues(alpha: 0.4) : c, shape: BoxShape.circle),
        ),
        SizedBox(width: dense ? 5 : 6),
        Text(angler, style: (dense ? t.labelMedium : t.labelLarge)),
        SizedBox(width: dense ? 5 : 6),
        Text('$count',
            style: (dense ? t.labelMedium : t.labelLarge)
                ?.copyWith(fontWeight: FontWeight.w800, fontFeatures: const [FontFeature.tabularFigures()])),
      ]),
    );
  }
}

/// A labelled number, for stats grids.
class StatTile extends StatelessWidget {
  const StatTile({super.key, required this.label, required this.value, this.icon, this.iconColor});
  final String label;
  final String value;
  final IconData? icon;
  final Color? iconColor;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final cs = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      decoration: BoxDecoration(color: cs.surfaceContainer, borderRadius: BorderRadius.circular(16)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          if (icon != null) ...[Icon(icon, size: 16, color: iconColor ?? cs.primary), const SizedBox(width: 6)],
          Expanded(
            child: Text(label,
                style: t.labelMedium?.copyWith(color: cs.onSurfaceVariant),
                maxLines: 2,
                overflow: TextOverflow.ellipsis),
          ),
        ]),
        const SizedBox(height: 4),
        Text(value,
            style: t.titleLarge?.copyWith(fontWeight: FontWeight.w700),
            maxLines: 2,
            overflow: TextOverflow.ellipsis),
      ]),
    );
  }
}

/// Stat tiles two to a row. Each row is as tall as its tallest tile, so the
/// tiles fit any text size without a fixed height.
class StatGrid extends StatelessWidget {
  const StatGrid({super.key, required this.children, this.spacing = 10});
  final List<Widget> children;
  final double spacing;

  @override
  Widget build(BuildContext context) {
    final rows = <Widget>[];
    for (var i = 0; i < children.length; i += 2) {
      if (rows.isNotEmpty) rows.add(SizedBox(height: spacing));
      rows.add(IntrinsicHeight(
        child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Expanded(child: children[i]),
          SizedBox(width: spacing),
          Expanded(child: i + 1 < children.length ? children[i + 1] : const SizedBox.shrink()),
        ]),
      ));
    }
    return Column(mainAxisSize: MainAxisSize.min, children: rows);
  }
}

/// Full-page message for empty and error states.
class MessageView extends StatelessWidget {
  const MessageView({
    super.key,
    required this.icon,
    required this.title,
    required this.body,
    this.actions = const [],
    this.iconColor,
    this.iconBackground,
  });

  final IconData icon;
  final String title;
  final String body;
  final List<Widget> actions;
  final Color? iconColor;
  final Color? iconBackground;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final t = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 32),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Container(
          width: 112,
          height: 112,
          decoration: BoxDecoration(color: iconBackground ?? cs.primaryContainer, shape: BoxShape.circle),
          child: Icon(icon, size: 52, color: iconColor ?? cs.onPrimaryContainer),
        ),
        const SizedBox(height: 28),
        Text(title, style: t.headlineSmall?.copyWith(fontWeight: FontWeight.w700), textAlign: TextAlign.center),
        const SizedBox(height: 12),
        Text(body,
            style: t.bodyLarge?.copyWith(color: cs.onSurfaceVariant, height: 1.4), textAlign: TextAlign.center),
        if (actions.isNotEmpty) ...[
          const SizedBox(height: 32),
          ...actions.expand((a) => [SizedBox(width: double.infinity, child: a), const SizedBox(height: 10)]),
        ],
      ]),
    );
  }
}
