import 'package:flutter/material.dart';

import '../main.dart';
import '../sync/logger_eraser.dart';
import 'format.dart';
import 'widgets.dart';

/// The word to type before "Erase all data" goes ahead.
const eraseWord = 'ERASE';

/// Asks twice before erasing everything on the phone: first what goes, then
/// typing ERASE. Returns true only if the person typed it and tapped Erase.
Future<bool> confirmEraseAll(BuildContext context, {required int trips, required int catches}) async {
  final step1 = await showDialog<bool>(
    context: context,
    builder: (c) {
      final t = Theme.of(c).textTheme;
      return AlertDialog(
        icon: Icon(Icons.delete_forever_rounded, color: Theme.of(c).colorScheme.error),
        title: const Text('Erase all data?'),
        content: SingleChildScrollView(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
            Text('This deletes from this phone:', style: t.bodyMedium),
            const SizedBox(height: 8),
            for (final line in [
              '$trips ${trips == 1 ? 'trip' : 'trips'}, real and sample',
              '$catches ${catches == 1 ? 'catch' : 'catches'}, and which photos go with them',
              'The trip meter and the all-time totals',
              'Cached weather and tides',
              'The log files received from the logger',
              'A meter reset still waiting for the logger',
            ])
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text('•  ', style: t.bodyMedium),
                  Expanded(child: Text(line, style: t.bodyMedium)),
                ]),
              ),
            const SizedBox(height: 8),
            Text('Your photos stay in the gallery. The logger isn\'t touched: you can erase it next, '
                'while it\'s connected.', style: t.bodyMedium),
            const SizedBox(height: 8),
            Text('This can\'t be undone.', style: t.bodyMedium?.copyWith(fontWeight: FontWeight.w700)),
          ]),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.pop(c, true), child: const Text('Continue')),
        ],
      );
    },
  );
  if (step1 != true || !context.mounted) return false;
  final step2 = await showDialog<bool>(context: context, builder: (_) => const _TypeToErase());
  return step2 == true;
}

class _TypeToErase extends StatefulWidget {
  const _TypeToErase();
  @override
  State<_TypeToErase> createState() => _TypeToEraseState();
}

class _TypeToEraseState extends State<_TypeToErase> {
  final _text = TextEditingController();
  bool get _ok => _text.text.trim().toUpperCase() == eraseWord;

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return AlertDialog(
      title: const Text('Type $eraseWord to confirm'),
      content: SingleChildScrollView(
        child: TextField(
          controller: _text,
          autofocus: true,
          textCapitalization: TextCapitalization.characters,
          autocorrect: false,
          enableSuggestions: false,
          decoration: const InputDecoration(hintText: eraseWord, border: OutlineInputBorder()),
          onChanged: (_) => setState(() {}),
          onSubmitted: (_) {
            if (_ok) Navigator.pop(context, true);
          },
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
        FilledButton(
          style: FilledButton.styleFrom(backgroundColor: cs.error, foregroundColor: cs.onError),
          onPressed: _ok ? () => Navigator.pop(context, true) : null,
          child: const Text('Erase'),
        ),
      ],
    );
  }
}

/// Erases the logger's log files over a live connection. Shows the files not
/// yet synced, so nothing goes without the person seeing it.
class EraseLoggerScreen extends StatefulWidget {
  const EraseLoggerScreen({super.key, this.controller});

  /// For tests; otherwise one is made that talks to the logger over Bluetooth.
  final EraseLoggerController? controller;

  static Route<void> route() => MaterialPageRoute(builder: (_) => const EraseLoggerScreen());

  @override
  State<EraseLoggerScreen> createState() => _EraseLoggerScreenState();
}

