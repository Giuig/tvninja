import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tvninja/services/video/engines/player_engine.dart';
import 'package:tvninja/services/video/reconnect_controller.dart';
import 'package:tvninja/services/video/unified_video_player.dart';

/// Why these tests exist (2026-11-13). On Rete 4 the broadcaster's live
/// playlist goes stale, ExoPlayer raises a source error and goes IDLE, and the
/// reconnect chain used to wait 2.0s before it rebuilt the player. A live HLS
/// prepare resumes at the live edge, so those 2.0s (plus the ~0.45s rebuild)
/// were broadcast the viewer never saw. The error is fatal to the player, so
/// "let it ride out" is not an option — the gap is only as short as the wait
/// before the rebuild. These pin that wait, and that the recovery stays safe.

/// An engine that opens and plays nothing, records what the player asked of
/// it, and lets a test fail `open()`, hold `dispose()` open, and fire the
/// events a real engine would (position, an out-of-band error).
class _FakeEngine extends PlayerEngine {
  _FakeEngine(this.rig, this.id,
      {required super.onPlaying,
      required super.onPosition,
      required super.onBuffering,
      required super.onEngineError});

  final _Rig rig;
  final int id;
  final openedUrls = <String>[];
  int disposeCalls = 0;

  @override
  Future<void> open(String url, Map<String, String>? headers,
      {required bool autoPlay}) async {
    openedUrls.add(url);
    final gate = rig.openGate;
    if (gate != null) await gate.future;
    if (rig.failOpens) throw StateError('open failed');
  }

  @override
  Future<void> dispose() async {
    disposeCalls++;
    final gate = rig.disposeGate;
    if (gate != null) await gate.future;
  }

  @override
  Future<void> play() async {}
  @override
  Future<void> pause() async {}
  @override
  Future<void> stop() async {}
  @override
  Future<void> switchTo(String url, Map<String, String>? headers) async {}
  @override
  Future<void> seek(Duration position) async {}
  @override
  Future<void> setVolume(double volume) async {}
  @override
  bool get isPlaying => false;
  @override
  Duration get position => Duration.zero;

  @override
  Widget buildSurface(BuildContext context, {bool stretch = false}) =>
      SizedBox(key: Key('surface-$id'));

  void firstFrame() => onPosition(const Duration(seconds: 1));
  void fail() => onEngineError('Source error');
}

class _Rig {
  final engines = <_FakeEngine>[];
  Completer<void>? openGate;
  Completer<void>? disposeGate;
  bool failOpens = false;

  _FakeEngine get last => engines.last;

  PlayerEngine create({
    required void Function(bool playing) onPlaying,
    required void Function(Duration position) onPosition,
    required void Function(bool buffering) onBuffering,
    required void Function(Object error) onEngineError,
  }) {
    final engine = _FakeEngine(this, engines.length,
        onPlaying: onPlaying,
        onPosition: onPosition,
        onBuffering: onBuffering,
        onEngineError: onEngineError);
    engines.add(engine);
    return engine;
  }
}

/// What foreground video passes as `firstDelay`.
const _fast = Duration(milliseconds: 250);

