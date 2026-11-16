import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart' as mk;
import 'package:tvninja/services/native_audio_service.dart';

/// An mpv player that does nothing but count what it is asked to do: a real
/// one cannot be built on the test host (no libmpv).
class _FakePlayer extends Fake implements mk.Player {
  _FakePlayer({this.failOpen = false});

  /// `open` throws, which is how a stream that cannot be opened looks to
  /// `NativeAudioService.play`.
  final bool failOpen;
  int stopCalls = 0;

  @override
  Future<void> open(mk.Playable playable,
      {bool play = true, Map<String, dynamic>? extras}) async {
    if (failOpen) throw StateError('cannot open');
  }

  @override
  Future<void> stop() async {
    stopCalls++;
  }

  @override
  Future<void> dispose() async {}
  @override
  mk.PlayerStream get stream => _FakePlayerStream();
}

class _FakePlayerStream extends Fake implements mk.PlayerStream {
  @override
  Stream<bool> get playing => const Stream<bool>.empty();
  @override
  Stream<bool> get buffering => const Stream<bool>.empty();
  @override
  Stream<bool> get completed => const Stream<bool>.empty();
  @override
  Stream<Duration> get position => const Stream<Duration>.empty();
  @override
  Stream<String> get error => const Stream<String>.empty();
}