class _EraseLoggerScreenState extends State<EraseLoggerScreen> {
  late final EraseLoggerController _c;
  bool _made = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_made) return;
    _made = true;
    final repo = AppScope.of(context).repo;
    _c = widget.controller ?? EraseLoggerController(onMeterReset: repo.meterResetByLogger);
    if (widget.controller == null) _c.start();
  }

  @override
  void dispose() {
    if (widget.controller == null) _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: _c,
      builder: (context, _) => PopScope(
        canPop: _c.phase != EraseLoggerPhase.erasing,
        child: Scaffold(
          appBar: AppBar(
            leading: IconButton(
              icon: const Icon(Icons.close_rounded),
              tooltip: 'Close',
              onPressed: _c.phase == EraseLoggerPhase.erasing ? null : () => Navigator.of(context).maybePop(),
            ),
            title: const Text('Erase logger files'),
          ),
          body: SafeArea(
            child: LayoutBuilder(
              builder: (context, box) => SingleChildScrollView(
                padding: const EdgeInsets.symmetric(vertical: 24),
                child: ConstrainedBox(
                  constraints: BoxConstraints(minHeight: box.maxHeight - 48),
                  child: Center(child: _body(context)),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _body(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final close = OutlinedButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Close'));
    switch (_c.phase) {
      case EraseLoggerPhase.connecting:
      case EraseLoggerPhase.erasing:
        final erasing = _c.phase == EraseLoggerPhase.erasing;
        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 32),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            const SizedBox(width: 56, height: 56, child: CircularProgressIndicator(strokeWidth: 5)),
            const SizedBox(height: 28),
            Text(erasing ? 'Erasing…' : 'Looking for the logger',
                style: Theme.of(context).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w700),
                textAlign: TextAlign.center),
            const SizedBox(height: 12),
            Text(
              erasing ? 'Keep the logger close until it\'s done.' : 'Put the logger\'s switch on Transfer and keep it close.',
              style: Theme.of(context).textTheme.bodyLarge?.copyWith(color: cs.onSurfaceVariant, height: 1.4),
              textAlign: TextAlign.center,
            ),
          ]),
        );
      case EraseLoggerPhase.needsFirmware:
        return MessageView(
          icon: Icons.system_update_rounded,
          title: 'Update the logger firmware',
          body: 'This logger runs protocol version ${_c.version}. Erasing its files needs version '
              '$eraseProtocolVersion or later. Flash the latest firmware, then try again. Nothing was erased.',
          actions: [close],
        );
      case EraseLoggerPhase.confirm:
        return _Confirm(controller: _c);
      case EraseLoggerPhase.done:
        return _Done(controller: _c);
      case EraseLoggerPhase.failed:
        return MessageView(
          icon: Icons.error_outline_rounded,
          iconColor: cs.onErrorContainer,
          iconBackground: cs.errorContainer,
          title: 'The logger wasn\'t erased',
          body: _c.error ?? 'Something went wrong.',
          actions: [FilledButton(onPressed: _c.start, child: const Text('Try again')), close],
        );
    }
  }
}

class _Confirm extends StatelessWidget {
  const _Confirm({required this.controller});
  final EraseLoggerController controller;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final t = Theme.of(context).textTheme;
    final files = controller.unsynced;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24),
      child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Center(
          child: Container(
            width: 96,
            height: 96,
            decoration: BoxDecoration(color: cs.errorContainer, shape: BoxShape.circle),
            child: Icon(Icons.delete_forever_rounded, size: 46, color: cs.onErrorContainer),
          ),
        ),
        const SizedBox(height: 24),
        Text('Erase every log file on the logger?',
            style: t.headlineSmall?.copyWith(fontWeight: FontWeight.w700), textAlign: TextAlign.center),
        const SizedBox(height: 12),
        Text(
          'This deletes all of its log files, including the ones already synced, and sets its trip meter to zero. '
          'It can\'t be undone.',
          style: t.bodyLarge?.copyWith(color: cs.onSurfaceVariant, height: 1.4),
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 20),
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: files.isEmpty ? cs.surfaceContainerHigh : cs.errorContainer,
            borderRadius: BorderRadius.circular(16),
          ),
          child: files.isEmpty
              ? Row(children: [
                  Icon(Icons.check_circle_rounded, color: cs.primary),
                  const SizedBox(width: 12),
                  Expanded(child: Text('Every file on the logger has been synced to a phone.', style: t.bodyMedium)),
                ])
              : Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(
                    '${files.length} ${files.length == 1 ? 'file hasn\'t' : 'files haven\'t'} been synced and would be lost:',
                    style: t.titleSmall?.copyWith(color: cs.onErrorContainer, fontWeight: FontWeight.w700),
                  ),
                  const SizedBox(height: 8),
                  for (final f in files)
                    Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Row(children: [
                        Expanded(child: Text(f.name, style: t.bodyMedium?.copyWith(color: cs.onErrorContainer))),
                        const SizedBox(width: 12),
                        Text(Fmt.bytes(f.size), style: t.bodyMedium?.copyWith(color: cs.onErrorContainer)),
                      ]),
                    ),
                ]),
        ),
        const SizedBox(height: 28),
        FilledButton(
          style: FilledButton.styleFrom(backgroundColor: cs.error, foregroundColor: cs.onError),
          onPressed: controller.erase,
          child: Text(files.isEmpty ? 'Erase the logger' : 'Erase, losing ${files.length} unsynced'),
        ),
        const SizedBox(height: 10),
        OutlinedButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Cancel')),
      ]),
    );
  }
}

