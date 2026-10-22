import 'dart:async';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:get_it/get_it.dart';
import 'package:mars_log/data/analysis_engine.dart';
import 'package:mars_log/data/export_service.dart';
import 'package:mars_log/data/journal_repository.dart';
import 'package:mars_log/data/local_storage_service.dart';
import 'package:mars_log/data/gemini_engine.dart';
import 'package:mars_log/data/secure_storage_service.dart';
import 'package:mars_log/data/usage_repository.dart';
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
import 'package:mars_log/logic/usage_tracking_manager.dart';
import 'package:mars_log/sync/sync_purge_trace.dart';
import 'package:mars_log/sync/journal_sync_repository.dart';
import 'package:mars_log/sync/pairing.dart';
import 'package:mars_log/theme/theme_manager.dart';
import 'package:mars_sync_flutter/mars_sync_flutter.dart';
import 'package:mars_sync_flutter/secure_sync_key_store.dart';

final getIt = GetIt.instance;

Future<void> setupServiceLocator() async {
  // Async storage first — everything else reads it in its constructor.
  getIt.registerSingleton<LocalStorageService>(
    await LocalStorageService.getInstance(),
  );
  getIt.registerSingleton<SecureStorageService>(SecureStorageService());

  final journal = await JournalRepository.getInstance(
    purgeTrace: SyncPurgeTrace(getIt<LocalStorageService>()),
  );
  getIt.registerSingleton<JournalRepository>(journal);

  final usage = await UsageRepository.open();
  getIt.registerSingleton<UsageRepository>(usage);

  // Never throws; an unpaired or broken pairing just reports it in status.
  final syncStorage = getIt<LocalStorageService>();
  final sync = SyncService(
    prefs: LogPairingPrefs(syncStorage),
    // Where the installed app's secrets are — changing the options loses them.
    keys: SecureSyncKeyStore(const FlutterSecureStorage(
      aOptions: AndroidOptions(encryptedSharedPreferences: true),
    )),
    // The phone-usage days sync along with the journal.
    repository: (deviceId) => JournalSyncRepository(
      journal: journal,
      storage: syncStorage,
      deviceId: deviceId,
      usage: usage,
    ),
    strings: logSyncStrings,
  );
  await sync.init();
  getIt.registerSingleton<SyncService>(sync);
  getIt.registerSingleton<LocationHistoryRepository>(
    await LocationHistoryRepository.getInstance(),
  );
  getIt.registerSingleton<GoogleTimelineImportService>(
    GoogleTimelineImportService(getIt<LocationHistoryRepository>()),
  );
  getIt.registerSingleton<LocationService>(LocationService());

  // Transcription, analysis and people: Gemini. Models from Settings.
  final secure = getIt<SecureStorageService>();
  final storage = getIt<LocalStorageService>();
  unawaited(secure.deleteOldKeys());
  getIt.registerSingleton<AnalysisEngine>(GeminiEngine(
    apiKey: () => secure.getApiKey(),
    transcriptionModelId: () => storage.getTranscriptionModel() ?? kDefaultTranscriptionModel,
    analysisModelId: () => storage.getAnalysisModel() ?? kDefaultAnalysisModel,
  ));


  getIt.registerSingleton<ThemeManager>(ThemeManager());
  getIt.registerSingleton<SettingsManager>(SettingsManager());
  getIt.registerSingleton<RecordingManager>(RecordingManager());
  getIt.registerSingleton<AnalysisTaskService>(AnalysisTaskService());
  getIt.registerSingleton<JournalManager>(JournalManager());
  getIt.registerSingleton<ExportService>(
    ExportService(
      getIt<JournalRepository>(),
      getIt<LocationHistoryRepository>(),
      usage: usage,
    ),
  );
  getIt.registerSingleton<LockManager>(LockManager());

  // Exactly once, before any manager registers a periodic task: the plugin
  // keeps a single callback handle, so initializing per-feature would leave
  // only the last one working.
  await initializeBackgroundTasks();

  final locationTracking = LocationTrackingManager();
  getIt.registerSingleton<LocationTrackingManager>(locationTracking);
  await locationTracking.init();

  final usageTracking = UsageTrackingManager(usage);
  getIt.registerSingleton<UsageTrackingManager>(usageTracking);
  await usageTracking.init();

  final dailyExport = DailyExportManager();
  getIt.registerSingleton<DailyExportManager>(dailyExport);
  await dailyExport.init();

  final notifications = NotificationManager();
  getIt.registerSingleton<NotificationManager>(notifications);
  await notifications.init();
}
