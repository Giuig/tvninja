import 'package:tvninja/services/video/stream_kind.dart';

/// What the player should open as, and why -- the UI-layer policy decision
/// derived from a [StreamKindVerdict].
///
/// Kept separate from [StreamKindVerdict] on purpose: the verdict is
/// classification evidence, owned by `services/video` and reusable anywhere
/// a stream needs classifying; this is what the player page does with that
/// evidence, and stays in `pages` alongside the state it drives.
class PlayerModeDecision {
  /// Whether the player should open in audio mode.
  final bool audio;

  /// Whether the video toggle should be unreachable. Only ever true
  /// alongside [audio] -- a channel is never locked into video, since a
  /// wrong video guess costs nothing today's app doesn't already cost.
  final bool locked;

  /// A short, loggable explanation for the decision -- the verdict's own
  /// `toString()` for an evidence-based one.
  final String reason;

  const PlayerModeDecision({
    required this.audio,
    required this.locked,
    required this.reason,
  }) : assert(
          !locked || audio,
          'a decision cannot lock video mode -- only audio locks',
        );

  @override
  String toString() {
    final mode = audio ? (locked ? 'audio/locked' : 'audio') : 'video';
    return '$mode ($reason)';
  }
}

/// Derives the player's opening mode from a stream-kind verdict.
///
/// Only a verdict [StreamKindVerdict.locksAudio] considers trustworthy opens
/// as locked audio. Every other verdict -- a plain video verdict, an
/// unresolved [StreamKind.unknown], or a provisional audio guess (an HLS
/// master with plausible-looking but unconfirmed audio CODECS, e.g. a TV
/// channel whose playlist happens to omit its own video codec) -- opens as
/// video, exactly like the app did before any of this classification
/// existed. A wrong guess is therefore never worse than today's behaviour.
PlayerModeDecision decideMode(StreamKindVerdict verdict) {
  if (verdict.locksAudio) {
    return PlayerModeDecision(
      audio: true,
      locked: true,
      reason: verdict.toString(),
    );
  }
  return PlayerModeDecision(
    audio: false,
    locked: false,
    reason: verdict.toString(),
  );
}
