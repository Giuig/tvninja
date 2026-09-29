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
}
