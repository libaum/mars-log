/// Phone usage as Android reports it: raw events, one [UsageDay] per local
/// calendar day, no aggregation. Like the transcript, the events are the
/// record — screen time, unlocks, launches per app are computed from them
/// later, as often as wanted. Android itself keeps them only about a week.
library;

/// Sync item ids: `usage:2026-10-21` per day, [kUsageAppsId] for the labels.
const kUsageItemPrefix = 'usage:';
const kUsageAppsId = '${kUsageItemPrefix}apps';

/// The `UsageEvents.Event` types that are stored — the ones usage stats are
/// made of. Notification events are system-only on most Android versions;
/// they are asked for anyway and kept if they come.
abstract final class UsageEventType {
  /// An activity came to the foreground / left it — time per app, launches.
  static const activityResumed = 1;
  static const activityPaused = 2;
  static const notificationSeen = 10;
  static const notificationInterruption = 12;

  /// Screen on / off — total screen time, sessions.
  static const screenInteractive = 15;
  static const screenNonInteractive = 16;

  /// Lock screen shown / dismissed — unlocks.
  static const keyguardShown = 17;
  static const keyguardHidden = 18;

  /// Foreground services — music, navigation, calls running in the background.
  static const foregroundServiceStart = 19;
  static const foregroundServiceStop = 20;
  static const deviceShutdown = 26;
  static const deviceStartup = 27;

  static const stored = {
    activityResumed,
    activityPaused,
    notificationSeen,
    notificationInterruption,
    screenInteractive,
    screenNonInteractive,
    keyguardShown,
    keyguardHidden,
    foregroundServiceStart,
    foregroundServiceStop,
    deviceShutdown,
    deviceStartup,
  };
}

/// One event: [at] in ms since epoch, [app] the package ('' for device-wide
/// events Android files under no package), [type] a [UsageEventType].
class UsageEvent implements Comparable<UsageEvent> {
  final int at;
  final String app;
  final int type;

  const UsageEvent(this.at, this.app, this.type);

  /// The local calendar day the event falls on (`yyyy-MM-dd`).
  String get day => usageDayKey(DateTime.fromMillisecondsSinceEpoch(at));

  @override
  int compareTo(UsageEvent other) {
    final byTime = at.compareTo(other.at);
    if (byTime != 0) return byTime;
    final byType = type.compareTo(other.type);
    return byType != 0 ? byType : app.compareTo(other.app);
  }

  @override
  bool operator ==(Object other) =>
      other is UsageEvent && other.at == at && other.app == app && other.type == type;

  @override
  int get hashCode => Object.hash(at, app, type);

  @override
  String toString() => 'UsageEvent($at, $app, $type)';
}

String usageDayKey(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-'
    '${d.month.toString().padLeft(2, '0')}-'
    '${d.day.toString().padLeft(2, '0')}';

/// A day's events, sorted, each once. [changedAt] is the sync clock: moved
/// when collecting added something.
class UsageDay {
  final String day;
  final List<UsageEvent> events;
  DateTime changedAt;

  UsageDay(this.day, Iterable<UsageEvent> events, {required this.changedAt})
      : events = (events.toSet().toList()..sort());

  String get id => '$kUsageItemPrefix$day';

  /// Adds the events not held yet. Returns how many were new.
  int merge(Iterable<UsageEvent> incoming) {
    final known = events.toSet();
    final fresh = incoming.where(known.add).toList();
    if (fresh.isEmpty) return 0;
    events
      ..addAll(fresh)
      ..sort();
    return fresh.length;
  }

  /// Compact, because a day travels as one sync item (the relay takes up to
  /// 256 KB): `apps` names each package once, `events` is a flat list of
  /// `Δms, app index, type` triples — Δ from the previous event, the first
  /// one from `base`.
  Map<String, dynamic> toJson() {
    final apps = <String>[];
    final index = <String, int>{};
    final flat = <int>[];
    final base = events.isEmpty ? 0 : events.first.at;
    var last = base;
    for (final e in events) {
      flat
        ..add(e.at - last)
        ..add(index.putIfAbsent(e.app, () {
          apps.add(e.app);
          return apps.length - 1;
        }))
        ..add(e.type);
      last = e.at;
    }
    return {
      'id': id,
      'day': day,
      'changedAt': changedAt.toUtc().toIso8601String(),
      'base': base,
      'apps': apps,
      'events': flat,
    };
  }

  factory UsageDay.fromJson(Map<String, dynamic> json) {
    final apps = (json['apps'] as List<dynamic>).cast<String>();
    final flat = (json['events'] as List<dynamic>).cast<int>();
    final events = <UsageEvent>[];
    var at = json['base'] as int;
    for (var i = 0; i + 2 < flat.length; i += 3) {
      at += flat[i];
      events.add(UsageEvent(at, apps[flat[i + 1]], flat[i + 2]));
    }
    return UsageDay(
      json['day'] as String,
      events,
      changedAt: DateTime.parse(json['changedAt'] as String).toLocal(),
    );
  }
}

/// Display names by package, as far as the phone could resolve them. Grows
/// only: a label once learnt stays, even after the app is uninstalled.
class UsageApps {
  final Map<String, String> labels;
  DateTime? changedAt;

  UsageApps(Map<String, String> labels, {this.changedAt}) : labels = {...labels};

  /// Takes new and renamed labels. Returns whether anything changed.
  bool merge(Map<String, String> incoming) {
    var changed = false;
    for (final MapEntry(key: app, value: label) in incoming.entries) {
      if (label.isEmpty || labels[app] == label) continue;
      labels[app] = label;
      changed = true;
    }
    return changed;
  }

  Map<String, dynamic> toJson() => {
        'id': kUsageAppsId,
        'changedAt': changedAt?.toUtc().toIso8601String(),
        'labels': labels,
      };

  factory UsageApps.fromJson(Map<String, dynamic> json) => UsageApps(
        (json['labels'] as Map).cast<String, String>(),
        changedAt: json['changedAt'] == null
            ? null
            : DateTime.parse(json['changedAt'] as String).toLocal(),
      );
}
