import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// The platform channels [PlayerPage] touches on its way into the tree.
///
/// Mounting the player in a widget test reaches native code three ways —
/// picture-in-picture, its three event channels, and `wakelock_plus` — and an
/// unhandled call on any of them throws before the first frame. Shared by
/// every test that renders the player, so the next channel it grows has to be
/// mocked in one place rather than rediscovered by whoever writes the next
/// test.
void mockPlayerPlatformChannels() {
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  messenger.setMockMethodCallHandler(
      const MethodChannel('io.github.giuig.tvninja/pip'), (call) async => null);
  for (final events in ['pip_events', 'noisy_events', 'audio_events']) {
    messenger.setMockMethodCallHandler(
        MethodChannel('io.github.giuig.tvninja/$events'), (call) async => null);
  }
  for (final name in ['toggle', 'isEnabled']) {
    messenger.setMockMessageHandler(
        'dev.flutter.pigeon.wakelock_plus_platform_interface.WakelockPlusApi.$name',
        (message) async => const StandardMessageCodec()
            .encodeMessage(<Object?>[name == 'isEnabled' ? false : null]));
  }
}

/// Undoes [mockPlayerPlatformChannels]. Call in `tearDown`: the mock messenger
/// is process-wide, so a handler left installed outlives the test that set it.
void clearPlayerPlatformChannelMocks() {
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  messenger.setMockMethodCallHandler(
      const MethodChannel('io.github.giuig.tvninja/pip'), null);
  for (final events in ['pip_events', 'noisy_events', 'audio_events']) {
    messenger.setMockMethodCallHandler(
        MethodChannel('io.github.giuig.tvninja/$events'), null);
  }
  for (final name in ['toggle', 'isEnabled']) {
    messenger.setMockMessageHandler(
        'dev.flutter.pigeon.wakelock_plus_platform_interface.WakelockPlusApi.$name',
        null);
  }
}
