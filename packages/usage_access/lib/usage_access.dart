import 'dart:typed_data';

import 'package:flutter/services.dart';

/// What [UsageAccess.queryEvents] returns: [events] is a flat list of
/// `timestamp (ms since epoch), type, index into [packages]` triples.
class RawUsageEvents {
  final List<String> packages;
  final Int64List events;

  const RawUsageEvents(this.packages, this.events);
}

/// Android's UsageStatsManager, through the plugin's channel. Android only;
/// needs the "usage access" special permission, granted by hand.
class UsageAccess {
  static const _channel = MethodChannel('mars_log/usage_access');

  static Future<bool> hasAccess() async =>
      await _channel.invokeMethod<bool>('hasAccess') ?? false;

  static Future<void> openAccessSettings() =>
      _channel.invokeMethod<void>('openAccessSettings');

  /// Events in `[begin, end)` whose type is one of [types]
  /// (`UsageEvents.Event` constants).
  static Future<RawUsageEvents> queryEvents(
    DateTime begin,
    DateTime end,
    Set<int> types,
  ) async {
    final result = await _channel.invokeMapMethod<String, Object?>('queryEvents', {
      'begin': begin.millisecondsSinceEpoch,
      'end': end.millisecondsSinceEpoch,
      'types': types.toList(),
    });
    return RawUsageEvents(
      (result?['packages'] as List<Object?>? ?? const []).cast<String>(),
      result?['events'] as Int64List? ?? Int64List(0),
    );
  }

  /// Display names by package; packages this app can't see are missing.
  static Future<Map<String, String>> appLabels(Iterable<String> packages) async =>
      await _channel.invokeMapMethod<String, String>(
        'appLabels',
        {'packages': packages.toList()},
      ) ??
      const {};
}
