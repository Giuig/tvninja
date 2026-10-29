import 'package:flutter_test/flutter_test.dart';
import 'package:tvninja/pages/screen_wake_policy.dart';

bool _keepOn({
  bool isPlaying = true,
  bool audioOnlyMode = false,
  bool hasError = false,
}) =>
    shouldKeepScreenOn(
      isPlaying: isPlaying,
      audioOnlyMode: audioOnlyMode,
      hasError: hasError,
    );

void main() {
  test('playing video keeps the screen on, in the player or in PiP', () {
    expect(_keepOn(), isTrue);
  });

  test('paused video lets the screen sleep', () {
    expect(_keepOn(isPlaying: false), isFalse);
  });

  test('audio-only mode lets the screen sleep', () {
    expect(_keepOn(audioOnlyMode: true), isFalse);
  });

  test('an error screen lets the screen sleep', () {
    expect(_keepOn(hasError: true), isFalse);
  });
}
