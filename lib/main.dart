import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:mars_log/logic/lock_manager.dart';
import 'package:mars_log/pages/lock_screen.dart';
import 'package:mars_log/pages/main_screen.dart';
import 'package:mars_log/services/service_locator.dart';
import 'package:mars_log/theme/theme_manager.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
  await setupServiceLocator();
  getIt<LockManager>().lockIfEnabled();
  runApp(const MarsLog());
}

class MarsLog extends StatelessWidget {
  const MarsLog({super.key});

  @override
  Widget build(BuildContext context) {
    final themeManager = getIt<ThemeManager>();

    return ValueListenableBuilder<ThemeMode>(
      valueListenable: themeManager.themeModeNotifier,
      builder: (context, themeMode, _) {
        return MaterialApp(
          debugShowCheckedModeBanner: false,
          title: 'Mars Log',
          theme: themeManager.lightTheme,
          darkTheme: themeManager.darkTheme,
          themeMode: themeMode,
          home: const AppRoot(),
          builder: (context, child) {
            final isDark = Theme.of(context).brightness == Brightness.dark;
            final iconBrightness =
                isDark ? Brightness.light : Brightness.dark;
            return AnnotatedRegion<SystemUiOverlayStyle>(
              value: SystemUiOverlayStyle(
                statusBarColor: Colors.transparent,
                statusBarIconBrightness: iconBrightness,
                statusBarBrightness:
                    isDark ? Brightness.dark : Brightness.light,
                systemNavigationBarColor: Colors.transparent,
                systemNavigationBarDividerColor: Colors.transparent,
                systemNavigationBarIconBrightness: iconBrightness,
                systemNavigationBarContrastEnforced: false,
              ),
              child: child!,
            );
          },
        );
      },
    );
  }
}

/// Chooses between the lock screen and the journal, and re-locks the app when
/// it goes to the background.
class AppRoot extends StatefulWidget {
  const AppRoot({super.key});

  @override
  State<AppRoot> createState() => _AppRootState();
}

class _AppRootState extends State<AppRoot> with WidgetsBindingObserver {
  final _lock = getIt<LockManager>();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused) {
      _lock.lockIfEnabled();
    }
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<bool>(
      valueListenable: _lock.lockedNotifier,
      builder: (context, locked, _) =>
          locked ? const LockScreen() : const MainScreen(),
    );
  }
}
