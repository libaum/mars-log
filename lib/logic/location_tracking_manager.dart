import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart';
import 'package:mars_log/data/local_storage_service.dart';
import 'package:mars_log/data/location_history_repository.dart';
import 'package:mars_log/domain/day_location_point.dart';
import 'package:mars_log/services/service_locator.dart';
import 'package:workmanager/workmanager.dart';

const _taskUniqueName = 'mars_log_location_tracking';
const _taskName = 'captureLocation';

/// The WorkManager entry point that runs [captureLocationFix] a few times a
/// day, independent of whether the app is open. Must stay top-level and
/// `vm:entry-point` per the `workmanager` plugin's contract — Android spawns
/// a background isolate that calls straight into this function, bypassing
/// `main()` and GetIt entirely.
@pragma('vm:entry-point')
void locationTrackingCallbackDispatcher() {
  Workmanager().executeTask((task, _) async {
    if (task == _taskName) await captureLocationFix();
    return true;
  });
}

/// Best-effort single GPS fix, appended to [LocationHistoryRepository].
/// Silent on any failure (permission revoked, GPS off, timeout) — a missed
/// fix is unremarkable, the next scheduled run tries again.
Future<void> captureLocationFix() async {
  try {
    if (!await Geolocator.isLocationServiceEnabled()) return;

    final permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied ||
        permission == LocationPermission.deniedForever) {
      return;
    }

    final position = await Geolocator.getCurrentPosition(
      locationSettings: const LocationSettings(
        accuracy: LocationAccuracy.low,
        timeLimit: Duration(seconds: 20),
      ),
    );

    final repo = await LocationHistoryRepository.getInstance();
    await repo.addPoint(DayLocationPoint(
      latitude: position.latitude,
      longitude: position.longitude,
      timestamp: DateTime.now(),
    ));
  } catch (_) {
    // Best-effort — never let a failed fix take down the background isolate.
  }
}

/// Toggles background location tracking on/off. Independent of the
/// per-entry, foreground [LocationService] — this captures a handful of raw
/// GPS fixes a day for a future route/map view, regardless of when (or
/// whether) a journal entry is recorded.
class LocationTrackingManager {
  static const _frequency = Duration(hours: 4);

  final _storage = getIt<LocalStorageService>();

  final ValueNotifier<bool> enabledNotifier = ValueNotifier(false);

  Future<void> init() async {
    await Workmanager().initialize(locationTrackingCallbackDispatcher);
    enabledNotifier.value = _storage.getLocationTrackingEnabled();
    if (enabledNotifier.value) await _register();
  }

  /// Enables/disables tracking. Returns false if location permission was
  /// declined (the toggle should then stay off), same contract as
  /// [NotificationManager.setEnabled].
  Future<bool> setEnabled(bool value) async {
    if (value) {
      if (!await _requestBackgroundPermission()) return false;
      await _register();
    } else {
      await Workmanager().cancelByUniqueName(_taskUniqueName);
    }
    enabledNotifier.value = value;
    await _storage.setLocationTrackingEnabled(value);
    return true;
  }

  Future<bool> _requestBackgroundPermission() async {
    if (!await Geolocator.isLocationServiceEnabled()) return false;

    var permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
    }
    if (permission == LocationPermission.denied ||
        permission == LocationPermission.deniedForever) {
      return false;
    }

    // Background fixes need "Allow all the time" on Android 10+ — foreground
    // ("while using the app") permission alone won't fire once backgrounded.
    if (permission == LocationPermission.whileInUse) {
      permission = await Geolocator.requestPermission();
    }
    return permission == LocationPermission.always ||
        permission == LocationPermission.whileInUse;
  }

  Future<void> _register() async {
    await Workmanager().registerPeriodicTask(
      _taskUniqueName,
      _taskName,
      frequency: _frequency,
      constraints: Constraints(networkType: NetworkType.notRequired),
      existingWorkPolicy: ExistingPeriodicWorkPolicy.keep,
    );
  }
}
