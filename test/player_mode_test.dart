import 'package:flutter_test/flutter_test.dart';
import 'package:tvninja/pages/player_mode.dart';
import 'package:tvninja/services/video/stream_kind.dart';

void main() {
  group('decideMode', () {
    test('radio="true" (strong audio) locks audio mode', () {
      const verdict = StreamKindVerdict(
        StreamKind.audioOnly,
        KindConfidence.strong,
        KindSource.radioAttribute,
      );

      final decision = decideMode(verdict);

      expect(decision.audio, isTrue);
      expect(decision.locked, isTrue);
      expect(decision.reason, verdict.toString());
    });

    test('strong audio via Content-Type locks audio mode', () {
      const verdict = StreamKindVerdict(
        StreamKind.audioOnly,
        KindConfidence.strong,
        KindSource.contentType,
      );

      final decision = decideMode(verdict);

      expect(decision.audio, isTrue);
      expect(decision.locked, isTrue);
    });

    test('strong audio via an icy-* header locks audio mode', () {
      const verdict = StreamKindVerdict(
        StreamKind.audioOnly,
        KindConfidence.strong,
        KindSource.icyHeader,
      );

      final decision = decideMode(verdict);

      expect(decision.audio, isTrue);
      expect(decision.locked, isTrue);
    });

    test('strong audio via a plausible-bandwidth HLS master locks audio mode',
        () {
      const verdict = StreamKindVerdict(
        StreamKind.audioOnly,
        KindConfidence.strong,
        KindSource.hlsMasterCodecs,
      );

      final decision = decideMode(verdict);

      expect(decision.audio, isTrue);
      expect(decision.locked, isTrue);
    });

    test('strong audio via a packed-audio HLS media playlist locks audio mode',
        () {
      const verdict = StreamKindVerdict(
        StreamKind.audioOnly,
        KindConfidence.strong,
        KindSource.hlsMediaPlaylist,
      );

      final decision = decideMode(verdict);

      expect(decision.audio, isTrue);
      expect(decision.locked, isTrue);
    });

    test(
        'provisional audio (LaC News 24 shape: audio-only CODECS above the '
        'bandwidth guard) opens as video, unlocked', () {
      const verdict = StreamKindVerdict(
        StreamKind.audioOnly,
        KindConfidence.provisional,
        KindSource.hlsMasterCodecs,
      );

      final decision = decideMode(verdict);

      expect(decision.audio, isFalse);
      expect(decision.locked, isFalse);
    });

    test('a plain video verdict opens as video, unlocked', () {
      const verdict = StreamKindVerdict(
        StreamKind.video,
        KindConfidence.strong,
        KindSource.hlsMasterCodecs,
      );

      final decision = decideMode(verdict);

      expect(decision.audio, isFalse);
      expect(decision.locked, isFalse);
    });

    test('a video Content-Type opens as video, unlocked', () {
      const verdict = StreamKindVerdict(
        StreamKind.video,
        KindConfidence.strong,
        KindSource.contentType,
      );

      final decision = decideMode(verdict);

      expect(decision.audio, isFalse);
      expect(decision.locked, isFalse);
    });

    test('StreamKindVerdict.unknown (a cap-out or undecidable playlist) '
        'opens as video, unlocked -- never worse than today', () {
      final decision = decideMode(StreamKindVerdict.unknown);

      expect(decision.audio, isFalse);
      expect(decision.locked, isFalse);
    });

    test('reason carries the verdict\'s own description, for logging', () {
      const verdict = StreamKindVerdict(
        StreamKind.audioOnly,
        KindConfidence.strong,
        KindSource.contentType,
      );

      final decision = decideMode(verdict);

      expect(decision.reason, 'audioOnly/strong via contentType');
    });
  });

  group('PlayerModeDecision', () {
    test('cannot be constructed locked without audio', () {
      expect(
        () => PlayerModeDecision(audio: false, locked: true, reason: 'x'),
        throwsA(isA<AssertionError>()),
      );
    });

    test('toString distinguishes audio, locked audio, and video', () {
      expect(
        const PlayerModeDecision(audio: true, locked: true, reason: 'r')
            .toString(),
        'audio/locked (r)',
      );
      expect(
        const PlayerModeDecision(audio: true, locked: false, reason: 'r')
            .toString(),
        'audio (r)',
      );
      expect(
        const PlayerModeDecision(audio: false, locked: false, reason: 'r')
            .toString(),
        'video (r)',
      );
    });
  });

  group('decideModeForZap', () {
    const strongAudio = StreamKindVerdict(
      StreamKind.audioOnly,
      KindConfidence.strong,
      KindSource.radioAttribute,
    );
    const provisionalAudio = StreamKindVerdict(
      StreamKind.audioOnly,
      KindConfidence.provisional,
      KindSource.hlsMasterCodecs,
    );
    const video = StreamKindVerdict(
      StreamKind.video,
      KindConfidence.strong,
      KindSource.hlsMasterCodecs,
    );

    test('a strong-audio target locks regardless of the current reason', () {
      for (final current in AudioModeReason.values) {
        final zap = decideModeForZap(current: current, verdict: strongAudio);
        expect(zap.decision.audio, isTrue, reason: '$current');
        expect(zap.decision.locked, isTrue, reason: '$current');
      }
    });

    test(
        'a strong-audio target carries a user override forward as user, '
        'not detected', () {
      final zap = decideModeForZap(
        current: AudioModeReason.user,
        verdict: strongAudio,
      );
      expect(zap.reason, AudioModeReason.user);
    });

    test(
        'a strong-audio target reached with no prior user override is '
        'recorded as detected', () {
      for (final current in [AudioModeReason.none, AudioModeReason.detected]) {
        final zap = decideModeForZap(current: current, verdict: strongAudio);
        expect(zap.reason, AudioModeReason.detected, reason: '$current');
      }
    });

    test(
        'a detected-audio channel zapping to a non-strong target falls back '
        'to video, unlocked', () {
      for (final verdict in [video, provisionalAudio, StreamKindVerdict.unknown]) {
        final zap = decideModeForZap(
          current: AudioModeReason.detected,
          verdict: verdict,
        );
        expect(zap.decision.audio, isFalse);
        expect(zap.decision.locked, isFalse);
        expect(zap.reason, AudioModeReason.none);
      }
    });

    test(
        'a channel already in video (no prior audio) zapping to a '
        'non-strong target stays in video', () {
      final zap = decideModeForZap(
        current: AudioModeReason.none,
        verdict: video,
      );
      expect(zap.decision.audio, isFalse);
      expect(zap.reason, AudioModeReason.none);
    });

    test(
        'a user-chosen audio channel zapping to a non-strong target stays '
        'in audio, unlocked -- today\'s behaviour', () {
      for (final verdict in [video, provisionalAudio, StreamKindVerdict.unknown]) {
        final zap = decideModeForZap(
          current: AudioModeReason.user,
          verdict: verdict,
        );
        expect(zap.decision.audio, isTrue, reason: '$verdict');
        expect(zap.decision.locked, isFalse, reason: '$verdict');
        expect(zap.reason, AudioModeReason.user, reason: '$verdict');
      }
    });

    test('a user-chosen target still carries the verdict\'s own reason text',
        () {
      final zap = decideModeForZap(
        current: AudioModeReason.user,
        verdict: video,
      );
      expect(zap.decision.reason, video.toString());
    });
  });

  group('playerBodyFor', () {
    // This is the precedence `PlayerPage._buildBody` applies, and it is a
    // real regression case: a channel the async probe locked into audio used
    // to leave `modeResolved` false forever, so `_buildBody` kept returning
    // the `resolving` placeholder even though audio was already playing.
    // `hasError` and `!modeResolved` must each win over `audioOnlyMode`, in
    // that order.
    test('an error always wins, regardless of the other two flags', () {
      expect(
        playerBodyFor(
            hasError: true, modeResolved: true, audioOnlyMode: true),
        PlayerBody.error,
      );
      expect(
        playerBodyFor(
            hasError: true, modeResolved: false, audioOnlyMode: false),
        PlayerBody.error,
      );
    });

    test(
        'still resolving shows the loading placeholder even when '
        'audioOnlyMode is already true -- the exact shape of the regression',
        () {
      expect(
        playerBodyFor(
            hasError: false, modeResolved: false, audioOnlyMode: true),
        PlayerBody.resolving,
      );
      expect(
        playerBodyFor(
            hasError: false, modeResolved: false, audioOnlyMode: false),
        PlayerBody.resolving,
      );
    });

    test('resolved and audio-only shows the audio placeholder', () {
      expect(
        playerBodyFor(
            hasError: false, modeResolved: true, audioOnlyMode: true),
        PlayerBody.audio,
      );
    });

    test('resolved and not audio-only shows video', () {
      expect(
        playerBodyFor(
            hasError: false, modeResolved: true, audioOnlyMode: false),
        PlayerBody.video,
      );
    });
  });

  group('playPauseActionFor', () {
    test('active and playing pauses the native audio session', () {
      expect(
        playPauseActionFor(
            isAudioModeActive: true, audioOnlyMode: true, isPlaying: true),
        PlayPauseAction.pauseAudio,
      );
    });

    test('active and not playing resumes the native audio session', () {
      expect(
        playPauseActionFor(
            isAudioModeActive: true, audioOnlyMode: true, isPlaying: false),
        PlayPauseAction.resumeAudio,
      );
    });

    // The regression case: a locked channel's notification Stop leaves
    // exactly this shape -- audioOnlyMode true, isAudioModeActive false --
    // and the pre-fix code called the (unmounted, in audio mode) video
    // player's play(), a silent no-op.
    test(
        'audio mode but inactive starts native audio, regardless of '
        'isPlaying', () {
      expect(
        playPauseActionFor(
            isAudioModeActive: false, audioOnlyMode: true, isPlaying: false),
        PlayPauseAction.startNativeAudio,
      );
      expect(
        playPauseActionFor(
            isAudioModeActive: false, audioOnlyMode: true, isPlaying: true),
        PlayPauseAction.startNativeAudio,
      );
    });

    test('video mode and playing pauses the video player', () {
      expect(
        playPauseActionFor(
            isAudioModeActive: false, audioOnlyMode: false, isPlaying: true),
        PlayPauseAction.pauseVideo,
      );
    });

    test('video mode and not playing plays the video player', () {
      expect(
        playPauseActionFor(
            isAudioModeActive: false,
            audioOnlyMode: false,
            isPlaying: false),
        PlayPauseAction.playVideo,
      );
    });
  });

  group('retryActionFor', () {
    test('not in audio mode retries the video player', () {
      expect(
        retryActionFor(audioOnlyMode: false, isAudioModeActive: true),
        RetryAction.retryVideo,
      );
      expect(
        retryActionFor(audioOnlyMode: false, isAudioModeActive: false),
        RetryAction.retryVideo,
      );
    });

    test('audio mode and active switches the audio channel', () {
      expect(
        retryActionFor(audioOnlyMode: true, isAudioModeActive: true),
        RetryAction.switchAudioChannel,
      );
    });

    // The regression case: `_switchAudioChannelIfNeeded` itself
    // early-returns as a no-op while `isAudioModeActive` is false, so the
    // pre-fix code left Retry dead for exactly this shape -- a locked
    // channel's failed native start, or a manual toggle stopped the same
    // way.
    test('audio mode and inactive starts native audio', () {
      expect(
        retryActionFor(audioOnlyMode: true, isAudioModeActive: false),
        RetryAction.startNativeAudio,
      );
    });
  });
}
