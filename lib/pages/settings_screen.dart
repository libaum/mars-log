import 'package:flutter/material.dart';
import 'package:mars_log/data/export_service.dart';
import 'package:mars_log/logic/settings_manager.dart';
import 'package:mars_log/logic/lock_manager.dart';
import 'package:mars_log/pages/about_screen.dart';
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
            child: const Text('Abbrechen'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, controller.text),
            child: const Text('Speichern'),
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
      _snack('Export fehlgeschlagen: $e');
    }
  }

  Future<void> _doImport() async {
    try {
      final count = await _export.importFromPicker();
      if (count != null) _snack('$count neue Einträge importiert.');
    } catch (e) {
      _snack('Import fehlgeschlagen: $e');
    }
  }

  Future<void> _togglePin(bool value) async {
    if (value) {
      final pin = await _promptPin();
      if (pin != null && pin.length >= 4) {
        await _settings.setPin(pin);
      } else if (pin != null) {
        _snack('PIN braucht mindestens 4 Ziffern.');
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
        title: const Text('PIN festlegen', style: TEXT_STYLE_SETTING),
        content: TextField(
          controller: controller,
          autofocus: true,
          obscureText: true,
          keyboardType: TextInputType.number,
          decoration: const InputDecoration(hintText: 'Mind. 4 Ziffern'),
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
  }

  Future<void> _toggleBiometric(bool value) async {
    if (value && !await _lock.deviceSupportsBiometrics()) {
      _snack('Keine Biometrie auf diesem Gerät verfügbar.');
      return;
    }
    await _settings.setBiometricEnabled(value);
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
                  'Gemini API-Key',
                  hasKey ? 'gesetzt' : 'nicht gesetzt',
                  _editApiKey,
                ),
              ),
              _divider(),
              _actionRow('Export', _doExport),
              _divider(),
              _actionRow('Import', _doImport),
              _divider(),

              ValueListenableBuilder<bool>(
                valueListenable: _settings.pinEnabledNotifier,
                builder: (context, enabled, _) => _toggleRow(
                  'PIN-Sperre',
                  'App beim Öffnen mit PIN schützen',
                  enabled,
                  _togglePin,
                ),
              ),
              _divider(),
              ValueListenableBuilder<bool>(
                valueListenable: _settings.biometricEnabledNotifier,
                builder: (context, enabled, _) => _toggleRow(
                  'Biometrie',
                  'Fingerabdruck / Face Unlock',
                  enabled,
                  _toggleBiometric,
                ),
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