/// The native-channel side of the foreground service: the screen-state query,
/// the early start that comes before the stream opens, and what `play`, `stop`
/// and the native events do to it. The mpv player is replaced by a fake, so
/// the channel traffic and the fake's own calls are what there is to look at.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('io.github.giuig.tvninja/audio');
  const eventChannel = EventChannel('io.github.giuig.tvninja/audio_events');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  final calls = <MethodCall>[];
  Future<Object?> Function(MethodCall call)? answer;

  /// Every player the service built since the test began, in order.
  final players = <_FakePlayer>[];
  var failOpen = false;
  MockStreamHandlerEventSink? nativeEvents;

  setUp(() async {
    calls.clear();
    answer = null;
    players.clear();
    failOpen = false;
    nativeEvents = null;
    NativeAudioService.playerFactory = () {
      final player = _FakePlayer(failOpen: failOpen);
      players.add(player);
      return player;
    };
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return answer == null ? true : await answer!(call);
    });
    messenger.setMockStreamHandler(
        eventChannel,
        MockStreamHandler.inline(onListen: (arguments, events) {
          nativeEvents = events;
        }));
    // Static state from an earlier test must not leak into this one: start
    // from "no player yet, nobody listening to the native events".
    await NativeAudioService.initialize();
    await NativeAudioService.dispose();
    players.clear();
    nativeEvents = null;
    calls.clear();
  });

  tearDown(() async {
    await NativeAudioService.stop();
    await NativeAudioService.dispose();
    NativeAudioService.playerFactory = mk.Player.new;
    messenger.setMockMethodCallHandler(channel, null);
    messenger.setMockStreamHandler(eventChannel, null);
  });

  /// Lets a native event reach the service: the sink hands it to the
  /// messenger, which delivers it on a later turn.
  Future<void> deliver(Map<String, Object?> event) async {
    nativeEvents!.success(event);
    for (var i = 0; i < 3; i++) {
      await Future<void>.delayed(Duration.zero);
    }
  }

  List<String> methods() => calls.map((c) => c.method).toList();

  group('isScreenInteractive', () {
    test('passes the native answer through', () async {
      answer = (_) async => false;
      expect(await NativeAudioService.isScreenInteractive(), isFalse);
      answer = (_) async => true;
      expect(await NativeAudioService.isScreenInteractive(), isTrue);
      expect(methods(), ['isInteractive', 'isInteractive']);
    });

    test('reads "not locked" when the native side fails or says nothing',
        () async {
      answer = (_) async => throw PlatformException(code: 'boom');
      expect(await NativeAudioService.isScreenInteractive(), isTrue);
      answer = (_) async => null;
      expect(await NativeAudioService.isScreenInteractive(), isTrue);
      messenger.setMockMethodCallHandler(channel, null);
      expect(await NativeAudioService.isScreenInteractive(), isTrue);
    });
  });

  group('startForegroundEarly', () {
    test('asks the native side for the service with the title and logo',
        () async {
      expect(
          await NativeAudioService.startForegroundEarly(
              title: 'Rai 1', logo: 'http://x/logo.png'),
          isTrue);
      expect(methods(), ['startBackground']);
      expect(calls.single.arguments,
          {'title': 'Rai 1', 'logo': 'http://x/logo.png'});
    });

    test('a stop ends it, once, even though the player was never initialised',
        () async {
      await NativeAudioService.startForegroundEarly(title: 'Rai 1');
      calls.clear();
      expect(await NativeAudioService.stop(), isTrue);
      expect(methods(), ['stopBackground']);

      // Nothing left to stop: a second stop does not touch the service.
      calls.clear();
      expect(await NativeAudioService.stop(), isTrue);
      expect(methods(), isEmpty);
    });

    test('a stop without an early start sends nothing', () async {
      expect(await NativeAudioService.stop(), isTrue);
      expect(methods(), isEmpty);
    });

    test('a refusal returns false and leaves nothing to stop', () async {
      answer = (call) async => call.method == 'startBackground'
          ? throw PlatformException(code: 'FGS_NOT_ALLOWED')
          : true;
      expect(await NativeAudioService.startForegroundEarly(title: 'Rai 1'),
          isFalse);
      calls.clear();
      expect(await NativeAudioService.stop(), isTrue);
      expect(methods(), isEmpty);
    });

    test('a missing native side returns false and leaves nothing to stop',
        () async {
      messenger.setMockMethodCallHandler(channel, null);
      expect(await NativeAudioService.startForegroundEarly(title: 'Rai 1'),
          isFalse);
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        return true;
      });
      expect(await NativeAudioService.stop(), isTrue);
      expect(methods(), isEmpty);
    });

    test('a stop that arrives while the start is still being answered stops '
        'the service and makes the start report false', () async {
      final started = Completer<Object?>();
      answer = (call) => call.method == 'startBackground'
          ? started.future
          : Future<Object?>.value(true);

      final early = NativeAudioService.startForegroundEarly(title: 'Rai 1');
      // Let the call reach the channel.
      await Future<void>.delayed(Duration.zero);
      expect(methods(), ['startBackground']);

      final stopped = NativeAudioService.stop();
      await Future<void>.delayed(Duration.zero);
      expect(methods(), ['startBackground', 'stopBackground']);

      started.complete(true);
      expect(await early, isFalse);
      expect(await stopped, isTrue);

      // Superseded, so the service is not considered running afterwards.
      calls.clear();
      expect(await NativeAudioService.stop(), isTrue);
      expect(methods(), isEmpty);
    });

    test('a start followed by a stop, back to back, sends both in that order',
        () async {
      final early = NativeAudioService.startForegroundEarly(title: 'Rai 1');
      final stopped = NativeAudioService.stop();
      await Future.wait([early, stopped]);
      expect(methods(), ['startBackground', 'stopBackground']);
    });
  });

  group('play after an early start', () {
    test('does not start the service a second time', () async {
      expect(await NativeAudioService.startForegroundEarly(title: 'Rai 1'),
          isTrue);
      expect(await NativeAudioService.play(url: 'http://x/a', title: 'Rai 1'),
          isTrue);
      expect(methods().where((m) => m == 'startBackground'), hasLength(1));
      expect(methods(), contains('updatePlaybackState'));
    });

    test('without an early start it starts the service itself', () async {
      expect(await NativeAudioService.play(url: 'http://x/a', title: 'Rai 1'),
          isTrue);
      expect(methods().where((m) => m == 'startBackground'), hasLength(1));
    });

    test('that fails ends the early service and the player, once', () async {
      await NativeAudioService.startForegroundEarly(title: 'Rai 1');
      failOpen = true;
      expect(await NativeAudioService.play(url: 'http://x/a', title: 'Rai 1'),
          isFalse);
      expect(methods().where((m) => m == 'stopBackground'), hasLength(1));
      // The player that failed was told to stop.
      expect(players.last.stopCalls, 1);

      // The early start is over: the next play starts the service itself.
      failOpen = false;
      calls.clear();
      expect(await NativeAudioService.play(url: 'http://x/b', title: 'Rai 2'),
          isTrue);
      expect(methods().where((m) => m == 'startBackground'), hasLength(1));
    });

    test('that fails without an early start does not touch the service',
        () async {
      failOpen = true;
      expect(await NativeAudioService.play(url: 'http://x/a', title: 'Rai 1'),
          isFalse);
      expect(methods(), isNot(contains('stopBackground')));
    });

    test('that fails while a newer play has taken over leaves the newer '
        'player and the service alone', () async {
      await NativeAudioService.startForegroundEarly(title: 'Rai 1');
      // The early service is stopped by the failed play; hold that round trip
      // open so a zap can start the next play in the middle of it.
      final stopHeld = Completer<Object?>();
      answer = (call) => call.method == 'stopBackground'
          ? stopHeld.future
          : Future<Object?>.value(true);

      failOpen = true;
      final first =
          NativeAudioService.play(url: 'http://x/a', title: 'Rai 1');
      // Let the failed play reach its stopBackground.
      for (var i = 0; i < 20 && !methods().contains('stopBackground'); i++) {
        await Future<void>.delayed(Duration.zero);
      }
      expect(methods(), contains('stopBackground'));

      failOpen = false;
      expect(await NativeAudioService.play(url: 'http://x/b', title: 'Rai 2'),
          isTrue);
      final successor = players.last;
      expect(successor.failOpen, isFalse);

      stopHeld.complete(true);
      expect(await first, isFalse);

      // The stale call must not stop the player that now owns the session.
      expect(successor.stopCalls, 0,
          reason: 'the failed play stopped the player of the play that '
              'replaced it');
    });
  });

  group('native stopRequested', () {
    test('ends the early start: a later play starts the service itself',
        () async {
      expect(await NativeAudioService.startForegroundEarly(title: 'Rai 1'),
          isTrue);
      await NativeAudioService.initialize();
      final controls = <PlaybackControl>[];
      final sub = NativeAudioService.controlStream.listen(controls.add);

      await deliver({'event': 'stopRequested'});
      await sub.cancel();
      expect(controls, [PlaybackControl.stop]);

      calls.clear();
      expect(await NativeAudioService.play(url: 'http://x/a', title: 'Rai 1'),
          isTrue);
      expect(methods().where((m) => m == 'startBackground'), hasLength(1),
          reason: 'the early service is gone, so play() must start its own');
    });

    test('without an early start sends nothing to the native side', () async {
      await NativeAudioService.initialize();
      calls.clear();
      await deliver({'event': 'stopRequested'});
      expect(methods(), isEmpty);
    });
  });

  group('foregroundRefused', () {
    test('reports a refusal that arrives after the start returned true, and '
        'ends the early start', () async {
      final before = NativeAudioService.foregroundRefusalCount;
      var emitted = 0;
      final sub = NativeAudioService.foregroundRefused.listen((_) => emitted++);

      // Nothing has initialised the service: the early start alone has to be
      // listening, or the refusal of this very start would be lost.
      expect(await NativeAudioService.startForegroundEarly(title: 'Rai 1'),
          isTrue);
      await deliver({'event': 'foregroundRefused'});
      await sub.cancel();

      expect(emitted, 1);
      expect(NativeAudioService.foregroundRefusalCount, before + 1);

      // The service is gone: nothing to stop, and a later play starts its own.
      calls.clear();
      expect(await NativeAudioService.stop(), isTrue);
      expect(methods(), isEmpty);
      expect(await NativeAudioService.play(url: 'http://x/a', title: 'Rai 1'),
          isTrue);
      expect(methods().where((m) => m == 'startBackground'), hasLength(1));
    });

    test('a refusal that lands while the start is still being answered makes '
        'the start report false', () async {
      final started = Completer<Object?>();
      answer = (call) => call.method == 'startBackground'
          ? started.future
          : Future<Object?>.value(true);
      final before = NativeAudioService.foregroundRefusalCount;

      final early = NativeAudioService.startForegroundEarly(title: 'Rai 1');
      await Future<void>.delayed(Duration.zero);
      await deliver({'event': 'foregroundRefused'});
      started.complete(true);

      expect(await early, isFalse);
      expect(NativeAudioService.foregroundRefusalCount, before + 1);
    });
  });

  group('whenStopsSettled', () {
    test('is already done when no stop is running', () async {
      await NativeAudioService.whenStopsSettled().timeout(
          const Duration(seconds: 1),
          onTimeout: () => fail('nothing is stopping, so there is nothing to wait for'));
    });

    test('completes only after a running stop has sent its stopBackground',
        () async {
      // A session with a player, so stop() takes the long road and sends
      // `stopBackground` last.
      await NativeAudioService.initialize();
      final gate = Completer<Object?>();
      answer = (call) =>
          call.method == 'stopBackground' ? gate.future : Future<Object?>.value(true);

      final stopping = NativeAudioService.stop();
      await Future<void>.delayed(Duration.zero);
      var settled = false;
      final waiting = NativeAudioService.whenStopsSettled().then((_) => settled = true);
      await Future<void>.delayed(const Duration(milliseconds: 20));

      expect(methods(), contains('stopBackground'));
      expect(settled, isFalse, reason: 'the stop is still in flight');

      gate.complete(null);
      await stopping;
      await waiting;
      expect(settled, isTrue);
    });
  });
}
