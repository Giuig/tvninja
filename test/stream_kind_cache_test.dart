import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tvninja/services/video/stream_kind.dart';
import 'package:tvninja/services/video/stream_kind_cache.dart';

const _strongAudio = StreamKindVerdict(
  StreamKind.audioOnly,
  KindConfidence.strong,
  KindSource.contentType,
);
const _provisionalAudio = StreamKindVerdict(
  StreamKind.audioOnly,
  KindConfidence.provisional,
  KindSource.hlsMasterCodecs,
);
const _video = StreamKindVerdict(
  StreamKind.video,
  KindConfidence.strong,
  KindSource.hlsMasterCodecs,
);

/// Reads the raw persisted map straight out of the mocked
/// `SharedPreferences`, so tests can check TTLs and "unknown never persists"
/// without depending on [StreamKindCache.load]'s own filtering.
Future<Map<String, dynamic>> _persistedEntries() async {
  final prefs = await SharedPreferences.getInstance();
  final raw = prefs.getString('streamKindCache');
  if (raw == null) return {};
  return jsonDecode(raw) as Map<String, dynamic>;
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    StreamKindCache.resetForTest();
  });

  test('a miss returns null', () {
    expect(StreamKindCache.get('missing'), isNull);
  });

  test('put then get round-trips within the same session', () {
    StreamKindCache.put('ch1', _strongAudio);
    expect(StreamKindCache.get('ch1'), _strongAudio);
  });

  test('an unknown verdict is cached in memory but never persisted', () async {
    StreamKindCache.put('ch-unknown', StreamKindVerdict.unknown);
    expect(StreamKindCache.get('ch-unknown'), StreamKindVerdict.unknown);

    // Give the fire-and-forget persist a chance to run, if it were going to.
    await Future<void>.delayed(Duration.zero);
    final persisted = await _persistedEntries();
    expect(persisted.containsKey('ch-unknown'), isFalse);
  });

  test('strong audio persists with a 30-day TTL', () async {
    StreamKindCache.put('ch-strong', _strongAudio);
    await Future<void>.delayed(Duration.zero);

    final persisted = await _persistedEntries();
    final expiresAt = DateTime.parse(persisted['ch-strong']['expiresAt'] as String);
    final ttl = expiresAt.difference(DateTime.now());
    // Within a minute of exactly 30 days -- generous slack for the wall-clock
    // gap between the put() and this re-read, without pinning an exact
    // instant that would make the test flaky.
    expect(ttl.inSeconds, closeTo(const Duration(days: 30).inSeconds, 60));
  });

  test('video persists with a 7-day TTL', () async {
    StreamKindCache.put('ch-video', _video);
    await Future<void>.delayed(Duration.zero);

    final persisted = await _persistedEntries();
    final expiresAt = DateTime.parse(persisted['ch-video']['expiresAt'] as String);
    final ttl = expiresAt.difference(DateTime.now());
    expect(ttl.inSeconds, closeTo(const Duration(days: 7).inSeconds, 60));
  });

  test('provisional audio persists with a 30-day TTL', () async {
    StreamKindCache.put('ch-provisional', _provisionalAudio);
    await Future<void>.delayed(Duration.zero);

    final persisted = await _persistedEntries();
    final expiresAt =
        DateTime.parse(persisted['ch-provisional']['expiresAt'] as String);
    final ttl = expiresAt.difference(DateTime.now());
    expect(ttl.inSeconds, closeTo(const Duration(days: 30).inSeconds, 60));
  });

  test('load() restores an unexpired entry and drops an expired one', () async {
    final now = DateTime.now();
    SharedPreferences.setMockInitialValues({
      'streamKindCache': jsonEncode({
        'still-good': {
          'kind': 'audioOnly',
          'confidence': 'strong',
          'source': 'contentType',
          'expiresAt': now.add(const Duration(days: 1)).toIso8601String(),
        },
        'already-expired': {
          'kind': 'video',
          'confidence': 'strong',
          'source': 'hlsMasterCodecs',
          'expiresAt': now.subtract(const Duration(days: 1)).toIso8601String(),
        },
      }),
    });
    StreamKindCache.resetForTest();

    await StreamKindCache.load();

    expect(StreamKindCache.get('still-good'), _strongAudio);
    expect(StreamKindCache.get('already-expired'), isNull);
  });

  test('load() is a no-op on a second call', () async {
    StreamKindCache.put('ch1', _strongAudio);
    await Future<void>.delayed(Duration.zero);

    // A second load() must not clobber what's already in memory (e.g. with
    // a stale on-disk snapshot from before this session's writes).
    await StreamKindCache.load();

    expect(StreamKindCache.get('ch1'), _strongAudio);
  });

  test('clear() drops everything, in memory and on disk', () async {
    StreamKindCache.put('ch1', _strongAudio);
    await Future<void>.delayed(Duration.zero);

    await StreamKindCache.clear();

    expect(StreamKindCache.get('ch1'), isNull);
    final persisted = await _persistedEntries();
    expect(persisted, isEmpty);
  });

  test(
    'eviction at the 2000-entry cap drops the soonest-expiring entries first',
    () async {
      // 10 video entries (7-day TTL) inserted first, then 2000 strong-audio
      // entries (30-day TTL) -- 2010 total, 10 over the cap. The video
      // entries expire soonest, so eviction should remove exactly those 10
      // and keep every strong-audio one.
      final shortLivedIds = [for (var i = 0; i < 10; i++) 'short-$i'];
      for (final id in shortLivedIds) {
        StreamKindCache.put(id, _video);
      }
      for (var i = 0; i < 2000; i++) {
        StreamKindCache.put('long-$i', _strongAudio);
      }

      expect(StreamKindCache.debugEntryCount, 2000);
      for (final id in shortLivedIds) {
        expect(StreamKindCache.get(id), isNull, reason: '$id should have been evicted');
      }
      expect(StreamKindCache.get('long-0'), _strongAudio);
      expect(StreamKindCache.get('long-1999'), _strongAudio);

      // Let the many fire-and-forget persists from this test settle before
      // the next test resets prefs out from under them.
      await Future<void>.delayed(const Duration(milliseconds: 300));
    },
    timeout: const Timeout(Duration(seconds: 30)),
  );
}
