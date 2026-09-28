import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'stream_kind.dart';

/// Persists [StreamKindVerdict]s across app runs, keyed by
/// `Channel.uniqueId`, so a channel already classified never pays the
/// probe's latency again.
///
/// A no-op on web: [StreamKindProbe] itself never runs there (CORS), so
/// there is never anything worth caching, and touching `shared_preferences`
/// for nothing would just add a preferences read for no benefit.
///
/// TTLs are keyed to how expensive being wrong would be. A strong audio
/// verdict is trusted for 30 days -- wrong would mean a channel silently
/// staying locked into audio with no in-app way back until the entry
/// expires, but the classifier only ever grants "strong" from real evidence
/// (a Content-Type, an HLS master's own CODECS+BANDWIDTH), not a guess. A
/// video verdict gets a shorter 7 days, since a channel that's genuinely
/// audio-only but was seen as video keeps opening (correctly, just without
/// the audio-mode benefits) either way -- there's nothing to protect against
/// by caching it longer. `unknown` never persists at all: it means "the
/// probe found nothing," which is exactly the state a differently-configured
/// server on a later attempt could resolve, so it's kept in memory for 10
/// minutes only, just long enough to stop back-to-back zaps re-probing the
/// same undecidable channel.
class StreamKindCache {
  StreamKindCache._();

  static const String _prefsKey = 'streamKindCache';
  static const int _maxEntries = 2000;

  static const Duration _strongAudioTtl = Duration(days: 30);
  static const Duration _videoTtl = Duration(days: 7);
  static const Duration _otherPersistedTtl = Duration(days: 30);
  static const Duration _unknownTtl = Duration(minutes: 10);

  static final Map<String, _CacheEntry> _memory = {};
  static bool _loaded = false;

  /// Loads whatever was persisted from a previous run, discarding entries
  /// that have already expired. Safe to call more than once -- only the
  /// first call does any work. Called from `AppStatsNotifier._loadData`.
  static Future<void> load() async {
    if (kIsWeb || _loaded) return;
    _loaded = true;
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_prefsKey);
      if (raw == null) return;
      final decoded = jsonDecode(raw) as Map<String, dynamic>;
      final now = DateTime.now();
      decoded.forEach((id, value) {
        final entry = _CacheEntry.fromJson(value as Map<String, dynamic>);
        if (entry.expiresAt.isAfter(now)) {
          _memory[id] = entry;
        }
      });
    } catch (e) {
      debugPrint('[StreamKindCache] failed to load: $e');
    }
  }

  /// The cached verdict for [uniqueId], or `null` on a miss, an expired
  /// entry, or the web (where this cache never holds anything).
  static StreamKindVerdict? get(String uniqueId) {
    if (kIsWeb) return null;
    final entry = _memory[uniqueId];
    if (entry == null) return null;
    if (entry.expiresAt.isBefore(DateTime.now())) {
      _memory.remove(uniqueId);
      return null;
    }
    return entry.verdict;
  }

  /// Caches [verdict] for [uniqueId] with a TTL chosen by [verdict]'s own
  /// kind/confidence, persisting everything except an `unknown` verdict. A
  /// no-op on web.
  static void put(String uniqueId, StreamKindVerdict verdict) {
    if (kIsWeb) return;
    _memory[uniqueId] = _CacheEntry(
      verdict: verdict,
      expiresAt: DateTime.now().add(_ttlFor(verdict)),
    );
    _evictOverflow();
    if (verdict.kind != StreamKind.unknown) {
      unawaited(_persist());
    }
  }

  /// Drops every cached verdict, in memory and on disk. Called from
  /// `AppStatsNotifier.globalResetData`.
  static Future<void> clear() async {
    _memory.clear();
    if (kIsWeb) return;
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_prefsKey);
  }

  /// Resets the in-memory state, including the [load] guard, so a test can
  /// exercise a fresh load against a different `SharedPreferences.
  /// setMockInitialValues` seed. Never called from app code -- production
  /// only ever calls [load] once per process, right after startup.
  @visibleForTesting
  static void resetForTest() {
    _memory.clear();
    _loaded = false;
  }

  /// The number of entries currently held in memory (persisted and
  /// in-memory-only alike) -- for asserting the [_maxEntries] cap in tests.
  @visibleForTesting
  static int get debugEntryCount => _memory.length;

  static Duration _ttlFor(StreamKindVerdict verdict) {
    if (verdict.kind == StreamKind.unknown) return _unknownTtl;
    if (verdict.kind == StreamKind.audioOnly &&
        verdict.confidence == KindConfidence.strong) {
      return _strongAudioTtl;
    }
    if (verdict.kind == StreamKind.video) return _videoTtl;
    // Provisional audio (and any future engine/user-sourced verdict).
    return _otherPersistedTtl;
  }

  /// Keeps the in-memory map at or under [_maxEntries] by dropping whichever
  /// entries expire soonest -- cheap to compute and, unlike insertion order,
  /// doesn't require tracking anything extra per entry.
  static void _evictOverflow() {
    if (_memory.length <= _maxEntries) return;
    final byExpiry = _memory.entries.toList()
      ..sort((a, b) => a.value.expiresAt.compareTo(b.value.expiresAt));
    final overflow = _memory.length - _maxEntries;
    for (var i = 0; i < overflow; i++) {
      _memory.remove(byExpiry[i].key);
    }
  }

  static Future<void> _persist() async {
    final prefs = await SharedPreferences.getInstance();
    final persisted = <String, dynamic>{
      for (final entry in _memory.entries)
        if (entry.value.verdict.kind != StreamKind.unknown)
          entry.key: entry.value.toJson(),
    };
    await prefs.setString(_prefsKey, jsonEncode(persisted));
  }
}

class _CacheEntry {
  final StreamKindVerdict verdict;
  final DateTime expiresAt;

  const _CacheEntry({required this.verdict, required this.expiresAt});

  Map<String, dynamic> toJson() => {
        'kind': verdict.kind.name,
        'confidence': verdict.confidence.name,
        'source': verdict.source.name,
        'expiresAt': expiresAt.toIso8601String(),
      };

  static _CacheEntry fromJson(Map<String, dynamic> json) {
    return _CacheEntry(
      verdict: StreamKindVerdict(
        StreamKind.values.byName(json['kind'] as String),
        KindConfidence.values.byName(json['confidence'] as String),
        KindSource.values.byName(json['source'] as String),
      ),
      expiresAt: DateTime.parse(json['expiresAt'] as String),
    );
  }
}
