import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:mars_log/services/service_locator.dart';
import 'package:mars_log/sync/sync_service.dart';
import 'package:mars_log/theme/theme_constants.dart';

/// Pairing and status for the sync to the owner's relay. Reached from Settings.
///
/// Three independent steps: the relay (URL + device token), the shared
/// encryption key, and then sync itself. Unlike mars_thoughts, Mars Log is
/// never the first device — the key already exists — so *pasting* it is the
/// primary action and generating a new one the secondary.
class SyncScreen extends StatefulWidget {
  const SyncScreen({super.key});

  @override
  State<SyncScreen> createState() => _SyncScreenState();
}

class _SyncScreenState extends State<SyncScreen> {
  final _sync = getIt<SyncService>();

  String? _deviceId;
  bool _hasKey = false;
  bool _busy = false;
  String? _message;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    final deviceId = await _sync.deviceId;
    final hasKey = await _sync.hasEncryptionKey;
    if (!mounted) return;
    setState(() {
      _deviceId = deviceId;
      _hasKey = hasKey;
    });
  }

  Future<void> _guard(Future<void> Function() action) async {
    setState(() {
      _busy = true;
      _message = null;
    });
    try {
      await action();
    } catch (e) {
      if (mounted) setState(() => _message = e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
      await _refresh();
    }
  }

  Future<void> _pairRelay() async {
    final result = await _prompt(
      title: 'Relay',
      fields: const ['Server-URL', 'Geräte-Token'],
      initial: [_sync.serverUrl ?? 'https://', ''],
      obscure: const [false, true],
    );
    if (result == null) return;
    await _guard(() async {
      await _sync.pairDevice(serverUrl: result[0], token: result[1]);
      _message = 'Gekoppelt als „${await _sync.deviceId}“';
    });
  }

  Future<void> _generateKey() async {
    final confirmed = await _confirm(
      'Neuen Schlüssel erzeugen?',
      'Nur, wenn noch kein Gerät einen hat. Mars Thoughts hat normalerweise '
          'schon einen — dann hier „Einfügen“. Ein zweiter Schlüssel passt '
          'nicht zum Relay und wird beim ersten Sync abgewiesen.',
    );
    if (!confirmed) return;
    await _guard(() async {
      final key = await _sync.generateEncryptionKey();
      await _showKey(key);
    });
  }

  Future<void> _importKey() async {
    final result = await _prompt(
      title: 'Schlüssel',
      fields: const ['Schlüssel aus KeePassXC'],
      initial: const [''],
      obscure: const [true],
    );
    if (result == null) return;
    await _guard(() async {
      await _sync.importEncryptionKey(result[0]);
      _message = 'Schlüssel gespeichert';
    });
  }

  Future<void> _showKey([String? key]) async {
    final value = key ?? await _sync.exportEncryptionKey();
    if (value == null || !mounted) return;
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Schlüssel'),
        content: SelectableText(
          value,
          style: const TextStyle(fontSize: 13, fontFamily: 'monospace'),
        ),
        actions: [
          TextButton(
            onPressed: () {
              Clipboard.setData(ClipboardData(text: value));
              Navigator.pop(context);
            },
            child: const Text('Kopieren'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Schließen'),
          ),
        ],
      ),
    );
  }

  Future<void> _unpair() async {
    final confirmed = await _confirm(
      'Kopplung aufheben?',
      'Entfernt Relay-Kopplung und Schlüssel von diesem Gerät. Die Einträge '
          'bleiben, wo sie sind — hier und auf dem Relay.',
    );
    if (!confirmed) return;
    await _guard(_sync.unpair);
  }

  @override
  Widget build(BuildContext context) {
    final primary = Theme.of(context).colorScheme.primary;

    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(28, 20, 28, 20),
          child: ValueListenableBuilder<SyncStatus>(
            valueListenable: _sync.statusNotifier,
            builder: (context, status, _) {
              return ListView(
                children: [
                  Text(
                    'Sync',
                    style: TextStyle(
                      fontSize: 28,
                      fontWeight: FontWeight.w300,
                      color: primary,
                    ),
                  ),
                  const SizedBox(height: 32),
                  _Step(
                    label: 'Relay',
                    detail: _deviceId == null
                        ? 'Nicht gekoppelt'
                        : '${_sync.serverUrl}\nals „$_deviceId“',
                    action: _deviceId == null ? 'Koppeln' : 'Neu koppeln',
                    onTap: _busy ? null : _pairRelay,
                  ),
                  _Step(
                    label: 'Schlüssel',
                    detail: _hasKey ? 'Auf diesem Gerät gespeichert' : 'Fehlt',
                    action: _hasKey ? 'Zeigen' : 'Einfügen',
                    onTap: _busy ? null : (_hasKey ? _showKey : _importKey),
                    secondaryAction: _hasKey ? null : 'Neu',
                    onSecondaryTap: _busy || _hasKey ? null : _generateKey,
                  ),
                  _Step(
                    label: 'Status',
                    detail: _describe(status),
                    action: status.isPaired ? 'Jetzt syncen' : null,
                    onTap: _busy || status.phase == SyncPhase.syncing
                        ? null
                        : _sync.syncNow,
                  ),
                  if (_message != null) ...[
                    const SizedBox(height: 24),
                    Text(
                      _message!,
                      style: const TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w300,
                        color: COLOR_SECONDARY,
                      ),
                    ),
                  ],
                  if (_deviceId != null || _hasKey) ...[
                    const SizedBox(height: 48),
                    _Step(
                      label: 'Entkoppeln',
                      detail: 'Relay und Schlüssel auf diesem Gerät vergessen',
                      action: 'Entkoppeln',
                      onTap: _busy ? null : _unpair,
                    ),
                  ],
                ],
              );
            },
          ),
        ),
      ),
    );
  }

  String _describe(SyncStatus status) {
    final last = status.lastSyncedAt == null
        ? 'noch nie gesynct'
        : 'zuletzt ${_ago(status.lastSyncedAt!)}';
    final skipped = status.undecryptable == 0
        ? ''
        : '\n${status.undecryptable} Eintrag/Einträge auf dem Relay nicht entschlüsselbar';
    return switch (status.phase) {
      SyncPhase.unpaired => 'Erst oben koppeln',
      SyncPhase.syncing => 'Synchronisiere …',
      SyncPhase.idle => '$last$skipped',
      SyncPhase.error => '${status.error}\n$last',
    };
  }

  static String _ago(DateTime time) {
    final diff = DateTime.now().difference(time);
    if (diff.inMinutes < 1) return 'gerade eben';
    if (diff.inMinutes < 60) return 'vor ${diff.inMinutes} Min.';
    if (diff.inHours < 24) return 'vor ${diff.inHours} Std.';
    if (diff.inDays < 7) return 'vor ${diff.inDays} T.';
    return 'am ${time.day}.${time.month}.${time.year}';
  }

  Future<bool> _confirm(String title, String body) async {
    final result = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: Text(
          body,
          style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w300),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Abbrechen'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Weiter'),
          ),
        ],
      ),
    );
    return result ?? false;
  }

  Future<List<String>?> _prompt({
    required String title,
    required List<String> fields,
    required List<String> initial,
    required List<bool> obscure,
  }) async {
    final controllers = [
      for (var i = 0; i < fields.length; i++)
        TextEditingController(text: initial[i]),
    ];
    final result = await showDialog<List<String>>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (var i = 0; i < fields.length; i++)
              TextField(
                controller: controllers[i],
                autocorrect: false,
                enableSuggestions: false,
                obscureText: obscure[i],
                style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w300),
                decoration: InputDecoration(
                  labelText: fields[i],
                  labelStyle: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w300,
                    color: COLOR_SECONDARY,
                  ),
                ),
              ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Abbrechen'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(
              context,
              [for (final c in controllers) c.text],
            ),
            child: const Text('Speichern'),
          ),
        ],
      ),
    );
    for (final c in controllers) {
      c.dispose();
    }
    return result;
  }
}

