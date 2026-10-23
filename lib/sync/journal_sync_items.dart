import 'dart:convert';

import 'package:mars_log/data/journal_repository.dart';
import 'package:mars_log/data/usage_repository.dart';
import 'package:mars_log/domain/insight.dart';
import 'package:mars_log/domain/journal_entry.dart';
import 'package:mars_log/domain/people_aliases.dart';
import 'package:mars_log/domain/usage_day.dart';
import 'package:mars_sync/mars_sync.dart';
import 'package:mars_sync_flutter/mars_sync_flutter.dart';

/// Maps journal entries onto mars_sync's generic [SyncItem]s.
///
/// The whole entry rides along as the payload, ordered by
/// [JournalEntry.changedAt] — text, analysis, day, place, tags, trash state.
/// Audio does not: [JournalEntry.audioFileNames] travels as metadata only,
/// the files stay on the device that recorded them (ARCHITECTURE.md §7).
///
/// Moving to the trash is an ordinary edit and syncs like one. A *purge* —
/// manual, or the 30-day trash retention — is the only thing that becomes a
/// tombstone; [SyncPurgeTrace] records it in the [SyncLedger], which pushes
/// it for the entry and its analysis ([tombstoneIds]).
///
/// Phone usage rides along: one item per day (`usage:2026-10-21`) and one
/// for the app labels ([kUsageAppsId]). Written only on the phone, merged
/// as sets wherever they land, never deleted.
class JournalSyncItems extends ModuleItems {
  static const _moduleId = 'mars_log';

  /// 2: the analysis is its own item (`<id>:analysis`) with its own clock,
  /// entry items carry `v: 2`. Items written before (2026-09-26) carried the
  /// analysis inside the entry; every device has migrated since.
  static const syncFormat = 2;

  /// The relay refuses a payload over 256 KB — and with it the whole push.
  /// Encrypted and base64'd, this much plaintext stays under it.
  static const maxUsagePayloadChars = 170 * 1024;

  final JournalRepository _journal;
  final UsageRepository? _usage;
  final String _deviceId;

  /// [usage]: null leaves usage items out both ways.
  JournalSyncItems({
    required JournalRepository journal,
    required String deviceId,
    UsageRepository? usage,
  })  : _journal = journal,
        _usage = usage,
        _deviceId = deviceId;

  @override
  String get moduleId => _moduleId;

  @override
  Future<List<SyncItem>> itemsSince(DateTime? since) async {
    final items = <SyncItem>[];

    for (final entry in _journal.allEntries) {
      // An entry still being analyzed is half-made: its transcript is empty
      // and its status will flip within seconds. Pushing it would briefly
      // show a spinner-forever entry on the laptop. It goes out once ready
      // or failed — that write stamps it anyway. Same for one waiting for a
      // connection: it is still the phone's to finish.
      if (entry.status == EntryStatus.analyzing ||
          entry.status == EntryStatus.pending) {
        continue;
      }
      final entryDue = since == null || !entry.changedAt.isBefore(since);
      if (entryDue) {
        items.add(
          SyncItem(
            itemId: entry.id,
            moduleId: _moduleId,
            deviceId: _deviceId,
            updatedAt: entry.changedAt,
            payload: entry.toEntryItemJson(),
          ),
        );
      }
      // The analysis is its own item with its own clock — see
      // JournalEntry.analysisChangedAt.
      final analyzed = entry.analysisChangedAt;
      final stamp =
          analyzed != null && (since == null || !analyzed.isBefore(since))
              ? analyzed
              : null;
      if (stamp != null) {
        items.add(
          SyncItem(
            itemId: '${entry.id}$kAnalysisItemSuffix',
            moduleId: _moduleId,
            deviceId: _deviceId,
            updatedAt: stamp,
            payload: entry.toAnalysisItemJson(),
          ),
        );
      }
    }

    // Evaluations over the whole journal, made on the laptop.
    for (final insight in _journal.insights) {
      if (since != null && insight.createdAt.isBefore(since)) continue;
      items.add(
        SyncItem(
          itemId: insight.id,
          moduleId: _moduleId,
          deviceId: _deviceId,
          updatedAt: insight.createdAt,
          payload: insight.toJson(),
        ),
      );
    }

    // Which names are the same person — edited by hand, one item.
    final aliases = _journal.aliases;
    final aliasesAt = aliases.changedAt;
    if (aliasesAt != null && (since == null || !aliasesAt.isBefore(since))) {
      items.add(
        SyncItem(
          itemId: kPeopleAliasesId,
          moduleId: _moduleId,
          deviceId: _deviceId,
          updatedAt: aliasesAt,
          payload: aliases.toJson(),
        ),
      );
    }

    final usage = _usage;
    if (usage != null) {
      for (final day in await usage.changedSince(since)) {
        final payload = day.toJson();
        // A day that big would sink every other item in the push. Not seen
        // in practice (a heavy day is ~40 KB); it stays on the phone and in
        // the export.
        if (jsonEncode(payload).length > maxUsagePayloadChars) continue;
        items.add(
          SyncItem(
            itemId: day.id,
            moduleId: _moduleId,
            deviceId: _deviceId,
            updatedAt: day.changedAt,
            payload: payload,
          ),
        );
      }
      final apps = await usage.apps();
      final appsAt = apps.changedAt;
      if (appsAt != null && (since == null || !appsAt.isBefore(since))) {
        items.add(
          SyncItem(
            itemId: kUsageAppsId,
            moduleId: _moduleId,
            deviceId: _deviceId,
            updatedAt: appsAt,
            payload: apps.toJson(),
          ),
        );
      }
    }

    return items;
  }

