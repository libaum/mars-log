import 'package:mars_log/logic/daily_export_manager.dart';
import 'package:mars_log/logic/location_tracking_manager.dart';
import 'package:workmanager/workmanager.dart';

/// Task names of every periodic job the app registers. They are matched
/// inside [backgroundCallbackDispatcher], so a name only ever lives here.
const kLocationTaskName = 'captureLocation';
const kDailyExportTaskName = 'dailyExport';

/// The app's single WorkManager entry point.
///
/// There can only ever be **one** registered callback dispatcher — the plugin
/// stores one callback handle natively, so a second `initialize` call would
/// silently replace the first and the displaced feature's task would fire
/// into a dispatcher that doesn't know its name. Every background job
/// therefore routes through this one function, and [initializeBackgroundTasks]
/// is called exactly once at startup.
///
/// Android spawns a background isolate that calls straight into this,
/// bypassing `main()` and GetIt, so everything it touches must be able to
/// construct itself standalone.
@pragma('vm:entry-point')
void backgroundCallbackDispatcher() {
  Workmanager().executeTask((task, _) async {
    switch (task) {
      case kLocationTaskName:
        await captureLocationFix();
      case kDailyExportTaskName:
        await runDailyExport();
    }
    return true;
  });
}

Future<void> initializeBackgroundTasks() =>
    Workmanager().initialize(backgroundCallbackDispatcher);
