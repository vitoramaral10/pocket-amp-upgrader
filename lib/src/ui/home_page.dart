// SPDX-License-Identifier: GPL-3.0-only

import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;

import '../firmware_package.dart';
import '../midi/midi_backend.dart';
import '../pedal_updater.dart';

/// Official download link published on M-VAVE's downloads page. The file is
/// fetched from M-VAVE's own server; this app never redistributes it.
const String officialFirmwareUrl =
    'https://yms-file-store.oss-cn-hongkong.aliyuncs.com/software/firmware/Pocket%20AMP.fwsc';

enum _Stage { idle, updating, success, failed }

class HomePage extends StatefulWidget {
  const HomePage({super.key, this.backend});

  /// Injected in tests; the platform backend otherwise.
  final MidiBackend? backend;

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  late final PedalUpdater _updater;
  final List<String> _log = <String>[];

  FirmwarePackage? _package;
  String? _packageSource;
  String? _packageError;
  bool _loadingPackage = false;

  DetectedPedal? _pedal;
  bool _detecting = false;
  bool _detectedOnce = false;

  _Stage _stage = _Stage.idle;
  UpdateProgress? _progress;
  String? _resultMessage;

  @override
  void initState() {
    super.initState();
    _updater = PedalUpdater(
      widget.backend ?? MidiBackend.forPlatform(),
      log: _addLog,
    );
    // Detection only sends the identity query, so it is safe to run unasked.
    WidgetsBinding.instance.addPostFrameCallback((_) => _detect());
  }

  void _addLog(String line) {
    final String stamp = DateTime.now().toIso8601String().substring(11, 19);
    setState(() => _log.add('$stamp  $line'));
  }

  bool get _busy => _stage == _Stage.updating || _detecting || _loadingPackage;

  List<String> get _blockers => _package != null && _pedal != null
      ? _updater.blockers(_package!, _pedal!)
      : const <String>[];

  bool get _canUpdate =>
      !_busy && _package != null && _pedal != null && _blockers.isEmpty;

  // --- actions --------------------------------------------------------------

  Future<void> _openFile() async {
    final XFile? file = await openFile(
      acceptedTypeGroups: const <XTypeGroup>[
        XTypeGroup(
          label: 'M-VAVE firmware',
          extensions: <String>['fwsc'],
          uniformTypeIdentifiers: <String>['public.data'],
        ),
      ],
    );
    if (file == null) {
      return;
    }
    await _loadPackage(() => file.readAsBytes(), file.name);
  }

  Future<void> _download() async {
    await _loadPackage(() async {
      _addLog('Downloading $officialFirmwareUrl');
      final http.Response r = await http
          .get(Uri.parse(officialFirmwareUrl))
          .timeout(const Duration(seconds: 60));
      if (r.statusCode != 200) {
        throw HttpException('HTTP ${r.statusCode}');
      }
      return r.bodyBytes;
    }, 'M-VAVE download');
  }

  Future<void> _loadPackage(
    Future<List<int>> Function() read,
    String source,
  ) async {
    setState(() {
      _loadingPackage = true;
      _packageError = null;
    });
    try {
      final FirmwarePackage p = FirmwarePackage.parse(
        Uint8List.fromList(await read()),
      );
      _addLog('Package "${p.product}" from $source, sha256 ${p.sha256}');
      setState(() {
        _package = p;
        _packageSource = source;
      });
    } catch (e) {
      _addLog('Package rejected: $e');
      setState(() {
        _package = null;
        _packageError = '$e';
      });
    } finally {
      setState(() => _loadingPackage = false);
    }
  }

  Future<void> _detect() async {
    setState(() {
      _detecting = true;
      _pedal = null;
    });
    try {
      final DetectedPedal? p = await _updater.detect();
      if (p == null) {
        _addLog('No pedal answered.');
      }
      setState(() => _pedal = p);
    } catch (e) {
      _addLog('Detection failed: $e');
    } finally {
      setState(() {
        _detecting = false;
        _detectedOnce = true;
      });
    }
  }