  @override
  Future<void> apply(List<SyncItem> items) async {
    final upserts = <JournalEntry>[];
    final removed = <String, DateTime>{};
    final analyses = <SyncedAnalysis>[];
    final insights = <Insight>[];
    PeopleAliases? aliases;
    final usageDays = <UsageDay>[];
    UsageApps? usageApps;
    for (final item in items) {
      if (item.itemId.startsWith(kUsageItemPrefix)) {
        if (item.isDeleted || item.payload['id'] != item.itemId) continue;
        try {
          if (item.itemId == kUsageAppsId) {
            usageApps = UsageApps.fromJson(item.payload)..changedAt = item.updatedAt;
          } else {
            usageDays.add(UsageDay.fromJson(item.payload)..changedAt = item.updatedAt);
          }
        } on Object {
          continue; // a newer build's shape — see the entry case below
        }
        continue;
      }
      if (item.itemId == kPeopleAliasesId) {
        if (item.isDeleted || item.payload['id'] != item.itemId) continue;
        try {
          aliases = PeopleAliases.fromJson(item.payload);
        } on Object {
          continue;
        }
        continue;
      }
      if (item.itemId.startsWith(kInsightPrefix)) {
        if (item.isDeleted || item.payload['id'] != item.itemId) continue;
        try {
          insights.add(Insight.fromJson(item.payload));
        } on Object {
          continue; // a newer build's shape — see the entry case below
        }
        continue;
      }
      final isAnalysis = item.itemId.endsWith(kAnalysisItemSuffix);
      if (item.isDeleted) {
        // An analysis tombstone always comes with its entry's; that one
        // removes both here.
        if (!isAnalysis) removed[item.itemId] = item.updatedAt;
        continue;
      }
      // The envelope's id is authenticated (AAD); the payload's id must agree
      // or the payload is not what the relay claims it is.
      if (item.payload['id'] != item.itemId) continue;
      if (isAnalysis) {
        final entryId = item.itemId
            .substring(0, item.itemId.length - kAnalysisItemSuffix.length);
        analyses.add(SyncedAnalysis(entryId, item.updatedAt, item.payload));
        continue;
      }
      final JournalEntry entry;
      try {
        entry = JournalEntry.fromJson(item.payload);
      } on Object {
        // A payload this build can't read (a newer app version on the other
        // device). Skipping beats failing the round for every other entry —
        // but the pull watermark moves past it, so this device only sees it
        // again after a re-pair (pull from 0) or its next edit elsewhere.
        continue;
      }
      entry.changedAt = item.updatedAt;
      upserts.add(entry);
    }
    await _journal.applySynced(upserts, removed, analyses: analyses);
    if (insights.isNotEmpty) await _journal.applySyncedInsights(insights);
    if (aliases != null) await _journal.applySyncedAliases(aliases);
    final usage = _usage;
    if (usage != null) {
      for (final day in usageDays) {
        await usage.applySynced(day);
      }
      if (usageApps != null) {
        await usage.applySyncedApps(usageApps);
      }
    }
  }

  /// The analysis tombstone only clears the relay's copy; devices drop the
  /// analysis with the entry.
  @override
  Iterable<String> tombstoneIds(String purgedId) =>
      [purgedId, '$purgedId$kAnalysisItemSuffix'];

  /// The round is complete: this device now holds everything the relay had,
  /// including a restore made elsewhere on day 29. Only now may the 30-day
  /// purge delete audio. Its tombstones are recorded after the watermark, so
  /// they go out with the next round.
  @override
  Future<void> afterRound() => _journal.purgeExpired();
}
