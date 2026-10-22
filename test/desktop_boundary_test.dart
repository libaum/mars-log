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
  'lib/data/usage_repository.dart',
  'lib/sync',
];

const _allowed = [
  'dart:',
  'package:flutter/foundation.dart',
  'package:path_provider/',
  'package:shared_preferences/',
  'package:mars_sync/',
  // SyncService and its status only — not the key store or the screen.
  'package:mars_sync_flutter/mars_sync_flutter.dart',
  'package:crypto/', // pure Dart (transcriptBasis)
  'package:mars_log/domain/',
  'package:mars_log/data/journal_repository.dart',
  'package:mars_log/data/local_storage_service.dart',
  'package:mars_log/data/usage_repository.dart',
  'package:mars_log/sync/',
];

void main() {
  test('code shared with Mars Hub imports nothing phone-only', () {
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
        final imports = RegExp(r'''^(?:import|export)\s+['"]([^'"]+)['"]''', multiLine: true)
            .allMatches(file.readAsStringSync())
            .map((m) => m.group(1)!);
        for (final uri in imports) {
          final ok = _allowed.any(uri.startsWith);
          if (!ok) violations.add('$path → $uri');
        }
      }
    }
    expect(violations, isEmpty,
        reason: 'mars_hub imports these files on Linux. Keep phone-only code '
            'in logic/ or pages/, or extend the allowlist deliberately.');
  });
}
