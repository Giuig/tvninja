import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tvninja/services/video/engines/player_engine.dart';
import 'package:tvninja/services/video/unified_video_player.dart';

/// An engine that opens and plays nothing, records what the player asked of
/// it, and lets a test hold `open()` or `dispose()` open and fire the events a
/// real engine would (position, buffering, an out-of-band error).
class _FakeEngine extends PlayerEngine {
  _FakeEngine(this.rig, this.id,
      {required super.onPlaying,
      required super.onPosition,
      required super.onBuffering,
      required super.onEngineError});

  final _Rig rig;
  final int id;
  final openedUrls = <String>[];
  int playCalls = 0;
  int disposeCalls = 0;

  @override
  Future<void> open(String url, Map<String, String>? headers,
      {required bool autoPlay}) async {
    openedUrls.add(url);
    final gate = rig.openGate;
    if (gate != null) await gate.future;
  }

  @override
  Future<void> dispose() async {
    disposeCalls++;
    final gate = rig.disposeGate;
    if (gate != null) await gate.future;
  }

  @override
  Future<void> play() async => playCalls++;
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

  // Events a real engine reports.
  void buffering(bool value) => onBuffering(value);
  void firstFrame() => onPosition(const Duration(seconds: 1));
  void fail() => onEngineError('boom');
}

