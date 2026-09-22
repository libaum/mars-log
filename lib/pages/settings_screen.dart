import 'package:flutter/material.dart';
import 'package:mars_log/data/export_service.dart';
import 'package:mars_log/data/local_storage_service.dart';
import 'package:mars_log/data/on_device_analysis_service.dart';
import 'package:mars_log/domain/journal_entry.dart';
import 'package:mars_log/logic/journal_manager.dart';
import 'package:mars_log/logic/location_tracking_manager.dart';
import 'package:mars_log/logic/notification_manager.dart';
import 'package:mars_log/logic/settings_manager.dart';
import 'package:mars_log/logic/lock_manager.dart';
import 'package:mars_log/pages/about_screen.dart';
import 'package:mars_log/pages/trash_screen.dart';
import 'package:mars_log/pages/widgets/double_tap_theme_toggle.dart';
import 'package:mars_log/services/service_locator.dart';
import 'package:mars_log/theme/theme_constants.dart';
import 'package:mars_log/theme/theme_manager.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  final _themeManager = getIt<ThemeManager>();
  final _settings = getIt<SettingsManager>();
  final _lock = getIt<LockManager>();
  final _export = getIt<ExportService>();
  final _journal = getIt<JournalManager>();
  final _notifications = getIt<NotificationManager>();
  final _locationTracking = getIt<LocationTrackingManager>();
  final _storage = getIt<LocalStorageService>();
  final _onDevice = getIt<OnDeviceAnalysisEngine>();
  bool _preparingModels = false;

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
    if (value && !ok) _snack('Notifications not allowed.');
  }

  Future<void> _toggleLocationTracking(bool value) async {
    final ok = await _locationTracking.setEnabled(value);
    if (value && !ok) _snack('Standortzugriff nicht erlaubt.');
  }

  Future<void> _toggleDeleteAudio(bool value) async {
    await _storage.setDeleteAudioAfterTranscription(value);
    setState(() {});
  }

  Future<void> _toggleAnalysisEngine(bool onDevice) async {
    await _settings.setAnalysisEngine(onDevice ? 'on_device' : 'cloud');
  }

  Future<void> _prepareOnDeviceModels() async {
    setState(() => _preparingModels = true);
    try {
      await _onDevice.ensureWhisperModelDownloaded();
      final nanoOk = await _onDevice.isNanoAvailable();
      _snack(
        nanoOk
            ? 'Whisper-Modell bereit, Gemini Nano verfügbar.'
            : 'Whisper-Modell bereit, Gemini Nano ist auf diesem Gerät nicht verfügbar.',
      );
    } catch (e) {
      _snack('Vorbereitung fehlgeschlagen: $e');
    } finally {
      if (mounted) setState(() => _preparingModels = false);
    }
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
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
    }
  }

  @override
  Widget build(BuildContext context) {
    final primary = Theme.of(context).colorScheme.primary;
    return DoubleTapThemeToggle(
      child: Scaffold(
        body: SafeArea(
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const SizedBox(height: 32),
                Padding(
                  padding: const EdgeInsets.fromLTRB(40, 0, 50, 0),
                  child: Text(
                    'Settings',
                    style: TEXT_STYLE_SETTINGS_TITLE.copyWith(color: primary),
                  ),
                ),
                const SizedBox(height: 40),

                ValueListenableBuilder<ThemeMode>(
                  valueListenable: _themeManager.themeModeNotifier,
                  builder: (context, _, _) {
                    final isDark =
                        Theme.of(context).brightness == Brightness.dark;
                    return _navRow(
                      'Appearance',
                      trailing: isDark ? 'Dark' : 'Light',
                      onTap: _themeManager.toggleTheme,
                    );
                  },
                ),
                ValueListenableBuilder<bool>(
                  valueListenable: _settings.hasApiKeyNotifier,
                  builder: (context, hasKey, _) => _actionRow(
                    hasKey ? 'Gemini API key · Set' : 'Gemini API key',
                    _editApiKey,
                  ),
                ),
                ValueListenableBuilder<bool>(
                  valueListenable: _settings.pinEnabledNotifier,
                  builder: (context, enabled, _) => _toggleRow(
                    'PIN lock',
                    'Protect the app with a PIN on open',
                    enabled,
                    () => _togglePin(!enabled),
                  ),
                ),
                ValueListenableBuilder<bool>(
                  valueListenable: _settings.biometricEnabledNotifier,
                  builder: (context, enabled, _) => _toggleRow(
                    'Biometrics',
                    'Fingerprint / Face Unlock',
                    enabled,
                    () => _toggleBiometric(!enabled),
                  ),
                ),
                ValueListenableBuilder<bool>(
                  valueListenable: _notifications.enabledNotifier,
                  builder: (context, enabled, _) => Column(
                    children: [
                      _toggleRow(
                        'Reminder',
                        'Remind me in the evening to log',
                        enabled,
                        () => _toggleReminder(!enabled),
                      ),
                      if (enabled)
                        ValueListenableBuilder<TimeOfDay>(
                          valueListenable: _notifications.timeNotifier,
                          builder: (context, time, _) => _valueRow(
                            'Time',
                            time.format(context),
                            _pickReminderTime,
                          ),
                        ),
                    ],
                  ),
                ),
                ValueListenableBuilder<bool>(
                  valueListenable: _locationTracking.enabledNotifier,
                  builder: (context, enabled, _) => _toggleRow(
                    'Standort-Tracking',
                    'Erfasst mehrmals täglich deinen Standort im Hintergrund',
                    enabled,
                    () => _toggleLocationTracking(!enabled),
                  ),
                ),
                _toggleRow(
                  'Delete audio after transcription',
                  'Saves space — the transcript stays',
                  _storage.getDeleteAudioAfterTranscription(),
                  () => _toggleDeleteAudio(
                    !_storage.getDeleteAudioAfterTranscription(),
                  ),
                ),
                ValueListenableBuilder<String>(
                  valueListenable: _settings.analysisEngineNotifier,
                  builder: (context, engine, _) => Column(
                    children: [
                      _toggleRow(
                        'Offline-Modus (Beta)',
                        'Analyse lokal via Whisper + Gemini Nano statt Cloud — experimentell, braucht ein unterstütztes Gerät',
                        engine == 'on_device',
                        () => _toggleAnalysisEngine(engine != 'on_device'),
                      ),
                      if (engine == 'on_device')
                        _actionRow(
                          _preparingModels
                              ? 'Modelle werden vorbereitet…'
                              : 'Modelle vorbereiten',
                          _preparingModels ? () {} : _prepareOnDeviceModels,
                        ),
                    ],
                  ),
                ),
                _actionRow('Export (share)', _doExport),
                _actionRow('Export (save to device)', _doExportToDisk),
                _actionRow('Import', _doImport),
                ValueListenableBuilder<List<JournalEntry>>(
                  valueListenable: _journal.trashNotifier,
                  builder: (context, trash, _) => _navRow(
                    'Trash',
                    trailing: trash.isEmpty ? null : '${trash.length}',
                    onTap: () => Navigator.push(
                      context,
                      MaterialPageRoute(builder: (_) => const TrashScreen()),
                    ),
                  ),
                ),
                _navRow(
                  'About',
                  onTap: () => Navigator.push(
                    context,
                    MaterialPageRoute(builder: (_) => const AboutScreen()),
                  ),
                ),
                const SizedBox(height: 20),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _valueRow(String label, String value, VoidCallback onTap) {
    return InkWell(
      onTap: onTap,
      splashColor: Colors.transparent,
      highlightColor: Colors.transparent,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(40, 20, 50, 20),
        child: Row(
          children: [
            Expanded(child: Text(label, style: TEXT_STYLE_SETTINGS_ITEM)),
            SizedBox(
              width: 60,
              child: Center(
                child: Text(value, style: TEXT_STYLE_SETTINGS_TRAILING),
              ),
            ),
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
        padding: const EdgeInsets.fromLTRB(40, 20, 50, 20),
        child: Text(label, style: TEXT_STYLE_SETTINGS_ITEM),
      ),
    );
  }

  Widget _navRow(
    String label, {
    String? trailing,
    required VoidCallback onTap,
  }) {
    final primary = Theme.of(context).colorScheme.primary;
    return InkWell(
      onTap: onTap,
      splashColor: Colors.transparent,
      highlightColor: Colors.transparent,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(40, 20, 50, 20),
        child: Row(
          children: [
            Expanded(child: Text(label, style: TEXT_STYLE_SETTINGS_ITEM)),
            SizedBox(
              width: 60,
              child: Center(
                child: trailing != null
                    ? Text(trailing, style: TEXT_STYLE_SETTINGS_TRAILING)
                    : Icon(
                        Icons.chevron_right,
                        size: 20,
                        color: primary.withValues(alpha: 0.3),
                      ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _toggleRow(
    String label,
    String description,
    bool value,
    VoidCallback onTap,
  ) {
    return InkWell(
      onTap: onTap,
      splashColor: Colors.transparent,
      highlightColor: Colors.transparent,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(40, 20, 50, 20),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(label, style: TEXT_STYLE_SETTINGS_ITEM),
                  const SizedBox(height: 2),
                  Text(description, style: TEXT_STYLE_SETTINGS_DESCRIPTION),
                ],
              ),
            ),
            SizedBox(
              width: 60,
              child: Center(
                child: Text(
                  value ? 'On' : 'Off',
                  style: TEXT_STYLE_SETTINGS_TRAILING,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
