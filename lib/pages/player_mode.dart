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

/// Why the channel currently playing is (or isn't) in audio mode, tracked
/// across zaps so the *next* zap's decision knows whether to carry it
/// forward.
///
/// [locked] alone (from [PlayerModeDecision]/[StreamKindVerdict]) isn't
/// enough for that: a manual choice and a classifier lock both eventually
/// settle on the same `audio: true` decision, but they behave differently
/// once the user zaps away, since only a manual choice is meant to follow
/// them.
enum AudioModeReason {
  /// Not currently in audio mode.
  none,

  /// In audio mode because the classifier locked the current channel's own
  /// evidence -- doesn't survive a zap to a channel that isn't itself
  /// strong audio.
  detected,

  /// In audio mode because the user chose it themselves (the AppBar toggle,
  /// or a rejoined background session that wasn't independently classified
  /// as strong audio) -- survives a zap regardless of the target's own
  /// evidence, exactly like the app behaved before this feature existed.
  user,
}

/// The result of re-deciding the mode on a zap: the same policy decision
/// [decideMode] would reach for the target channel's own evidence, plus
/// which [AudioModeReason] the player page should remember afterwards --
/// needed because *that* value is what the zap after this one will read as
/// its own `current`.
typedef ZapModeDecision = ({PlayerModeDecision decision, AudioModeReason reason});

/// Re-decides the mode when zapping away from a channel whose current audio
/// state is explained by [current], onto a channel whose evidence is
/// [verdict].
///
/// Three rules, applied in order:
///
/// 1. **The target's own strong evidence always wins.** A channel that
///    [StreamKindVerdict.locksAudio] on its own opens locked, exactly like a
///    fresh [decideMode] call would, regardless of [current] -- nothing about
///    the channel being left changes what *this* one's evidence says. What
///    does depend on [current] is only the reason carried forward: a
///    [AudioModeReason.user] override survives being routed through a
///    channel that also happens to qualify on its own -- the person's own
///    choice to hear audio persists until they change it, with no exception
///    for an intervening channel that would have locked audio on its own --
///    so it's kept rather than downgraded to [AudioModeReason.detected].
/// 2. **A [AudioModeReason.user] current mode always carries forward.** If
///    the target's own evidence doesn't already lock it (rule 1 handles that
///    case), the user's manual choice follows them to any channel until they
///    turn it off again -- today's behaviour, unchanged by this feature.
/// 3. **Otherwise, detected audio doesn't stick.** A [AudioModeReason.detected]
///    (or already-[AudioModeReason.none]) current mode never carries a
///    non-strong target into audio -- there's nothing about *this* channel
///    that earned it, so it opens exactly as [decideMode] says: video.
ZapModeDecision decideModeForZap({
  required AudioModeReason current,
  required StreamKindVerdict verdict,
}) {
  final decision = decideMode(verdict);

  if (decision.audio) {
    return (
      decision: decision,
      reason: current == AudioModeReason.user
          ? AudioModeReason.user
          : AudioModeReason.detected,
    );
  }

  if (current == AudioModeReason.user) {
    return (
      decision: PlayerModeDecision(
        audio: true,
        locked: false,
        reason: decision.reason,
      ),
      reason: AudioModeReason.user,
    );
  }

  return (decision: decision, reason: AudioModeReason.none);
}

/// Which body `PlayerPage._buildBody` should show, in the same precedence
/// `_buildBody` itself applies: an error screen first, then the loading
/// placeholder while the stream's kind is still being decided, then
/// audio-vs-video.
enum PlayerBody { error, resolving, audio, video }

/// Pure counterpart of `PlayerPage._buildBody`'s branching, pulled out so the
/// precedence above can be unit tested without a full `PlayerPage` widget --
/// one needs a live `NativeAudioService` and platform channels that neither
/// `flutter_test` nor a loopback server can stand in for.
///
/// This precedence is exactly what a real defect got wrong: `_buildBody`
/// checks "still resolving" (`resolving`) before "audio or video", so a
/// channel whose kind lock never flipped `modeResolved` to `true` stayed on
/// the `resolving` placeholder forever, even while audio was already
/// playing underneath. See `_enterAudioModeState`'s doc comment in
/// `player_page.dart` for where that flip now happens.
PlayerBody playerBodyFor({
  required bool hasError,
  required bool modeResolved,
  required bool audioOnlyMode,
}) {
  if (hasError) return PlayerBody.error;
  if (!modeResolved) return PlayerBody.resolving;
  if (audioOnlyMode) return PlayerBody.audio;
  return PlayerBody.video;
}