  Future<void> _confirmAndUpdate() async {
    final bool? go = await showDialog<bool>(
      context: context,
      builder: (BuildContext context) =>
          _ConfirmDialog(from: _pedal!.identity, to: _package!.product),
    );
    if (go != true) {
      return;
    }
    setState(() {
      _stage = _Stage.updating;
      _progress = null;
      _resultMessage = null;
    });
    try {
      final String after = await _updater.update(
        _package!,
        _pedal!,
        (UpdateProgress p) => setState(() => _progress = p),
      );
      setState(() {
        _stage = _Stage.success;
        _resultMessage = 'The pedal restarted as $after.';
        _pedal = null;
      });
    } catch (e) {
      _addLog('Update failed: $e');
      setState(() {
        _stage = _Stage.failed;
        _resultMessage = '$e';
        _pedal = null;
      });
    }
  }

  // --- view -----------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Pocket AMP Upgrader'),
        actions: <Widget>[
          IconButton(
            tooltip: 'About',
            icon: const Icon(Icons.info_outline),
            onPressed: () => showAboutDialog(
              context: context,
              applicationName: 'Pocket AMP Upgrader',
              applicationLegalese:
                  'Community tool, not affiliated with M-VAVE.\n'
                  'GPL-3.0. Update protocol from M-VAVE\'s FM1 Open project.',
            ),
          ),
        ],
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 720),
          child: ListView(
            padding: const EdgeInsets.all(16),
            children: <Widget>[
              if (_stage == _Stage.updating)
                _ProgressCard(progress: _progress)
              else ...<Widget>[
                if (_stage == _Stage.success || _stage == _Stage.failed)
                  _ResultCard(
                    success: _stage == _Stage.success,
                    message: _resultMessage ?? '',
                    onDismiss: () => setState(() => _stage = _Stage.idle),
                  ),
                _firmwareCard(theme),
                const SizedBox(height: 12),
                _pedalCard(theme),
                const SizedBox(height: 12),
                const _WarningCard(),
                const SizedBox(height: 16),
                for (final String b in _blockers)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Text(
                      b,
                      style: TextStyle(color: theme.colorScheme.error),
                    ),
                  ),
                FilledButton.icon(
                  onPressed: _canUpdate ? _confirmAndUpdate : null,
                  icon: const Icon(Icons.system_update_alt),
                  label: Text(
                    _pedal?.inLoader == true
                        ? 'Resume update'
                        : 'Update firmware',
                  ),
                  style: FilledButton.styleFrom(
                    minimumSize: const Size.fromHeight(52),
                  ),
                ),
              ],
              const SizedBox(height: 16),
              _LogPanel(lines: _log),
            ],
          ),
        ),
      ),
    );
  }

  Widget _firmwareCard(ThemeData theme) {
    final FirmwarePackage? p = _package;
    return _StepCard(
      number: 1,
      title: 'Firmware file',
      done: p != null,
      children: <Widget>[
        if (p != null) ...<Widget>[
          _InfoRow('Product', p.productFamily),
          _InfoRow('Version', p.version),
          _InfoRow('Source', _packageSource ?? ''),
          _InfoRow('SHA-256', '${p.sha256.substring(0, 16)}…'),
          _InfoRow(
            'Loader',
            p.hasKnownLoader ? 'known, verified' : 'UNKNOWN (refused)',
          ),
          const SizedBox(height: 8),
        ] else if (_packageError != null) ...<Widget>[
          Text(
            'Not a valid package: $_packageError',
            style: TextStyle(color: theme.colorScheme.error),
          ),
          const SizedBox(height: 8),
        ] else
          const Padding(
            padding: EdgeInsets.only(bottom: 8),
            child: Text(
              'Use the official .fwsc file from M-VAVE. Download it here or '
              'open one you already have.',
            ),
          ),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: <Widget>[
            FilledButton.tonalIcon(
              onPressed: _busy ? null : _download,
              icon: const Icon(Icons.cloud_download_outlined),
              label: const Text('Download from M-VAVE'),
            ),
            OutlinedButton.icon(
              onPressed: _busy ? null : _openFile,
              icon: const Icon(Icons.folder_open),
              label: const Text('Open .fwsc file…'),
            ),
            if (_loadingPackage)
              const Padding(
                padding: EdgeInsets.all(8),
                child: SizedBox.square(
                  dimension: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              ),
          ],
        ),
      ],
    );
  }

  Widget _pedalCard(ThemeData theme) {
    final DetectedPedal? p = _pedal;
    return _StepCard(
      number: 2,
      title: 'Pedal',
      done: p != null,
      children: <Widget>[
        if (p != null) ...<Widget>[
          _InfoRow('Model', p.family),
          _InfoRow('Installed', p.inLoader ? 'update mode' : p.version),
          _InfoRow('Port', p.port.name),
          if (p.inLoader)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                'The pedal is waiting in update mode, probably from an '
                'interrupted update. Updating again will finish the job.',
                style: TextStyle(color: theme.colorScheme.tertiary),
              ),
            ),
          const SizedBox(height: 8),
        ] else
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Text(
              _detectedOnce
                  ? 'No Pocket AMP found. Connect it with a USB data cable, '
                        'turn it on, close the M-VAVE app and try again.'
                  : 'Connect the pedal by USB, turn it on and close any other '
                        'app that uses MIDI.',
            ),
          ),
        Wrap(
          spacing: 8,
          children: <Widget>[
            FilledButton.tonalIcon(
              onPressed: _busy ? null : _detect,
              icon: _detecting
                  ? const SizedBox.square(
                      dimension: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.usb),
              label: Text(p == null ? 'Detect pedal' : 'Detect again'),
            ),
          ],
        ),
      ],
    );
  }
}

