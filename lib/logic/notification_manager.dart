import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_timezone/flutter_timezone.dart';
import 'package:mars_log/data/local_storage_service.dart';
import 'package:mars_log/logic/journal_manager.dart';
import 'package:mars_log/services/service_locator.dart';
import 'package:timezone/data/latest_all.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

/// Schedules a daily "time for your log" reminder at a user-chosen time of day
/// (default 21:00). State is persisted via [LocalStorageService]; the reminder
/// survives reboots (see the receivers in AndroidManifest.xml).
///
/// Days on which a log already exists are skipped: instead of one blindly
/// repeating notification, we schedule an individual one-shot for each of the
/// next [_windowDays] days that has no entry yet, and re-arm that window
/// whenever the timeline changes (e.g. a new log is recorded today).
class NotificationManager {
  static const _baseId = 1001;
  static const _windowDays = 14;
  static const _channelId = 'daily_reminder';

  final _storage = getIt<LocalStorageService>();
  final _plugin = FlutterLocalNotificationsPlugin();

  late final JournalManager _journal = getIt<JournalManager>();

  final ValueNotifier<bool> enabledNotifier = ValueNotifier(false);
  final ValueNotifier<TimeOfDay> timeNotifier =
      ValueNotifier(const TimeOfDay(hour: 21, minute: 0));

  Set<int> _lastLoggedDays = const {};

  Future<void> init() async {
    enabledNotifier.value = _storage.getReminderEnabled();
    final minutes = _storage.getReminderMinutes();
    timeNotifier.value = TimeOfDay(hour: minutes ~/ 60, minute: minutes % 60);

    tzdata.initializeTimeZones();
    // Reminders are optional — never let timezone lookup crash app startup.
    try {
      final localName = await FlutterTimezone.getLocalTimezone();
      tz.setLocalLocation(tz.getLocation(localName.identifier));
    } catch (_) {
      tz.setLocalLocation(tz.getLocation('UTC'));
    }

    const android = AndroidInitializationSettings('@mipmap/ic_launcher');
    const ios = DarwinInitializationSettings();
    await _plugin.initialize(
      settings: const InitializationSettings(android: android, iOS: ios),
    );

    // Re-arm the window when a log is added/removed so "already logged today"
    // takes effect immediately.
    _lastLoggedDays = _loggedDays();
    _journal.entriesNotifier.addListener(_onEntriesChanged);

    if (enabledNotifier.value) await _schedule();
  }

  /// Enables/disables the reminder. Returns false if the user declined the
  /// notification permission (the toggle should then stay off).
  Future<bool> setEnabled(bool value) async {
    if (value) {
      if (!await _requestPermission()) return false;
    }
    enabledNotifier.value = value;
    await _storage.setReminderEnabled(value);
    if (value) {
      await _schedule();
    } else {
      await _cancelAll();
    }
    return true;
  }

  Future<void> setTime(TimeOfDay time) async {
    timeNotifier.value = time;
    await _storage.setReminderMinutes(time.hour * 60 + time.minute);
    if (enabledNotifier.value) await _schedule();
  }

  void _onEntriesChanged() {
    final logged = _loggedDays();
    // Only the set of logged days matters here — ignore status/analysis churn.
    if (setEquals(logged, _lastLoggedDays)) return;
    _lastLoggedDays = logged;
    if (enabledNotifier.value) _schedule();
  }

  Future<bool> _requestPermission() async {
    final android = _plugin.resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin>();
    if (android != null) {
      return await android.requestNotificationsPermission() ?? false;
    }
    final ios = _plugin.resolvePlatformSpecificImplementation<
        IOSFlutterLocalNotificationsPlugin>();
    if (ios != null) {
      return await ios.requestPermissions(
              alert: true, badge: true, sound: true) ??
          false;
    }
    return true;
  }

  /// Day-keys (year*10000 + month*100 + day) of every active entry.
  Set<int> _loggedDays() =>
      _journal.entriesNotifier.value.map((e) => _dayKey(e.day)).toSet();

  int _dayKey(DateTime d) => d.year * 10000 + d.month * 100 + d.day;

  Future<void> _cancelAll() async {
    for (var i = 0; i < _windowDays; i++) {
      await _plugin.cancel(id: _baseId + i);
    }
  }

  /// Schedules one reminder per upcoming day that has no log yet, over the next
  /// [_windowDays] days. Any app launch or new log re-fills this window.
  Future<void> _schedule() async {
    await _cancelAll();
    final time = timeNotifier.value;
    final now = tz.TZDateTime.now(tz.local);
    final logged = _loggedDays();

    var slot = 0;
    for (var offset = 0; offset < _windowDays; offset++) {
      final d = now.add(Duration(days: offset));
      final scheduled = tz.TZDateTime(
        tz.local,
        d.year,
        d.month,
        d.day,
        time.hour,
        time.minute,
      );
      if (!scheduled.isAfter(now)) continue; // today's time already passed
      if (logged.contains(_dayKey(scheduled))) continue; // already logged
      await _plugin.zonedSchedule(
        id: _baseId + slot,
        title: 'Mars Log',
        body: 'Zeit für deinen Log.',
        scheduledDate: scheduled,
        notificationDetails: const NotificationDetails(
          android: AndroidNotificationDetails(
            _channelId,
            'Erinnerung',
            channelDescription: 'Erinnert dich abends an deinen Log.',
            importance: Importance.defaultImportance,
            priority: Priority.defaultPriority,
          ),
          iOS: DarwinNotificationDetails(),
        ),
        androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
      );
      slot++;
    }
  }
}
