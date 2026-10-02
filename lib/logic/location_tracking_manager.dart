import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart';
import 'package:mars_log/data/local_storage_service.dart';
import 'package:mars_log/data/location_history_repository.dart';
import 'package:mars_log/domain/day_location_point.dart';
import 'package:mars_log/logic/background_tasks.dart';
import 'package:mars_log/services/service_locator.dart';
import 'package:workmanager/workmanager.dart';

const _taskUniqueName = 'mars_log_location_tracking';

/// How old a last-known position may be to stand in for a fresh fix.
const _maxLastKnownAge = Duration(minutes: 30);

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

    // Android hands background apps only a few fresh fixes an hour, so a
    // one-shot request often times out. Then a recent last-known position
    // (from any app) still beats an empty hour.
    Position? position;
    try {
      position = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.low,
          timeLimit: Duration(seconds: 60),
        ),
      );
    } catch (_) {
      final last = await Geolocator.getLastKnownPosition();
      if (last != null &&
          DateTime.now().difference(last.timestamp) <= _maxLastKnownAge) {
        position = last;
      }
    }
    if (position == null) return;

    // The fix's own time — a last-known position may be older than now.
    final timestamp = position.timestamp.toLocal();
    final repo = await LocationHistoryRepository.getInstance();
    // Two runs can fall back to the same last-known fix; store it once.
    if (repo.pointsForDay(timestamp).any((p) => p.timestamp == timestamp)) {
      return;
    }
    await repo.addPoint(DayLocationPoint(
      latitude: position.latitude,
      longitude: position.longitude,
      timestamp: timestamp,
      source: LocationSource.tracked,
    ));
  } catch (_) {
    // Best-effort — never let a failed fix take down the background isolate.
  }
}

/// What actually happened when tracking was switched on — "on" and "on but
/// the OS will throttle it" are different outcomes and the UI must say so.
enum LocationTrackingResult {
  off,

  /// Permission denied or location services disabled; the toggle stays off.
  denied,

  /// Running with "Allow all the time".
  enabled,

  /// Running, but only "While using the app" was granted — background fixes
  /// will mostly not happen until that's changed in system settings.
  enabledForegroundOnly,
}

/// Toggles background location tracking on/off. Independent of the
/// per-entry, foreground [LocationService] — this captures a handful of raw
/// GPS fixes a day for a future route/map view, regardless of when (or
/// whether) a journal entry is recorded.
class LocationTrackingManager {
  static const _frequency = Duration(hours: 1);

  final _storage = getIt<LocalStorageService>();

  final ValueNotifier<bool> enabledNotifier = ValueNotifier(false);

  Future<void> init() async {
    enabledNotifier.value = _storage.getLocationTrackingEnabled();
    if (enabledNotifier.value) await _register();
  }

  /// Enables/disables tracking, reporting what the OS actually granted so
  /// Settings can tell the truth rather than silently claiming success.
  Future<LocationTrackingResult> setEnabled(bool value) async {
    if (!value) {
      await Workmanager().cancelByUniqueName(_taskUniqueName);
      enabledNotifier.value = false;
      await _storage.setLocationTrackingEnabled(false);
      return LocationTrackingResult.off;
    }

    final permission = await _requestPermission();
    if (permission == null) return LocationTrackingResult.denied;

    await _register();
    enabledNotifier.value = true;
    await _storage.setLocationTrackingEnabled(true);

    // "While in use" is enough to register the job, but Android will starve
    // it once the app is backgrounded — which is exactly when it should run.
    // The toggle goes on, and the caller warns.
    return permission == LocationPermission.always
        ? LocationTrackingResult.enabled
        : LocationTrackingResult.enabledForegroundOnly;
  }

  /// Sends the user to the system settings page for this app — the only way
  /// to upgrade to "Allow all the time" on Android 11+, where the runtime
  /// dialog no longer offers that option at all.
  Future<void> openSystemSettings() => Geolocator.openAppSettings();

  /// Returns the granted permission, or null if there's nothing usable.
  Future<LocationPermission?> _requestPermission() async {
    if (!await Geolocator.isLocationServiceEnabled()) return null;

    var permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
    }
    if (permission == LocationPermission.denied ||
        permission == LocationPermission.deniedForever) {
      return null;
    }
    // Deliberately no second requestPermission() here: on Android 10+ it does
    // not escalate whileInUse → always. That upgrade only happens in system
    // settings, which is what [openSystemSettings] is for.
    return permission;
  }

  Future<void> _register() async {
    await Workmanager().registerPeriodicTask(
      _taskUniqueName,
      kLocationTaskName,
      frequency: _frequency,
      constraints: Constraints(networkType: NetworkType.notRequired),
      existingWorkPolicy: ExistingPeriodicWorkPolicy.update,
    );
  }
}