class _Done extends StatelessWidget {
  const _Done({required this.controller});
  final EraseLoggerController controller;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final t = Theme.of(context).textTheme;
    final r = controller.result;
    final n = r?.deletedFiles ?? 0;
    final failed = r?.failedFiles ?? 0;
    final since = controller.phoneResetAt;
    final notes = <String>[
      if (r?.resetNotSaved == true)
        'The logger couldn\'t save its new meter start to the card. If it restarts before the next sync, '
            'its meter may count from the old time.',
    ];
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24),
      child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Center(
          child: Container(
            width: 96,
            height: 96,
            decoration: BoxDecoration(
                color: failed == 0 ? cs.primaryContainer : cs.errorContainer, shape: BoxShape.circle),
            child: Icon(failed == 0 ? Icons.check_rounded : Icons.warning_amber_rounded,
                size: 46, color: failed == 0 ? cs.onPrimaryContainer : cs.onErrorContainer),
          ),
        ),
        const SizedBox(height: 24),
        Text(failed == 0 ? 'Logger erased' : 'Logger partly erased',
            style: t.headlineSmall?.copyWith(fontWeight: FontWeight.w700), textAlign: TextAlign.center),
        const SizedBox(height: 12),
        Text(
          [
            'It deleted $n log ${n == 1 ? 'file' : 'files'}, and its trip meter is back to zero.',
            if (since != null) 'The trip meter on this phone now counts from ${Fmt.date(since)}, ${Fmt.time(since)} too.',
          ].join(' '),
          style: t.bodyLarge?.copyWith(color: cs.onSurfaceVariant, height: 1.4),
          textAlign: TextAlign.center,
        ),
        if (failed > 0) ...[
          const SizedBox(height: 20),
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(color: cs.errorContainer, borderRadius: BorderRadius.circular(16)),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(
                '$failed ${failed == 1 ? 'file' : 'files'} couldn\'t be deleted and ${failed == 1 ? 'is' : 'are'} '
                'still on the logger${controller.remaining.isEmpty ? '.' : ':'}',
                style: t.titleSmall?.copyWith(color: cs.onErrorContainer, fontWeight: FontWeight.w700),
              ),
              for (final f in controller.remaining)
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Row(children: [
                    Expanded(child: Text(f.name, style: t.bodyMedium?.copyWith(color: cs.onErrorContainer))),
                    const SizedBox(width: 12),
                    Text(Fmt.bytes(f.size), style: t.bodyMedium?.copyWith(color: cs.onErrorContainer)),
                  ]),
                ),
              const SizedBox(height: 8),
              Text(
                controller.remaining.length < failed
                    ? 'Files already synced (in /uploaded) aren\'t listed. Try erasing again, or check the card on a computer.'
                    : 'Try erasing again, or check the card on a computer.',
                style: t.bodyMedium?.copyWith(color: cs.onErrorContainer),
              ),
            ]),
          ),
        ],
        for (final note in notes) ...[
          const SizedBox(height: 16),
          Text(note, style: t.bodyMedium?.copyWith(color: cs.onSurfaceVariant), textAlign: TextAlign.center),
        ],
        const SizedBox(height: 28),
        if (failed > 0) ...[
          FilledButton(onPressed: controller.start, child: const Text('Erase again')),
          const SizedBox(height: 10),
        ],
        (failed > 0 ? OutlinedButton.new : FilledButton.new)(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Done'),
        ),
      ]),
    );
  }
}
