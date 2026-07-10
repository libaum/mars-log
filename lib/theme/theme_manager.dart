import 'package:flutter/material.dart';
import 'package:mars_log/data/local_storage_service.dart';
import 'package:mars_log/services/service_locator.dart';
import 'package:mars_log/theme/theme_constants.dart';

/// Manages dark/light theme, following Mars Launcher pattern.
class ThemeManager {
  final _storage = getIt<LocalStorageService>();

  late final ValueNotifier<ThemeMode> themeModeNotifier;

  ThemeManager() {
    final isDark = _storage.getThemeIsDark();
    if (isDark == null) {
      themeModeNotifier = ValueNotifier(ThemeMode.system);
    } else {
      themeModeNotifier =
          ValueNotifier(isDark ? ThemeMode.dark : ThemeMode.light);
    }
  }

  void toggleTheme() {
    if (themeModeNotifier.value == ThemeMode.dark) {
      themeModeNotifier.value = ThemeMode.light;
    } else {
      // Both system and light → dark
      themeModeNotifier.value = ThemeMode.dark;
    }
    _storage.setThemeIsDark(themeModeNotifier.value == ThemeMode.dark);
  }

  ThemeData get lightTheme => buildLightTheme();
  ThemeData get darkTheme => buildDarkTheme();
}