/// The engines the player created, plus the gates a test can hold shut.
class _Rig {
  final engines = <_FakeEngine>[];
  Completer<void>? openGate;
  Completer<void>? disposeGate;

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

void main() {
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

  UnifiedVideoPlayerState state() => key.currentState!;

  Widget player(String url) => MaterialApp(
        home: UnifiedVideoPlayer(key: key, url: url, onError: errors.add),
      );

  Future<void> mount(WidgetTester tester, {String url = 'http://a/one'}) async {
    await tester.pumpWidget(player(url));
    await tester.pump();
  }

  /// Fake time in 1 s steps, so the timers fire in order with the microtasks
  /// of each handler settled in between.
  Future<void> elapse(WidgetTester tester, int seconds) async {
    for (var i = 0; i < seconds; i++) {
      await tester.pump(const Duration(seconds: 1));
    }
  }

  Future<void> unmount(WidgetTester tester) async {
    for (final gate in [rig.disposeGate, rig.openGate]) {
      if (gate != null && !gate.isCompleted) gate.complete();
    }
    await tester.pumpWidget(const SizedBox());
  }

  group('videoMayAutoStart', () {
    test('only an un-shut-down, still-current operation may start an engine',
        () {
      expect(videoMayAutoStart(shutDown: false, generationMatches: true), isTrue);
      expect(videoMayAutoStart(shutDown: true, generationMatches: true), isFalse);
      expect(videoMayAutoStart(shutDown: false, generationMatches: false), isFalse);
      expect(videoMayAutoStart(shutDown: true, generationMatches: false), isFalse);
    });
  });

  group('shutDownForBackground', () {
    testWidgets('disposes the engine, flags it, and play() stays a no-op',
        (tester) async {
      await mount(tester);
      expect(rig.engines, hasLength(1));
      expect(state().isShutDown, isFalse);

      await state().play(); // control: plays normally before the shutdown
      expect(rig.last.playCalls, 1);

      await state().shutDownForBackground();

      expect(state().isShutDown, isTrue);
      expect(rig.engines[0].disposeCalls, 1);
      await state().play();
      expect(rig.engines[0].playCalls, 1, reason: 'play() must not reach an engine');
      expect(rig.engines, hasLength(1), reason: 'and must not build a new one');
      await unmount(tester);
    });

    testWidgets('cancels the first-load watchdog (15 s) it was about to fire',
        (tester) async {
      await mount(tester);
      rig.last.buffering(true); // arms the never-started timer
      await elapse(tester, 14);

      await state().shutDownForBackground();
      await elapse(tester, 30);

      expect(errors, isEmpty, reason: 'no give-up / error screen while shut down');
      expect(rig.engines, hasLength(1));
      await unmount(tester);
    });

    testWidgets('cancels the re-buffer watchdog (20 s) of a playing stream',
        (tester) async {
      await mount(tester);
      rig.last.firstFrame();
      rig.last.buffering(true);
      await elapse(tester, 19);

      await state().shutDownForBackground();
      await elapse(tester, 40);

      expect(rig.engines, hasLength(1), reason: 'onStalled must not reconnect');
      expect(errors, isEmpty);
      await unmount(tester);
    });

    testWidgets('cancels a reconnect that is scheduled but not yet fired',
        (tester) async {
      await mount(tester);
      rig.last.fail(); // schedules a retry in 2 s
      await elapse(tester, 1);

      await state().shutDownForBackground();
      await elapse(tester, 60);

      expect(rig.engines, hasLength(1), reason: 'no retry may build an engine');
      expect(errors, isEmpty);
      await unmount(tester);
    });

    testWidgets(
        'a reconnect already in flight does not build a new engine afterwards',
        (tester) async {
      await mount(tester);
      rig.last.fail();
      rig.disposeGate = Completer<void>(); // hold the reconnect's teardown
      await elapse(tester, 2); // the retry fires and waits inside dispose()
      expect(rig.engines[0].disposeCalls, 1);

      final shutDown = state().shutDownForBackground();
      rig.disposeGate!.complete(); // the in-flight teardown now finishes
      await shutDown;
      await elapse(tester, 10);

      expect(rig.engines, hasLength(1),
          reason: 'the in-flight attempt must see the shutdown after its await');
      expect(state().isShutDown, isTrue);
      await unmount(tester);
    });

    testWidgets(
        'a reconnect whose new engine is still opening is disposed and never plays',
        (tester) async {
      await mount(tester);
      rig.last.fail();
      await elapse(tester, 2); // retry: engine 0 disposed, engine 1 created
      expect(rig.engines, hasLength(2));
      // (the open of engine 1 already returned; hold the next load instead)
      rig.openGate = Completer<void>();
      rig.engines[1].fail();
      await elapse(tester, 4); // second retry: engine 2 created, open held
      expect(rig.engines, hasLength(3));

      await state().shutDownForBackground();
      rig.openGate!.complete();
      await elapse(tester, 30);

      expect(rig.engines, hasLength(3), reason: 'nothing starts after the shutdown');
      expect(rig.engines[2].disposeCalls, 1);
      expect(rig.engines[2].playCalls, 0);
      expect(find.byKey(const Key('surface-2')), findsNothing,
          reason: 'a superseded open must not mark the player initialised');
      await unmount(tester);
    });

    testWidgets('a first load still opening when the screen locks never shows',
        (tester) async {
      rig.openGate = Completer<void>();
      await mount(tester);
      expect(rig.engines, hasLength(1));

      await state().shutDownForBackground();
      rig.openGate!.complete();
      await elapse(tester, 2);

      expect(find.byKey(const Key('surface-0')), findsNothing);
      expect(rig.engines[0].disposeCalls, 1);
      expect(rig.engines[0].playCalls, 0);
      await unmount(tester);
    });

    testWidgets(
        'a watchdog armed before the shutdown does not fire against the load '
        'the restart starts', (tester) async {
      await mount(tester);
      rig.last.buffering(true); // arms the 15 s first-load timer
      await elapse(tester, 10);

      await state().shutDownForBackground();
      await state().restartAfterShutDown(); // flag cleared again, new load
      await elapse(tester, 10); // past the old timer's 15 s deadline

      expect(errors, isEmpty, reason: 'the stale timer must have been cancelled');
      expect(rig.engines, hasLength(2));
      await unmount(tester);
    });

    testWidgets(
        'a late buffering event from the old engine does not time out the '
        'next load', (tester) async {
      await mount(tester);
      await state().shutDownForBackground();
      rig.engines[0].buffering(true); // the engine's last gasp, after the shutdown

      await state().restartAfterShutDown();
      await elapse(tester, 20); // past the 15 s first-load budget

      expect(errors, isEmpty);
      expect(rig.engines, hasLength(2));
      await unmount(tester);
    });
  });

  group('restartAfterShutDown', () {
    testWidgets('clears the flag and opens the current url on a fresh engine',
        (tester) async {
      await mount(tester, url: 'http://a/one');
      await state().shutDownForBackground();

      await state().restartAfterShutDown();
      await tester.pump();

      expect(state().isShutDown, isFalse);
      expect(rig.engines, hasLength(2));
      expect(rig.engines[1].openedUrls, ['http://a/one']);
      expect(find.byKey(const Key('surface-1')), findsOneWidget);
      await state().play();
      expect(rig.engines[1].playCalls, 1, reason: 'play() works again');
      await unmount(tester);
    });

    testWidgets('does nothing when the player was never shut down',
        (tester) async {
      await mount(tester);

      await state().restartAfterShutDown();

      expect(rig.engines, hasLength(1));
      expect(rig.engines[0].disposeCalls, 0);
      await unmount(tester);
    });

    testWidgets(
        'a reconnect still in flight from before the shutdown cannot build a '
        'second engine on top of the restart', (tester) async {
      await mount(tester);
      rig.last.fail();
      final staleTeardown = Completer<void>();
      rig.disposeGate = staleTeardown; // hold the reconnect's teardown
      await elapse(tester, 2); // the retry waits inside dispose()
      expect(rig.engines[0].disposeCalls, 1);

      await state().shutDownForBackground();
      rig.disposeGate = null; // later teardowns are immediate
      await state().restartAfterShutDown(); // engine 1, the one that is wanted
      await tester.pump();
      expect(rig.engines, hasLength(2));
      expect(state().isShutDown, isFalse);

      // The stale reconnect resumes now. It belongs to the shut-down epoch,
      // and the flag alone would not tell it so (the restart cleared it): it
      // must not run `_initializePlayer` over the restart's engine.
      staleTeardown.complete();
      await elapse(tester, 10);

      expect(rig.engines, hasLength(2));
      expect(rig.engines[1].disposeCalls, 0);
      expect(find.byKey(const Key('surface-1')), findsOneWidget);
      await unmount(tester);
    });

    testWidgets('a user zap while shut down clears it and opens the new channel',
        (tester) async {
      await mount(tester, url: 'http://a/one');
      await state().shutDownForBackground();

      await tester.pumpWidget(player('http://a/two'));
      await tester.pump();

      expect(state().isShutDown, isFalse);
      expect(rig.engines, hasLength(2));
      expect(rig.engines[1].openedUrls, ['http://a/two']);
      await unmount(tester);
    });
  });
}
