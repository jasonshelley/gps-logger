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
  const StatTile({super.key, required this.label, required this.value, this.icon});
  final String label;
  final String value;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final cs = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      decoration: BoxDecoration(color: cs.surfaceContainer, borderRadius: BorderRadius.circular(16)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
        Row(children: [
          if (icon != null) ...[Icon(icon, size: 16, color: cs.primary), const SizedBox(width: 6)],
          Flexible(
            child: Text(label,
                style: t.labelMedium?.copyWith(color: cs.onSurfaceVariant), overflow: TextOverflow.ellipsis),
          ),
        ]),
        const SizedBox(height: 4),
        Text(value,
            style: t.titleLarge?.copyWith(fontWeight: FontWeight.w700),
            maxLines: 1,
            overflow: TextOverflow.ellipsis),
      ]),
    );
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
