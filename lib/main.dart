import 'package:flutter/material.dart';
import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:mars_log/logic/journal_manager.dart';
import 'package:mars_log/logic/lock_manager.dart';
import 'package:mars_log/pages/lock_screen.dart';
import 'package:mars_log/pages/main_screen.dart';
import 'package:mars_log/services/service_locator.dart';
import 'package:mars_log/sync/sync_service.dart';
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
          locale: const Locale('de'),
          supportedLocales: const [Locale('de')],
          localizationsDelegates: const [
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
          ],
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
  final _journal = getIt<JournalManager>();
  final _sync = getIt<SyncService>();
  StreamSubscription<List<ConnectivityResult>>? _connectivity;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // Pick up anything left half-analysed by a killed or frozen process.
    _journal.resumePending();
    // Back online: entries waiting for a connection go now, not at the end
    // of their backoff.
    _connectivity = Connectivity().onConnectivityChanged.listen((results) {
      if (results.any((r) => r != ConnectivityResult.none)) {
        _journal.resumePending(now: true);
      }
    });
    // A cold launch doesn't replay `resumed` to observers added here, so the
    // first round is kicked off explicitly.
    _sync.syncNow();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _connectivity?.cancel();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused) {
      _lock.lockIfEnabled();
      // Best-effort on the way out: the OS may freeze the process mid-request,
      // and the next resume repeats whatever didn't land.
      _sync.syncNow();
    } else if (state == AppLifecycleState.resumed) {
      _journal.resumePending(now: true);
      _sync.syncNow();
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
