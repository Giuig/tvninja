import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tvninja/services/native_audio_service.dart';

/// The native-channel side of the foreground service: the screen-state query
/// and the early start that comes before the stream opens. The mpv player is
/// never created here (nothing below calls `initialize` or `play`), so the
/// channel traffic is all there is to look at.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('io.github.giuig.tvninja/audio');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  final calls = <MethodCall>[];
  Future<Object?> Function(MethodCall call)? answer;

  setUp(() async {
    calls.clear();
    answer = null;
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return answer == null ? true : await answer!(call);
    });
    // Static state from an earlier test must not leak into this one.
    await NativeAudioService.stop();
    calls.clear();
  });

  tearDown(() async {
    await NativeAudioService.stop();
    messenger.setMockMethodCallHandler(channel, null);
  });

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
}
