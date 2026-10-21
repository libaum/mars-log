import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:mars_log/data/local_storage_service.dart';
import 'package:mars_log/data/usage_repository.dart';
import 'package:mars_log/domain/usage_day.dart';
import 'package:mars_log/logic/background_tasks.dart';
import 'package:mars_log/services/service_locator.dart';
import 'package:usage_access/usage_access.dart';
import 'package:workmanager/workmanager.dart';

const _taskUniqueName = 'mars_log_usage_tracking';

/// Android keeps raw usage events for about a week. A first collection
/// takes all of it.
const _firstReach = Duration(days: 10);

/// Every collection re-reads this much before the last one. The day files
/// merge, so re-reading is free — and it heals a write lost to the app and
/// the background isolate collecting at the same moment.
const _overlap = Duration(days: 1);

Future<void>? _running;

/// Copies Android's usage events since the last run into
/// [UsageRepository], plus labels for apps not named yet. Best-effort and
/// silent: no access, or any failure, and the next run tries again. Calls in
/// the same isolate while one runs share it.
Future<void> collectUsage({UsageRepository? repository}) =>
    _running ??= _collect(repository).whenComplete(() => _running = null);

Future<void> _collect(UsageRepository? repository) async {
  try {
    if (!await UsageAccess.hasAccess()) return;
    final repo = repository ?? await UsageRepository.open();
    final now = DateTime.now();
    final last = await repo.lastCollected();
    final from = last == null ? now.subtract(_firstReach) : last.subtract(_overlap);

    final raw = await UsageAccess.queryEvents(from, now, UsageEventType.stored);
    final events = [
      for (var i = 0; i + 2 < raw.events.length; i += 3)
        UsageEvent(raw.events[i], raw.packages[raw.events[i + 2]], raw.events[i + 1]),
    ];
    await repo.addEvents(events, now: now);

    final known = (await repo.apps()).labels;
    final unnamed = raw.packages.where((p) => p.isNotEmpty && !known.containsKey(p));
    if (unnamed.isNotEmpty) {
      await repo.addLabels(await UsageAccess.appLabels(unnamed), now: now);
    }
    await repo.setLastCollected(now);
  } catch (e) {
    debugPrint('usage collection failed: $e');
  }
}

/// Records phone usage — screen time, unlocks, which apps when — for later
/// stats. Nothing is shown yet; the days sync to Mars Hub and go into the
/// export. Needs Android's "usage access", which only the system settings
/// can grant.
class UsageTrackingManager {
  static const _frequency = Duration(hours: 6);

  final _storage = getIt<LocalStorageService>();
  final UsageRepository _repository;

  final ValueNotifier<bool> enabledNotifier = ValueNotifier(false);

  /// Whether Android currently grants usage access. Re-checked on resume:
  /// the grant happens in system settings, outside the app.
  final ValueNotifier<bool> accessNotifier = ValueNotifier(false);

  UsageTrackingManager(this._repository);

  Future<void> init() async {
    enabledNotifier.value = _storage.getUsageTrackingEnabled();
    if (enabledNotifier.value) {
      await _register();
      unawaited(refresh()); // a first collection reads a week; don't hold the start
    }
  }

  /// Re-checks access and collects — on start and on every resume, so the
  /// days are fresh before a sync round.
  Future<void> refresh() async {
    if (!enabledNotifier.value) return;
    accessNotifier.value = await UsageAccess.hasAccess();
    if (accessNotifier.value) await collectUsage(repository: _repository);
  }

  /// On: registers the periodic job and, without access yet, sends the user
  /// to the system page that grants it. Off: stops collecting; what is
  /// stored stays.
  Future<void> setEnabled(bool value) async {
    enabledNotifier.value = value;
    await _storage.setUsageTrackingEnabled(value);
    if (!value) {
      await Workmanager().cancelByUniqueName(_taskUniqueName);
      return;
    }
    await _register();
    accessNotifier.value = await UsageAccess.hasAccess();
    if (accessNotifier.value) {
      await collectUsage(repository: _repository);
    } else {
      await UsageAccess.openAccessSettings();
    }
  }

  Future<void> openAccessSettings() => UsageAccess.openAccessSettings();

  Future<int> storedDays() async => (await _repository.days()).length;

  Future<DateTime?> lastCollected() => _repository.lastCollected();

  Future<void> _register() async {
    await Workmanager().registerPeriodicTask(
      _taskUniqueName,
      kUsageTaskName,
      frequency: _frequency,
      constraints: Constraints(networkType: NetworkType.notRequired),
      existingWorkPolicy: ExistingPeriodicWorkPolicy.update,
    );
  }
}