class _StepCard extends StatelessWidget {
  const _StepCard({
    required this.number,
    required this.title,
    required this.done,
    required this.children,
  });

  final int number;
  final String title;
  final bool done;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              children: <Widget>[
                CircleAvatar(
                  radius: 14,
                  backgroundColor: done
                      ? theme.colorScheme.primary
                      : theme.colorScheme.surfaceContainerHighest,
                  foregroundColor: done
                      ? theme.colorScheme.onPrimary
                      : theme.colorScheme.onSurfaceVariant,
                  child: done
                      ? const Icon(Icons.check, size: 16)
                      : Text('$number'),
                ),
                const SizedBox(width: 12),
                Text(title, style: theme.textTheme.titleMedium),
              ],
            ),
            const SizedBox(height: 12),
            ...children,
          ],
        ),
      ),
    );
  }
}

class _InfoRow extends StatelessWidget {
  const _InfoRow(this.label, this.value);
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          SizedBox(
            width: 96,
            child: Text(
              label,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          Expanded(child: SelectableText(value)),
        ],
      ),
    );
  }
}

class _WarningCard extends StatelessWidget {
  const _WarningCard();

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Card(
      color: theme.colorScheme.errorContainer,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: DefaultTextStyle.merge(
          style: TextStyle(color: theme.colorScheme.onErrorContainer),
          child: const Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(
                'Before you update',
                style: TextStyle(fontWeight: FontWeight.w600),
              ),
              SizedBox(height: 8),
              Text(
                '• Back up your presets first. The V1.05 update was seen '
                'overwriting presets P01–P05 and P80 and resetting their EQ.\n'
                '• Charge the battery and use a reliable USB data cable.\n'
                '• Do not unplug, turn off or let the computer sleep until the '
                'app says it is done (about 2 minutes).\n'
                '• Use at your own risk. This is a community tool, not '
                'affiliated with M-VAVE.',
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ProgressCard extends StatelessWidget {
  const _ProgressCard({required this.progress});
  final UpdateProgress? progress;

  static const List<(UpdatePhase, String)> _steps = <(UpdatePhase, String)>[
    (UpdatePhase.preparing, 'Checking the pedal'),
    (UpdatePhase.loader, 'Sending the update loader'),
    (UpdatePhase.waitingLoader, 'Waiting for update mode'),
    (UpdatePhase.flash, 'Writing the firmware'),
    (UpdatePhase.rebooting, 'Waiting for the pedal to restart'),
  ];

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final UpdatePhase current = progress?.phase ?? UpdatePhase.preparing;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text('Updating…', style: theme.textTheme.headlineSmall),
            const SizedBox(height: 4),
            Text(
              'Do not unplug or turn off the pedal.',
              style: TextStyle(
                color: theme.colorScheme.error,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 16),
            for (final (UpdatePhase phase, String label) in _steps)
              _phaseRow(theme, phase, label, current),
          ],
        ),
      ),
    );
  }

