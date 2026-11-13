import 'package:flutter_test/flutter_test.dart';
import 'package:tvninja/pages/lock_handover_policy.dart';
import 'package:tvninja/pages/player_mode.dart';

/// A video that is playing in the foreground on a locked-then-asleep Android
/// screen: the one case that hands over. Each test below flips one input.
bool _handOver({
  bool wasPlayingVideo = true,
  bool wasLoadingVideo = false,
  bool audioOnlyMode = false,
  bool hasError = false,
  bool inPip = false,
  bool screenInteractive = false,
  bool isWeb = false,
}) =>
    shouldHandOverOnLock(
      wasPlayingVideo: wasPlayingVideo,
      wasLoadingVideo: wasLoadingVideo,
      audioOnlyMode: audioOnlyMode,
      hasError: hasError,
      inPip: inPip,
      screenInteractive: screenInteractive,
      isWeb: isWeb,
    );

void main() {
  group('shouldHandOverOnLock', () {
    test('a playing video on a screen that went off hands over', () {
      expect(_handOver(), isTrue);
    });

    test('a video that was still loading hands over too', () {
      expect(_handOver(wasPlayingVideo: false, wasLoadingVideo: true), isTrue);
    });

    test('playing and loading together hand over', () {
      expect(_handOver(wasLoadingVideo: true), isTrue);
    });

    test('a paused video does not: it stays paused through the lock', () {
      expect(_handOver(wasPlayingVideo: false, wasLoadingVideo: false), isFalse);
    });

    test('picture-in-picture is left alone', () {
      expect(_handOver(inPip: true), isFalse);
      expect(_handOver(inPip: true, wasPlayingVideo: false, wasLoadingVideo: true),
          isFalse);
    });

    test('a page showing an error does not', () {
      expect(_handOver(hasError: true), isFalse);
      expect(_handOver(hasError: true, wasPlayingVideo: false, wasLoadingVideo: true),
          isFalse);
    });

    test('a channel already in sound mode does not (manual, detected or lock)',
        () {
      // The mode itself is what the input carries; the reason behind it is
      // irrelevant to the hand-over, so one flag covers all three.
      expect(_handOver(audioOnlyMode: true), isFalse);
      expect(_handOver(audioOnlyMode: true, wasPlayingVideo: false), isFalse);
    });

    test('a screen that is still interactive does not (PiP dismissed, shade)',
        () {
      expect(_handOver(screenInteractive: true), isFalse);
    });

    test('web never hands over, whatever else is true', () {
      expect(_handOver(isWeb: true), isFalse);
      expect(
          _handOver(
              isWeb: true,
              wasPlayingVideo: true,
              wasLoadingVideo: true,
              screenInteractive: false),
          isFalse);
    });

    test('every one of the 128 input combinations follows the one rule', () {
      for (var bits = 0; bits < 128; bits++) {
        bool bit(int i) => (bits >> i) & 1 == 1;
        final wasPlaying = bit(0),
            wasLoading = bit(1),
            audioOnly = bit(2),
            error = bit(3),
            pip = bit(4),
            interactive = bit(5),
            web = bit(6);
        final expected = !web &&
            !interactive &&
            !pip &&
            !audioOnly &&
            !error &&
            (wasPlaying || wasLoading);
        expect(
          _handOver(
            wasPlayingVideo: wasPlaying,
            wasLoadingVideo: wasLoading,
            audioOnlyMode: audioOnly,
            hasError: error,
            inPip: pip,
            screenInteractive: interactive,
            isWeb: web,
          ),
          expected,
          reason: 'bits=$bits',
        );
      }
    });
  });

  group('lockReturnActionFor', () {
    test('a lock-caused sound mode returns to video when not paused', () {
      expect(
        lockReturnActionFor(
            reason: AudioModeReason.screenLock, audioPausedByUser: false),
        LockReturnAction.returnToVideo,
      );
    });

    test('a lock-caused sound mode the person paused stays in sound mode', () {
      expect(
        lockReturnActionFor(
            reason: AudioModeReason.screenLock, audioPausedByUser: true),
        LockReturnAction.stayInAudio,
      );
    });

    test('every other reason does nothing, paused or not', () {
      for (final reason in AudioModeReason.values) {
        if (reason == AudioModeReason.screenLock) continue;
        for (final paused in [false, true]) {
          expect(
            lockReturnActionFor(reason: reason, audioPausedByUser: paused),
            LockReturnAction.none,
            reason: '$reason paused=$paused',
          );
        }
      }
    });
  });
}
