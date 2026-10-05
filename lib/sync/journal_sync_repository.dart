import 'package:mars_log/data/journal_repository.dart';
import 'package:mars_log/data/local_storage_service.dart';
import 'package:mars_log/domain/insight.dart';
import 'package:mars_log/domain/journal_entry.dart';
import 'package:mars_log/domain/people_aliases.dart';
import 'package:mars_sync/mars_sync.dart';

/// Maps journal entries onto mars_sync's generic [SyncItem]s.
///
/// The whole entry rides along as the payload, ordered by
/// [JournalEntry.changedAt] — text, analysis, day, place, tags, trash state.
/// Audio does not: [JournalEntry.audioFileNames] travels as metadata only,
/// the files stay on the device that recorded them (ARCHITECTURE.md §7).
///
/// Moving to the trash is an ordinary edit and syncs like one. A *purge* —
/// manual, or the 30-day trash retention — is the only thing that becomes a
/// tombstone; [SyncPurgeTrace] records it, this class pushes it.
class JournalSyncRepository implements SyncRepository {
  static const _moduleId = 'mars_log';

  final JournalRepository _journal;
  final LocalStorageService _storage;
  final String _deviceId;

  JournalSyncRepository({
    required JournalRepository journal,
    required LocalStorageService storage,
    required String deviceId,
  })  : _journal = journal,
        _storage = storage,
        _deviceId = deviceId;

  @override
  String get moduleId => _moduleId;

  @override
  Future<List<SyncItem>> localChangesSince(DateTime? since) async {
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
      final DateTime? stamp;
      if (analyzed != null) {
        stamp = (since == null || !analyzed.isBefore(since)) ? analyzed : null;
      } else if (entryDue && _hasAnalysis(entry)) {
        // An analysis from before the split (Gemini) has no clock of its own
        // and would never go out as its own item — while the entry item
        // above replaces the old combined one on the relay, taking it along.
        // So it rides with every push of its entry, stamped with the entry's
        // creation: older than any analysis written since, so it never
        // displaces one.
        stamp = entry.createdAt;
      } else {
        stamp = null;
      }
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

    for (final MapEntry(key: id, value: mark) in _storage.getSyncPurged().entries) {
      // Filtered by when it was recorded, but competing with its stamp —
      // see PurgeMark.
      if (since != null && mark.recorded.isBefore(since)) continue;
      // Both items go: the entry's and its analysis'. The analysis tombstone
      // only clears the relay's copy; devices drop the analysis with the entry.
      for (final itemId in [id, '$id$kAnalysisItemSuffix']) {
        items.add(
          SyncItem(
            itemId: itemId,
            moduleId: _moduleId,
            deviceId: _deviceId,
            updatedAt: mark.stamp,
            deletedAt: mark.stamp,
            payload: const {},
          ),
        );
      }
    }

    return items;
  }

  static bool _hasAnalysis(JournalEntry e) =>
      (e.summary ?? '').isNotEmpty || e.moodScore != null || e.tags.isNotEmpty;

  @override
  Future<void> applyRemoteItems(List<SyncItem> items) async {
    final upserts = <JournalEntry>[];
    final removed = <String, DateTime>{};
    final analyses = <SyncedAnalysis>[];
    final insights = <Insight>[];
    PeopleAliases? aliases;
    for (final item in items) {
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
      // Written before the analysis became its own item: the analysis rides
      // inside. Split it off, with the item's stamp as its clock.
      if (!item.payload.containsKey('v')) {
        analyses.add(SyncedAnalysis(entry.id, item.updatedAt, {
          ...entry.toAnalysisItemJson(),
          'analysisSource': null,
          'analysisBasis': null,
        }));
      }
    }
    await _journal.applySynced(upserts, removed, analyses: analyses);
    if (insights.isNotEmpty) await _journal.applySyncedInsights(insights);
    if (aliases != null) await _journal.applySyncedAliases(aliases);
  }

  @override
  Future<DateTime?> lastSyncedAt() async => _storage.getSyncLastSyncedAt();

  @override
  Future<void> setLastSyncedAt(DateTime time) async {
    await _storage.setSyncLastSyncedAt(time);
    // Everything purged before this watermark has been pushed — forget it.
    // Entries sharing its exact millisecond go once more next round.
    final purged = _storage.getSyncPurged()
      ..removeWhere((_, mark) => mark.recorded.isBefore(time));
    await _storage.setSyncPurged(purged);
    // The round is complete: this device now holds everything the relay had,
    // including a restore made elsewhere on day 29. Only now may the 30-day
    // purge delete audio. Its tombstones are recorded after [time], so they
    // survive the pruning above and go out with the next round.
    await _journal.purgeExpired();
  }

  @override
  Future<PullWatermark?> pullWatermark() async {
    final seq = _storage.getSyncLastSeenSeq();
    final relayId = _storage.getSyncLastSeenRelayId();
    if (seq == null || relayId == null) return null;
    return PullWatermark(relayId: relayId, seq: seq);
  }

  @override
  Future<void> setPullWatermark(PullWatermark watermark) =>
      _storage.setSyncPullWatermark(seq: watermark.seq, relayId: watermark.relayId);
}
