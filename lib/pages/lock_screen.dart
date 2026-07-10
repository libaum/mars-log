import 'package:flutter/material.dart';
import 'package:mars_log/logic/lock_manager.dart';
import 'package:mars_log/services/service_locator.dart';
import 'package:mars_log/theme/theme_constants.dart';

/// Shown while the app is locked. Offers biometric unlock and/or PIN entry
/// depending on what the user enabled.
class LockScreen extends StatefulWidget {
  const LockScreen({super.key});

  @override
  State<LockScreen> createState() => _LockScreenState();
}

class _LockScreenState extends State<LockScreen> {
  final _lock = getIt<LockManager>();
  final _pinController = TextEditingController();
  String? _error;

  @override
  void initState() {
    super.initState();
    if (_lock.biometricEnabled) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _tryBiometric());
    }
  }

  @override
  void dispose() {
    _pinController.dispose();
    super.dispose();
  }

  Future<void> _tryBiometric() async {
    await _lock.authenticateBiometric();
  }

  Future<void> _submitPin() async {
    final ok = await _lock.verifyPin(_pinController.text);
    if (!ok && mounted) {
      setState(() => _error = 'Falscher PIN');
      _pinController.clear();
    }
  }

  @override
  Widget build(BuildContext context) {
    final primary = Theme.of(context).colorScheme.primary;

    return Scaffold(
      body: SafeArea(
        child: Center(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 48),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.lock_outline, size: 40, color: primary),
                const SizedBox(height: 16),
                Text('Mars Log', style: TEXT_STYLE_STATUS),
                const SizedBox(height: 48),
                if (_lock.pinEnabled) ...[
                  TextField(
                    controller: _pinController,
                    autofocus: !_lock.biometricEnabled,
                    obscureText: true,
                    keyboardType: TextInputType.number,
                    textAlign: TextAlign.center,
                    style: TEXT_STYLE_SCORE.copyWith(fontSize: 28),
                    decoration: const InputDecoration(hintText: 'PIN'),
                    onSubmitted: (_) => _submitPin(),
                  ),
                  const SizedBox(height: 20),
                  TextButton(
                    onPressed: _submitPin,
                    child: const Text('Entsperren', style: TEXT_STYLE_SETTING),
                  ),
                ],
                if (_lock.biometricEnabled)
                  TextButton(
                    onPressed: _tryBiometric,
                    child: const Text('Biometrie verwenden',
                        style: TEXT_STYLE_SETTING),
                  ),
                if (_error != null) ...[
                  const SizedBox(height: 16),
                  Text(_error!, style: TEXT_STYLE_STATUS),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