void main() {
  group('ReconnectController schedule', () {
    /// Runs a chain whose every attempt fails and returns the elapsed time at
    /// which each attempt (and the give-up) happened.
    ({List<Duration> fires, Duration? gaveUpAt}) runDeadChain(
        {bool immediate = false, Duration? firstDelay}) {
      final fires = <Duration>[];
      Duration? gaveUpAt;
      fakeAsync((async) {
        final start = async.getClock(DateTime(2026)).now();
        Duration since() =>
            async.getClock(DateTime(2026)).now().difference(start);
        late final ReconnectController c;
        c = ReconnectController(
          onRetry: () async {
            fires.add(since());
            throw StateError('still dead');
          },
          onGiveUp: () => gaveUpAt = since(),
          firstDelay: firstDelay ?? const Duration(seconds: 2), // the default
        );
        c.schedule(immediate: immediate);
        async.elapse(const Duration(minutes: 3));
        c.cancel();
      });
      return (fires: fires, gaveUpAt: gaveUpAt);
    }

    test('without a firstDelay the schedule is the old 2/4/8/16/30 s', () {
      final r = runDeadChain();
      expect(r.fires, [
        const Duration(seconds: 2),
        const Duration(seconds: 2 + 4),
        const Duration(seconds: 2 + 4 + 8),
        const Duration(seconds: 2 + 4 + 8 + 16),
        const Duration(seconds: 2 + 4 + 8 + 16 + 30),
      ]);
    });

    test('a 0.25 s firstDelay changes only the first step', () {
      final r = runDeadChain(firstDelay: _fast);
      expect(r.fires, [
        const Duration(milliseconds: 250),
        const Duration(milliseconds: 250 + 4000),
        const Duration(milliseconds: 250 + 4000 + 8000),
        const Duration(milliseconds: 250 + 4000 + 8000 + 16000),
        const Duration(milliseconds: 250 + 4000 + 8000 + 16000 + 30000),
      ]);
    });

    test('a source that never comes back still gives up after 5 attempts', () {
      final r = runDeadChain(firstDelay: _fast);
      expect(r.fires, hasLength(5));
      expect(r.gaveUpAt, isNotNull,
          reason: 'the give-up path must still be reached');
      // The give-up fires on the schedule() after the 5th attempt, with no
      // attempt after it.
      expect(r.gaveUpAt!, greaterThanOrEqualTo(r.fires.last));
    });

    test('immediate skips the wait for the first attempt only', () {
      final r = runDeadChain(immediate: true, firstDelay: _fast);
      expect(r.fires.first, Duration.zero);
      // `immediate` is asked once; the chain's own re-arms are plain, so every
      // later step keeps its backoff and a dead source is not hammered.
      expect(r.fires.skip(1).toList(), [
        const Duration(milliseconds: 4000),
        const Duration(milliseconds: 4000 + 8000),
        const Duration(milliseconds: 4000 + 8000 + 16000),
        const Duration(milliseconds: 4000 + 8000 + 16000 + 30000),
      ]);
    });

    test('immediate is ignored once the chain is past its first attempt', () {
      fakeAsync((async) {
        var fired = 0;
        final c = ReconnectController(
          onRetry: () async => fired++,
          onGiveUp: () {},
          firstDelay: _fast,
        );
        c.schedule(immediate: true);
        async.elapse(const Duration(milliseconds: 1));
        expect(fired, 1);
        // attempt 1 is now armed at 4 s by the chain itself; asking again
        // with `immediate` must not pull it forward.
        c.schedule(immediate: true);
        async.elapse(const Duration(milliseconds: 3999));
        expect(fired, 1);
        async.elapse(const Duration(milliseconds: 1));
        expect(fired, 2);
        c.cancel();
      });
    });

    test('reset() gives the next chain its fast first attempt back', () {
      fakeAsync((async) {
        var fired = 0;
        final c = ReconnectController(
          onRetry: () async => fired++,
          onGiveUp: () {},
          firstDelay: _fast,
        );
        c.schedule();
        async.elapse(const Duration(milliseconds: 250));
        expect(fired, 1);
        // First frame seen: success.
        c.reset();
        expect(c.attempt, 0);
        c.schedule();
        async.elapse(const Duration(milliseconds: 249));
        expect(fired, 1);
        async.elapse(const Duration(milliseconds: 1));
        expect(fired, 2);
        c.cancel();
      });
    });

    test('cancel() while an attempt is in flight does not re-arm the chain',
        () {
      fakeAsync((async) {
        final gate = Completer<void>();
        var fired = 0;
        final c = ReconnectController(
          onRetry: () async {
            fired++;
            await gate.future;
          },
          onGiveUp: () => fail('cancel must not notify give-up'),
          firstDelay: _fast,
        );
        c.schedule();
        async.elapse(const Duration(milliseconds: 250));
        expect(fired, 1);
        c.cancel(); // dispose while the attempt is mid-await
        gate.complete();
        async.elapse(const Duration(minutes: 3));
        expect(fired, 1, reason: 'the superseded attempt must not reschedule');
      });
    });
  });

  group('UnifiedVideoPlayer recovery from an engine error', () {
    late _Rig rig;
    late GlobalKey<UnifiedVideoPlayerState> key;
    late List<String?> errors;

    setUp(() {
      rig = _Rig();
      key = GlobalKey<UnifiedVideoPlayerState>();
      errors = [];
      UnifiedVideoPlayerState.engineFactory = rig.create;
    });

    tearDown(() => UnifiedVideoPlayerState.engineFactory = null);

    Widget player(String url) => MaterialApp(
          home: UnifiedVideoPlayer(key: key, url: url, onError: errors.add),
        );

    Future<void> mount(WidgetTester tester,
        {String url = 'http://a/one'}) async {
      await tester.pumpWidget(player(url));
      await tester.pump();
    }

    Future<void> unmount(WidgetTester tester) async {
      for (final gate in [rig.disposeGate, rig.openGate]) {
        if (gate != null && !gate.isCompleted) gate.complete();
      }
      await tester.pumpWidget(const SizedBox());
      // Anything still timed (the 10 s open timeout, a diagnostic probe) is
      // allowed to run out so the binding sees no pending timer.
      await tester.pump(const Duration(minutes: 2));
    }

    testWidgets(
        'a transient error rebuilds the player within 50 ms, not after 2 s',
        (tester) async {
      await mount(tester);
      rig.last.firstFrame();
      expect(rig.engines, hasLength(1));

      rig.last.fail();
      await tester.pump(const Duration(milliseconds: 50));

      expect(rig.engines, hasLength(2),
          reason: 'the new engine must exist 50 ms after the error');
      expect(rig.engines.first.disposeCalls, 1);
      expect(rig.engines.last.openedUrls, ['http://a/one']);
      await unmount(tester);
    });

    testWidgets('a recovered stream gets the fast retry again next time',
        (tester) async {
      await mount(tester);
      rig.last.firstFrame();

      // Two events 7 s apart, as seen on Rete 4.
      rig.last.fail();
      await tester.pump(const Duration(milliseconds: 50));
      expect(rig.engines, hasLength(2));
      rig.last.firstFrame(); // first frame of the rebuilt stream: success
      await tester.pump(const Duration(seconds: 7));

      rig.last.fail();
      await tester.pump(const Duration(milliseconds: 50));
      expect(rig.engines, hasLength(3),
          reason: 'reset-on-first-frame must restore the fast first attempt');
      await unmount(tester);
    });

    testWidgets('a source that stays dead is retried 5 times, then gives up',
        (tester) async {
      await mount(tester);
      rig.last.firstFrame();
      rig.failOpens = true;

      rig.last.fail();
      // attempt 1 now, then +4 +8 +16 +30 s of backoff = 58 s.
      await tester.pump(const Duration(milliseconds: 50));
      expect(rig.engines, hasLength(2), reason: 'attempt 1 is immediate');
      for (var s = 0; s < 70; s++) {
        await tester.pump(const Duration(seconds: 1));
      }

      expect(rig.engines, hasLength(1 + 5),
          reason: 'the original engine plus exactly 5 attempts');
      expect(
          rig.engines.skip(1).every((e) => e.openedUrls.length == 1), isTrue);
      expect(
          tester
              .state<UnifiedVideoPlayerState>(find.byType(UnifiedVideoPlayer))
              .isReconnecting,
          isFalse,
          reason: 'give-up ends the reconnecting state');
      await unmount(tester);
    });

    testWidgets('dispose while the retry is tearing down builds no engine',
        (tester) async {
      await mount(tester);
      rig.last.firstFrame();
      rig.disposeGate = Completer<void>(); // hold the old engine's teardown

      rig.last.fail();
      await tester.pump(const Duration(milliseconds: 50));
      expect(rig.engines, hasLength(1),
          reason: 'the retry is parked in the old engine\'s dispose()');

      await tester.pumpWidget(const SizedBox()); // the page is left
      rig.disposeGate!.complete();
      await tester.pump(const Duration(seconds: 1));

      expect(rig.engines, hasLength(1),
          reason: 'a disposed player must not start a new engine');
      await unmount(tester);
    });

    testWidgets('dispose while the retry is opening leaves no live chain',
        (tester) async {
      await mount(tester);
      rig.last.firstFrame();
      rig.openGate = Completer<void>();

      rig.last.fail();
      await tester.pump(const Duration(milliseconds: 50));
      expect(rig.engines, hasLength(2));

      await tester.pumpWidget(const SizedBox());
      rig.openGate!.complete();
      await tester.pump(const Duration(minutes: 2));

      expect(rig.engines, hasLength(2),
          reason: 'no further attempt after dispose');
      expect(errors, isEmpty, reason: 'nothing may surface after dispose');
      await unmount(tester);
    });

    testWidgets('a zap during the retry wins and lands on the new channel',
        (tester) async {
      await mount(tester);
      rig.last.firstFrame();
      rig.openGate = Completer<void>(); // keep the retry's open() in flight

      rig.last.fail();
      await tester.pump(const Duration(milliseconds: 50));
      expect(rig.engines, hasLength(2));

      await tester.pumpWidget(player('http://a/two')); // user zaps mid-retry
      await tester.pump();
      rig.openGate!.complete();
      rig.openGate = null;
      await tester.pump(const Duration(seconds: 1));

      expect(rig.last.openedUrls, ['http://a/two'],
          reason: 'the queued zap must be the one that ends up playing');
      await unmount(tester);
    });
  });
}
