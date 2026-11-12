import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Android's "audio becoming noisy" signal: headphones (Bluetooth or wired)
/// are about to disconnect and output is falling back to the speaker.
///
/// Media apps are expected to pause on it and not resume by themselves when
/// the headphones come back — that is what [becomingNoisy] is for. The native
/// receiver only exists while something listens, so subscribe for as long as
/// a player is on screen and cancel with it.
///
/// A channel of its own rather than `audio_events`: that one is only listened
/// to once `NativeAudioService.initialize()` has run, which video mode skips.
class AudioOutputService {
  static const EventChannel _channel =
      EventChannel('io.github.giuig.tvninja/noisy_events');

  static Stream<void> get becomingNoisy {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) {
      return const Stream.empty();
    }
    return _channel
        .receiveBroadcastStream()
        .where((event) => event == 'becomingNoisy')
        .map((_) {});
  }
}
