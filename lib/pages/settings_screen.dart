import 'package:flutter/material.dart';
import 'package:mars_log/data/export_service.dart';
import 'package:mars_log/data/journal_repository.dart';
import 'package:mars_log/data/google_timeline_import_service.dart';
import 'package:mars_log/data/local_storage_service.dart';
import 'package:mars_log/data/gemini_engine.dart';
import 'package:mars_log/data/secure_storage_service.dart';
import 'package:mars_log/domain/journal_entry.dart';
import 'package:mars_log/logic/daily_export_manager.dart';
import 'package:mars_log/logic/journal_manager.dart';
import 'package:mars_log/logic/location_tracking_manager.dart';
import 'package:mars_log/logic/notification_manager.dart';
import 'package:mars_log/logic/settings_manager.dart';
import 'package:mars_log/logic/lock_manager.dart';
import 'package:mars_log/pages/about_screen.dart';
import 'package:mars_log/pages/sync_screen.dart';
import 'package:mars_log/pages/trash_screen.dart';
import 'package:mars_log/pages/widgets/confirm_dialog.dart';
import 'package:mars_log/pages/widgets/double_tap_theme_toggle.dart';
import 'package:mars_log/services/service_locator.dart';
import 'package:mars_log/sync/sync_service.dart';
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
  final _dailyExport = getIt<DailyExportManager>();
  final _timelineImport = getIt<GoogleTimelineImportService>();
  bool _importingTimeline = false;
  final _storage = getIt<LocalStorageService>();
  final _secure = getIt<SecureStorageService>();

  Future<void> _doExportToDisk() async {
    try {
      final folder = await _export.exportToFolder();
      if (folder != null) _snack('Gespeichert in $folder.');
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
    final result = await _locationTracking.setEnabled(value);
    if (!mounted) return;
    switch (result) {
      case LocationTrackingResult.denied:
        _snack('Standortzugriff nicht erlaubt.');
      case LocationTrackingResult.enabledForegroundOnly:
        // Registering the job "worked", but Android starves it in the
        // background without "Immer zulassen" — say so instead of pretending.
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            duration: const Duration(seconds: 8),
            content: const Text(
                'Standort steht auf „Nur bei App-Nutzung" — im Hintergrund '
                'wird dann kaum etwas erfasst.'),
            action: SnackBarAction(
              label: 'Einstellungen',
              onPressed: _locationTracking.openSystemSettings,
            ),
          ),
        );
      case LocationTrackingResult.off:
      case LocationTrackingResult.enabled:
        break;
    }
  }

  Future<void> _importTimeline() async {
    setState(() => _importingTimeline = true);
    try {
      final count = await _timelineImport.importFromPicker();
      if (count != null) _snack('$count Standortpunkte importiert.');
    } catch (e) {
      _snack('Import fehlgeschlagen: $e');
    } finally {
      if (mounted) setState(() => _importingTimeline = false);
    }
  }

  Future<void> _pickDailyExportFolder() async {
    final ok = await _dailyExport.pickFolder();
    if (!ok) return;
    if (mounted) setState(() {});
  }

  Future<void> _toggleDailyExport(bool value) async {
    final ok = await _dailyExport.setEnabled(value);
    if (value && !ok) _snack('Erst einen Ordner wählen.');
  }

  Future<void> _toggleDeleteAudio(bool value) async {
    await _storage.setDeleteAudioAfterTranscription(value);
    setState(() {});
  }

  Future<void> _editApiKey() async {
    final controller = TextEditingController(text: await _secure.getApiKey() ?? '');
    if (!mounted) return;
    final result = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Gemini API-Key', style: TEXT_STYLE_SETTING),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(controller: controller, autofocus: true),
            const SizedBox(height: 12),
            const Text(
              'Aus Google AI Studio. Mit hinterlegter Zahlungsart nutzt Google '
              'deine Aufnahmen und Texte nicht zum Training — außerhalb der EU '
              'gilt das sonst nicht.',
              style: TEXT_STYLE_SETTINGS_DESCRIPTION,
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Abbrechen'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, controller.text),
            child: const Text('Speichern'),
          ),
        ],
      ),
    );
    if (result == null) return;
    await _secure.setApiKey(result);
    if (mounted) setState(() {});
    // Entries that failed for want of a key go now.
    if (result.trim().isNotEmpty) _journal.retryFailed();
  }

  /// [transcription]: the transcription model, else the analysis model.
  Future<void> _editModel({required bool transcription}) async {
    final current = transcription
        ? _storage.getTranscriptionModel() ?? kDefaultTranscriptionModel
        : _storage.getAnalysisModel() ?? kDefaultAnalysisModel;
    final controller = TextEditingController(text: current);
    final result = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(
          transcription ? 'Modell: Transkription' : 'Modell: Analyse',
          style: TEXT_STYLE_SETTING,
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(controller: controller, autofocus: true),
            const SizedBox(height: 12),
            Text(
              'Gemini-Modell-ID. Leer: ${transcription ? kDefaultTranscriptionModel : kDefaultAnalysisModel}.',
              style: TEXT_STYLE_SETTINGS_DESCRIPTION,
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Abbrechen'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, controller.text),
            child: const Text('Speichern'),
          ),
        ],
      ),
    );
    if (result == null) return;
    if (transcription) {
      await _storage.setTranscriptionModel(result);
    } else {
      await _storage.setAnalysisModel(result);
    }
    if (mounted) setState(() {});
  }

  Future<void> _backfillPeople() async {
    final due = _journal.peopleBackfillDue;
    final all = due == 0;
    if (all) {
      final ok = await showConfirmDialog(
        context,
        title: 'Alle Personen neu erkennen?',
        message: 'Alle Einträge sind schon mit der aktuellen Erkennung '
            'ausgewertet. Noch einmal alle durchgehen? Was du von Hand '
            'korrigiert hast, bleibt.',
        confirmLabel: 'Neu erkennen',
      );
      if (!ok) return;
    }
    final result = await _journal.backfillPeople(all: all);
    if (!mounted) return;
    _snack(result.failed == 0
        ? '${result.done} Einträge ausgewertet.'
        : '${result.done - result.failed} von ${result.total} ausgewertet, '
            '${result.failed} fehlgeschlagen${result.lastError == null ? '' : ' (${result.lastError})'}.');
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
                _actionRow(
                  _importingTimeline
                      ? 'Zeitachse wird importiert…'
                      : 'Google-Zeitachse importieren',
                  _importingTimeline ? () {} : _importTimeline,
                ),
                _toggleRow(
                  'Delete audio after transcription',
                  'Saves space — the transcript stays',
                  _storage.getDeleteAudioAfterTranscription(),
                  () => _toggleDeleteAudio(
                    !_storage.getDeleteAudioAfterTranscription(),
                  ),
                ),
                _navRow(
                  'Selbsteinschätzung',
                  trailing: _storage.getSelfRatingTiming() == kRatedBefore ? 'Vorher' : 'Nachher',
                  onTap: () async {
                    await _storage.setSelfRatingTiming(
                      _storage.getSelfRatingTiming() == kRatedBefore ? kRatedAfter : kRatedBefore,
                    );
                    setState(() {});
                  },
                ),
                FutureBuilder<String?>(
                  future: _secure.getApiKey(),
                  builder: (context, snap) => _navRow(
                    'Gemini API-Key',
                    trailing: (snap.data ?? '').isEmpty ? 'Fehlt' : 'Gesetzt',
                    onTap: _editApiKey,
                  ),
                ),
                _textRow(
                  'Modell: Transkription',
                  _storage.getTranscriptionModel() ?? kDefaultTranscriptionModel,
                  () => _editModel(transcription: true),
                ),
                _textRow(
                  'Modell: Analyse',
                  _storage.getAnalysisModel() ?? kDefaultAnalysisModel,
                  () => _editModel(transcription: false),
                ),
                ValueListenableBuilder<BackfillProgress?>(
                  valueListenable: _journal.backfill,
                  builder: (context, progress, _) {
                    if (progress != null) {
                      return _actionRow(
                        'Personen werden erkannt… ${progress.done} / ${progress.total}',
                        () {},
                      );
                    }
                    final due = _journal.peopleBackfillDue;
                    return _actionRow(
                      due > 0
                          ? 'Personen neu erkennen ($due Einträge)'
                          : 'Alle Personen neu erkennen',
                      _backfillPeople,
                    );
                  },
                ),
                _actionRow('Export', _doExportToDisk),
                _actionRow('Import', _doImport),
                ValueListenableBuilder<String?>(
                  valueListenable: _dailyExport.folderNameNotifier,
                  builder: (context, folderName, _) => Column(
                    children: [
                      _navRow(
                        'Sicherungsordner',
                        trailing: folderName ?? 'Nicht gewählt',
                        onTap: _pickDailyExportFolder,
                      ),
                      ValueListenableBuilder<bool>(
                        valueListenable: _dailyExport.enabledNotifier,
                        builder: (context, enabled, _) => _toggleRow(
                          'Tägliche Sicherung',
                          'Sichert automatisch einmal täglich in den gewählten Ordner',
                          enabled,
                          () => _toggleDailyExport(!enabled),
                        ),
                      ),
                    ],
                  ),
                ),
                ValueListenableBuilder<SyncStatus>(
                  valueListenable: getIt<SyncService>().statusNotifier,
                  builder: (context, status, _) => _navRow(
                    'Sync',
                    trailing: switch (status.phase) {
                      SyncPhase.unpaired => 'Aus',
                      SyncPhase.error => 'Fehler',
                      _ => null,
                    },
                    onTap: () => Navigator.push(
                      context,
                      MaterialPageRoute(builder: (_) => const SyncScreen()),
                    ),
                  ),
                ),
                ValueListenableBuilder<bool>(
                  valueListenable: getIt<JournalRepository>().corruptIndex,
                  builder: (context, corrupt, _) => corrupt
                      ? _navRow(
                          'Beschädigter Index',
                          trailing: '!',
                          onTap: _discardCorruptIndex,
                        )
                      : const SizedBox.shrink(),
                ),
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

  Future<void> _discardCorruptIndex() async {
    final ok = await showConfirmDialog(
      context,
      title: 'Beschädigter Index',
      message: 'Das Journal war nicht lesbar und wurde beiseitegelegt. '
          'Es steckt in jedem Export, und bis du es verwirfst, bleiben alle '
          'Aufnahmen erhalten. Mit Sync: entkoppeln und neu koppeln holt die '
          'Einträge vom Relay zurück. Verwerfen löscht beim nächsten Start '
          'jede Aufnahme ohne Eintrag.',
      confirmLabel: 'Verwerfen',
    );
    if (ok) await getIt<JournalRepository>().discardCorruptIndexes();
  }

  /// A setting whose value is too long for the trailing column.
  Widget _textRow(String label, String value, VoidCallback onTap) {
    return InkWell(
      onTap: onTap,
      splashColor: Colors.transparent,
      highlightColor: Colors.transparent,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(40, 20, 50, 20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(label, style: TEXT_STYLE_SETTINGS_ITEM),
            const SizedBox(height: 2),
            Text(value, style: TEXT_STYLE_SETTINGS_DESCRIPTION),
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
