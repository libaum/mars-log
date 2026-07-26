import 'package:flutter/material.dart';
import 'package:mars_log/data/export_service.dart';
import 'package:mars_log/data/local_storage_service.dart';
import 'package:mars_log/domain/journal_entry.dart';
import 'package:mars_log/logic/journal_manager.dart';
import 'package:mars_log/logic/notification_manager.dart';
import 'package:mars_log/logic/settings_manager.dart';
import 'package:mars_log/logic/lock_manager.dart';
import 'package:mars_log/pages/about_screen.dart';
import 'package:mars_log/pages/trash_screen.dart';
import 'package:mars_log/pages/widgets/double_tap_theme_toggle.dart';
import 'package:mars_log/services/service_locator.dart';
import 'package:mars_log/theme/theme_constants.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  final _settings = getIt<SettingsManager>();
  final _lock = getIt<LockManager>();
  final _export = getIt<ExportService>();
  final _journal = getIt<JournalManager>();
  final _notifications = getIt<NotificationManager>();
  final _storage = getIt<LocalStorageService>();

  Future<void> _editApiKey() async {
    final current = await _settings.getApiKey() ?? '';
    if (!mounted) return;
    final controller = TextEditingController(text: current);
    final result = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Gemini API-Key', style: TEXT_STYLE_SETTING),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(hintText: 'AIza…'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, controller.text),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    if (result != null) await _settings.setApiKey(result);
  }

  Future<void> _doExport() async {
    try {
      await _export.exportAndShare();
    } catch (e) {
      _snack('Export failed: $e');
    }
  }

  Future<void> _doExportToDisk() async {
    try {
      final path = await _export.exportToDisk();
      if (path != null) _snack('Saved.');
    } catch (e) {
      _snack('Save failed: $e');
    }
  }

  Future<void> _doImport() async {
    try {
      final count = await _export.importFromPicker();
      if (count != null) _snack('$count new entries imported.');
    } catch (e) {
      _snack('Import failed: $e');
    }
  }

  Future<void> _togglePin(bool value) async {
    if (value) {
      final pin = await _promptPin();
      if (pin != null && pin.length >= 4) {
        await _settings.setPin(pin);
      } else if (pin != null) {
        _snack('PIN needs at least 4 digits.');
      }
    } else {
      await _settings.disablePin();
    }
  }

  Future<String?> _promptPin() async {
    final controller = TextEditingController();
    return showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Set PIN', style: TEXT_STYLE_SETTING),
        content: TextField(
          controller: controller,
          autofocus: true,
          obscureText: true,
          keyboardType: TextInputType.number,
          decoration: const InputDecoration(hintText: 'At least 4 digits'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, controller.text),
            child: const Text('Save'),
          ),
        ],
      ),
    );
  }

  Future<void> _toggleBiometric(bool value) async {
    if (value && !await _lock.deviceSupportsBiometrics()) {
      _snack('No biometrics available on this device.');
      return;
    }
    await _settings.setBiometricEnabled(value);
  }

  Future<void> _toggleReminder(bool value) async {
    final ok = await _notifications.setEnabled(value);
    if (value && !ok) _snack('Benachrichtigungen nicht erlaubt.');
  }

  Future<void> _toggleDeleteAudio(bool value) async {
    await _storage.setDeleteAudioAfterTranscription(value);
    setState(() {});
  }

  Future<void> _pickReminderTime() async {
    final picked = await showTimePicker(
      context: context,
      initialTime: _notifications.timeNotifier.value,
    );
    if (picked != null) await _notifications.setTime(picked);
  }

  void _snack(String msg) {
    if (mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(msg)));
    }
  }

  @override
  Widget build(BuildContext context) {
    return DoubleTapThemeToggle(
      child: Scaffold(
        body: SafeArea(
          child: ListView(
            children: [
              const SizedBox(height: 32),
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 32),
                child: Text('Settings', style: TEXT_STYLE_TITLE),
              ),
              const SizedBox(height: 40),

              ValueListenableBuilder<bool>(
                valueListenable: _settings.hasApiKeyNotifier,
                builder: (context, hasKey, _) => _valueRow(
                  'Gemini API key',
                  hasKey ? 'set' : 'not set',
                  _editApiKey,
                ),
              ),
              _divider(),
              _actionRow('Export (share)', _doExport),
              _divider(),
              _actionRow('Export (save to device)', _doExportToDisk),
              _divider(),
              _actionRow('Import', _doImport),
              _divider(),

              ValueListenableBuilder<List<JournalEntry>>(
                valueListenable: _journal.trashNotifier,
                builder: (context, trash, _) => _valueRow(
                  'Papierkorb',
                  trash.isEmpty ? '' : '${trash.length}',
                  () => Navigator.push(
                    context,
                    MaterialPageRoute(builder: (_) => const TrashScreen()),
                  ),
                ),
              ),
              _divider(),

              ValueListenableBuilder<bool>(
                valueListenable: _settings.pinEnabledNotifier,
                builder: (context, enabled, _) => _toggleRow(
                  'PIN lock',
                  'Protect the app with a PIN on open',
                  enabled,
                  _togglePin,
                ),
              ),
              _divider(),
              ValueListenableBuilder<bool>(
                valueListenable: _settings.biometricEnabledNotifier,
                builder: (context, enabled, _) => _toggleRow(
                  'Biometrics',
                  'Fingerprint / Face Unlock',
                  enabled,
                  _toggleBiometric,
                ),
              ),
              _divider(),

              ValueListenableBuilder<bool>(
                valueListenable: _notifications.enabledNotifier,
                builder: (context, enabled, _) => Column(
                  children: [
                    _toggleRow(
                      'Erinnerung',
                      'Abends an den Log erinnern',
                      enabled,
                      _toggleReminder,
                    ),
                    if (enabled) ...[
                      _divider(),
                      ValueListenableBuilder<TimeOfDay>(
                        valueListenable: _notifications.timeNotifier,
                        builder: (context, time, _) => _valueRow(
                          'Uhrzeit',
                          time.format(context),
                          _pickReminderTime,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              _divider(),
              _toggleRow(
                'Audio nach Transkription löschen',
                'Spart Speicher — das Transkript bleibt erhalten',
                _storage.getDeleteAudioAfterTranscription(),
                _toggleDeleteAudio,
              ),
              _divider(),
              _navRow('About', () {
                Navigator.push(
                  context,
                  MaterialPageRoute(builder: (_) => const AboutScreen()),
                );
              }),
            ],
          ),
        ),
      ),
    );
  }

  Widget _divider() => Divider(
        height: 1,
        thickness: 0.5,
        indent: 32,
        endIndent: 32,
        color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.1),
      );

  Widget _valueRow(String label, String value, VoidCallback onTap) {
    final primary = Theme.of(context).colorScheme.primary;
    return InkWell(
      onTap: onTap,
      splashColor: Colors.transparent,
      highlightColor: Colors.transparent,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 20),
        child: Row(
          children: [
            Expanded(child: Text(label, style: TEXT_STYLE_SETTING)),
            Text(value, style: const TextStyle(color: COLOR_SECONDARY)),
            Icon(Icons.chevron_right, color: primary.withValues(alpha: 0.3)),
          ],
        ),
      ),
    );
  }

  Widget _actionRow(String label, VoidCallback onTap) {
    return InkWell(
      onTap: onTap,
      splashColor: Colors.transparent,
      highlightColor: Colors.transparent,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 20),
        child: Text(label, style: TEXT_STYLE_SETTING),
      ),
    );
  }

  Widget _navRow(String label, VoidCallback onTap) {
    final primary = Theme.of(context).colorScheme.primary;
    return InkWell(
      onTap: onTap,
      splashColor: Colors.transparent,
      highlightColor: Colors.transparent,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 20),
        child: Row(
          children: [
            Expanded(child: Text(label, style: TEXT_STYLE_SETTING)),
            Icon(Icons.chevron_right, color: primary.withValues(alpha: 0.3)),
          ],
        ),
      ),
    );
  }

  Widget _toggleRow(
    String label,
    String description,
    bool value,
    ValueChanged<bool> onChanged,
  ) {
    final primary = Theme.of(context).colorScheme.primary;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 16),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label, style: TEXT_STYLE_SETTING),
                const SizedBox(height: 4),
                Text(description, style: TEXT_STYLE_STATUS),
              ],
            ),
          ),
          Switch(
            value: value,
            onChanged: onChanged,
            activeThumbColor: primary,
          ),
        ],
      ),
    );
  }
}