class _Step extends StatelessWidget {
  final String label;
  final String detail;
  final String? action;
  final VoidCallback? onTap;
  final String? secondaryAction;
  final VoidCallback? onSecondaryTap;

  const _Step({
    required this.label,
    required this.detail,
    this.action,
    this.onTap,
    this.secondaryAction,
    this.onSecondaryTap,
  });

  @override
  Widget build(BuildContext context) {
    final primary = Theme.of(context).colorScheme.primary;
    return Padding(
      padding: const EdgeInsets.only(bottom: 28),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: TextStyle(
                    fontSize: 19,
                    fontWeight: FontWeight.w300,
                    color: primary,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  detail,
                  style: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w300,
                    color: COLOR_SECONDARY,
                    height: 1.4,
                  ),
                ),
              ],
            ),
          ),
          if (action != null)
            _ActionText(label: action!, onTap: onTap),
          if (secondaryAction != null) ...[
            const SizedBox(width: 16),
            _ActionText(label: secondaryAction!, onTap: onSecondaryTap),
          ],
        ],
      ),
    );
  }
}

class _ActionText extends StatelessWidget {
  final String label;
  final VoidCallback? onTap;

  const _ActionText({required this.label, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final primary = Theme.of(context).colorScheme.primary;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.w300,
            color: onTap == null ? COLOR_SECONDARY : primary,
          ),
        ),
      ),
    );
  }
}