  Widget _phaseRow(
    ThemeData theme,
    UpdatePhase phase,
    String label,
    UpdatePhase current,
  ) {
    final bool done = phase.index < current.index;
    final bool active = phase == current;
    final double? fraction = active ? progress?.fraction : null;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Icon(
                done
                    ? Icons.check_circle
                    : active
                    ? Icons.radio_button_checked
                    : Icons.radio_button_unchecked,
                size: 20,
                color: done || active
                    ? theme.colorScheme.primary
                    : theme.colorScheme.outline,
              ),
              const SizedBox(width: 12),
              Expanded(child: Text(label)),
              if (fraction != null) Text('${(fraction * 100).floor()}%'),
            ],
          ),
          if (active)
            Padding(
              padding: const EdgeInsets.only(left: 32, top: 6),
              child: LinearProgressIndicator(value: fraction),
            ),
        ],
      ),
    );
  }
}

class _ResultCard extends StatelessWidget {
  const _ResultCard({
    required this.success,
    required this.message,
    required this.onDismiss,
  });

  final bool success;
  final String message;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final Color bg = success
        ? theme.colorScheme.primaryContainer
        : theme.colorScheme.errorContainer;
    final Color fg = success
        ? theme.colorScheme.onPrimaryContainer
        : theme.colorScheme.onErrorContainer;
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Card(
        color: bg,
        child: ListTile(
          leading: Icon(
            success ? Icons.check_circle : Icons.error_outline,
            color: fg,
          ),
          title: Text(
            success ? 'Update finished' : 'Update failed',
            style: TextStyle(color: fg, fontWeight: FontWeight.w600),
          ),
          subtitle: Text(message, style: TextStyle(color: fg)),
          trailing: IconButton(
            icon: Icon(Icons.close, color: fg),
            onPressed: onDismiss,
          ),
        ),
      ),
    );
  }
}

class _ConfirmDialog extends StatefulWidget {
  const _ConfirmDialog({required this.from, required this.to});
  final String from;
  final String to;

  @override
  State<_ConfirmDialog> createState() => _ConfirmDialogState();
}

class _ConfirmDialogState extends State<_ConfirmDialog> {
  bool _understood = false;

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      icon: const Icon(Icons.warning_amber_rounded),
      title: const Text('Write new firmware?'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text('${widget.from}  →  ${widget.to}'),
          const SizedBox(height: 12),
          const Text(
            'An interrupted update can leave the pedal unusable. Keep it '
            'connected and powered until the app says it is done.',
          ),
          const SizedBox(height: 8),
          CheckboxListTile(
            contentPadding: EdgeInsets.zero,
            value: _understood,
            onChanged: (bool? v) => setState(() => _understood = v ?? false),
            title: const Text('I backed up my presets and accept the risk.'),
            controlAffinity: ListTileControlAffinity.leading,
          ),
        ],
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _understood ? () => Navigator.pop(context, true) : null,
          child: const Text('Update'),
        ),
      ],
    );
  }
}

class _LogPanel extends StatelessWidget {
  const _LogPanel({required this.lines});
  final List<String> lines;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Card(
      clipBehavior: Clip.antiAlias,
      child: ExpansionTile(
        title: const Text('Details'),
        subtitle: Text('${lines.length} log lines'),
        children: <Widget>[
          Align(
            alignment: Alignment.centerRight,
            child: TextButton.icon(
              onPressed: lines.isEmpty
                  ? null
                  : () => Clipboard.setData(
                      ClipboardData(
                        text:
                            '${Platform.operatingSystem} '
                            '${Platform.operatingSystemVersion}\n'
                            '${lines.join('\n')}',
                      ),
                    ),
              icon: const Icon(Icons.copy, size: 18),
              label: const Text('Copy for a bug report'),
            ),
          ),
          Container(
            width: double.infinity,
            constraints: const BoxConstraints(maxHeight: 240),
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            child: SingleChildScrollView(
              reverse: true,
              child: SelectableText(
                lines.join('\n'),
                style: theme.textTheme.bodySmall?.copyWith(
                  fontFamily: 'monospace',
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
