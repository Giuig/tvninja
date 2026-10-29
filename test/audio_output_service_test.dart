import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tvninja/services/audio_output_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = EventChannel('io.github.giuig.tvninja/noisy_events');

  setUp(() => debugDefaultTargetPlatformOverride = TargetPlatform.android);
  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockStreamHandler(channel, null);
  });

  void mockEvents(List<Object?> events) {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockStreamHandler(
      channel,
      MockStreamHandler.inline(onListen: (args, sink) {
        for (final e in events) {
          sink.success(e);
        }
        sink.endOfStream();
      }),
    );
  }

  test('emits once for every becomingNoisy event from Android', () async {
    mockEvents(['becomingNoisy', 'becomingNoisy']);
    final events = await AudioOutputService.becomingNoisy.toList();
    expect(events, hasLength(2));
  });

  test('ignores payloads it does not know', () async {
    mockEvents(['somethingElse', 42, 'becomingNoisy']);
    final events = await AudioOutputService.becomingNoisy.toList();
    expect(events, hasLength(1));
  });

  test('is empty off Android, where there is no receiver', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    final events = await AudioOutputService.becomingNoisy.toList();
    expect(events, isEmpty);
  });
}
