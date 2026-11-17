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

/// The cache's own prefs key, mirrored here because these tests read and
/// seed the raw blob. Bumped to `…2` on 2026-11-17 when sound-mode URIs were
/// added, so pre-existing entries (which carry no URI and live up to 30 days)
/// are dropped once rather than suppressing the pin.
const String _testPrefsKey = 'streamKindCache2';

/// Reads the raw persisted map straight out of the mocked
/// `SharedPreferences`, so tests can check TTLs and "unknown never persists"
/// without depending on [StreamKindCache.load]'s own filtering.
Future<Map<String, dynamic>> _persistedEntries() async {
  final prefs = await SharedPreferences.getInstance();
  final raw = prefs.getString(_testPrefsKey);
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
      _testPrefsKey: jsonEncode({
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

  group('sound-mode URI', () {
    test('put then getSoundModeUri round-trips', () {
      StreamKindCache.put('ch-pin', _video, soundModeUri: 'v_360.m3u8');
      expect(StreamKindCache.getSoundModeUri('ch-pin'), 'v_360.m3u8');
      expect(StreamKindCache.get('ch-pin'), _video);
    });

    test('a verdict cached without a URI reads back as null', () {
      StreamKindCache.put('ch-nopin', _video);
      expect(StreamKindCache.get('ch-nopin'), _video);
      expect(StreamKindCache.getSoundModeUri('ch-nopin'), isNull);
    });

    test('a miss returns null rather than throwing', () {
      expect(StreamKindCache.getSoundModeUri('never-seen'), isNull);
    });

    test('the URI persists and survives load()', () async {
      StreamKindCache.put('ch-pin', _video, soundModeUri: 'audio_it.m3u8');
      await Future<void>.delayed(Duration.zero);

      final persisted = await _persistedEntries();
      expect(
        (persisted['ch-pin'] as Map<String, dynamic>)['soundUri'],
        'audio_it.m3u8',
      );

      StreamKindCache.resetForTest();
      await StreamKindCache.load();
      expect(StreamKindCache.getSoundModeUri('ch-pin'), 'audio_it.m3u8');
    });

    test('an entry with no URI omits the key rather than writing null',
        () async {
      StreamKindCache.put('ch-nopin', _video);
      await Future<void>.delayed(Duration.zero);

      final persisted = await _persistedEntries();
      expect(
        (persisted['ch-nopin'] as Map<String, dynamic>).containsKey('soundUri'),
        isFalse,
      );
    });

    test('an entry written before this field existed still loads', () async {
      // The 1.9.0-and-earlier shape, in case such a blob is ever read back:
      // the verdict must survive and the URI must read as a plain miss.
      final now = DateTime.now();
      SharedPreferences.setMockInitialValues({
        _testPrefsKey: jsonEncode({
          'legacy': {
            'kind': 'video',
            'confidence': 'strong',
            'source': 'hlsMasterCodecs',
            'expiresAt': now.add(const Duration(days: 3)).toIso8601String(),
          },
        }),
      });
      StreamKindCache.resetForTest();
      await StreamKindCache.load();

      expect(StreamKindCache.get('legacy'), _video);
      expect(StreamKindCache.getSoundModeUri('legacy'), isNull);
    });

    test('an expired entry drops its URI with the verdict', () async {
      final now = DateTime.now();
      SharedPreferences.setMockInitialValues({
        _testPrefsKey: jsonEncode({
          'stale': {
            'kind': 'video',
            'confidence': 'strong',
            'source': 'hlsMasterCodecs',
            'expiresAt': now.add(const Duration(days: 1)).toIso8601String(),
            'soundUri': 'v_360.m3u8',
          },
        }),
      });
      StreamKindCache.resetForTest();
      await StreamKindCache.load();
      expect(StreamKindCache.getSoundModeUri('stale'), 'v_360.m3u8');

      await StreamKindCache.clear();
      expect(StreamKindCache.getSoundModeUri('stale'), isNull);
    });
  });
}
