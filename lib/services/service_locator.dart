import 'package:get_it/get_it.dart';
import 'package:mars_log/data/analysis_engine.dart';
import 'package:mars_log/data/export_service.dart';
import 'package:mars_log/data/gemini_service.dart';
import 'package:mars_log/data/journal_repository.dart';
import 'package:mars_log/data/local_storage_service.dart';
import 'package:mars_log/data/on_device_analysis_service.dart';
import 'package:mars_log/data/secure_storage_service.dart';
import 'package:mars_log/logic/analysis_task_service.dart';
import 'package:mars_log/logic/background_tasks.dart';
import 'package:mars_log/data/google_timeline_import_service.dart';
import 'package:mars_log/data/location_history_repository.dart';
import 'package:mars_log/logic/daily_export_manager.dart';
import 'package:mars_log/logic/journal_manager.dart';
import 'package:mars_log/logic/location_service.dart';
import 'package:mars_log/logic/location_tracking_manager.dart';
import 'package:mars_log/logic/lock_manager.dart';
import 'package:mars_log/logic/notification_manager.dart';
import 'package:mars_log/logic/recording_manager.dart';
import 'package:mars_log/logic/settings_manager.dart';
import 'package:mars_log/theme/theme_manager.dart';

final getIt = GetIt.instance;

Future<void> setupServiceLocator() async {
  // Async storage first — everything else reads it in its constructor.
  getIt.registerSingleton<LocalStorageService>(
    await LocalStorageService.getInstance(),
  );
  getIt.registerSingleton<SecureStorageService>(SecureStorageService());

  getIt.registerSingleton<JournalRepository>(
    await JournalRepository.getInstance(),
  );
  getIt.registerSingleton<LocationHistoryRepository>(
    await LocationHistoryRepository.getInstance(),
  );
  getIt.registerSingleton<GoogleTimelineImportService>(
    GoogleTimelineImportService(getIt<LocationHistoryRepository>()),
  );
  getIt.registerSingleton<GeminiService>(GeminiService());
  getIt.registerSingleton<LocationService>(LocationService());

  getIt.registerSingleton<CloudAnalysisEngine>(CloudAnalysisEngine());
  getIt.registerSingleton<OnDeviceAnalysisEngine>(OnDeviceAnalysisEngine());

  getIt.registerSingleton<ThemeManager>(ThemeManager());
  getIt.registerSingleton<SettingsManager>(SettingsManager());
  getIt.registerSingleton<RecordingManager>(RecordingManager());
  getIt.registerSingleton<AnalysisTaskService>(AnalysisTaskService());
  getIt.registerSingleton<JournalManager>(JournalManager());
  getIt.registerSingleton<ExportService>(
    ExportService(getIt<JournalRepository>()),
  );
  getIt.registerSingleton<LockManager>(LockManager());

  // Exactly once, before any manager registers a periodic task: the plugin
  // keeps a single callback handle, so initializing per-feature would leave
  // only the last one working.
  await initializeBackgroundTasks();

  final locationTracking = LocationTrackingManager();
  getIt.registerSingleton<LocationTrackingManager>(locationTracking);
  await locationTracking.init();

  final dailyExport = DailyExportManager();
  getIt.registerSingleton<DailyExportManager>(dailyExport);
  await dailyExport.init();

  final notifications = NotificationManager();
  getIt.registerSingleton<NotificationManager>(notifications);
  await notifications.init();
}
