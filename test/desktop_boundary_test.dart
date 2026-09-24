import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// mars_hub (the Linux desktop app) imports these files straight from this
/// repo — one JournalEntry, one JournalRepository, one sync mapping for both
/// devices. They must therefore import nothing that needs a phone.
///
/// An allowlist, not a denylist: this app pulls in some 25 plugins, most of
/// them Android-only, and a denylist would only guard against the ones
/// someone remembered. Anything new has to be added here on purpose.
const _shared = [
  'lib/domain',
  'lib/data/journal_repository.dart',
  'lib/data/local_storage_service.dart',
  'lib/sync',
];

const _allowed = [
  'dart:',
  'package:flutter/foundation.dart',
  'package:path_provider/',
  'package:shared_preferences/',
  'package:mars_sync/',
  'package:mars_log/domain/',
  'package:mars_log/data/journal_repository.dart',
  'package:mars_log/data/local_storage_service.dart',
  'package:mars_log/sync/',
];

/// The phone's key store. It has a Linux build, but the hub never constructs
/// it — it passes mars_sync's FileSyncKeyStore instead.
const _exceptions = {
  'lib/sync/secure_sync_key_store.dart': ['package:flutter_secure_storage/'],
};

void main() {
  test('code shared with the desktop hub imports nothing phone-only', () {
    final violations = <String>[];
    for (final root in _shared) {
      final files = FileSystemEntity.isDirectorySync(root)
          ? Directory(root)
              .listSync(recursive: true)
              .whereType<File>()
              .where((f) => f.path.endsWith('.dart'))
          : [File(root)];
      for (final file in files) {
        final path = file.path;
        final extra = _exceptions[path] ?? const <String>[];
        final imports = RegExp(r'''^(?:import|export)\s+['"]([^'"]+)['"]''', multiLine: true)
            .allMatches(file.readAsStringSync())
            .map((m) => m.group(1)!);
        for (final uri in imports) {
          final ok = [..._allowed, ...extra].any(uri.startsWith);
          if (!ok) violations.add('$path → $uri');
        }
      }
    }
    expect(violations, isEmpty,
        reason: 'mars_hub imports these files on Linux. Keep phone-only code '
            'in logic/ or pages/, or extend the allowlist deliberately.');
  });
}
