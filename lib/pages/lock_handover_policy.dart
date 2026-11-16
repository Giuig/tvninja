import 'package:tvninja/pages/player_mode.dart';

/// Pure rules for the lock-screen handover: when a locked screen switches a
/// playing video to sound mode, and what happens to that sound mode when the
/// screen comes back.
///
/// Kept free of widgets, platform channels and the audio service so the whole
/// decision table can be tested exhaustively; `PlayerPage` only gathers the
/// inputs (captured *before* the video player pauses itself on the lifecycle
/// change, otherwise "was it playing" would read the paused state) and acts on
/// the answer.

/// Whether a screen that has just gone off should switch the current video to
/// sound mode.
///
/// Hands over only for a video that was actually going to be heard:
/// [wasPlayingVideo], or one that was still loading toward playback
/// ([wasLoadingVideo]: the person pressed play or zapped and the picture has
/// not arrived yet, so the lock would otherwise leave a stream opening in the
/// background for nobody). Everything else is left exactly as it is:
///
/// * a **paused** video stays paused (neither flag set): a lock must not start
///   sound the person had stopped;
/// * **picture-in-picture** ([inPip]) is left alone: unlocking from PiP does
///   not deliver the resume that would bring video back;
/// * a page showing an **error** ([hasError]) has nothing playing to hand over;
/// * a channel **already in sound mode** ([audioOnlyMode]: chosen by hand,
///   classified as audio, or handed over by an earlier lock) keeps its
///   session untouched;
/// * a screen that is still **interactive** ([screenInteractive]) was not a
///   lock at all: the app went to the background some other way (Home with PiP
///   off, the shade, a dismissed PiP window);
/// * **web** ([isWeb]) never hands over: there a lifecycle "paused" means the
///   tab was hidden, not that the device locked, and no native service exists.
bool shouldHandOverOnLock({
  required bool wasPlayingVideo,
  required bool wasLoadingVideo,
  required bool audioOnlyMode,
  required bool hasError,
  required bool inPip,
  required bool screenInteractive,
  required bool isWeb,
}) {
  if (isWeb) return false;
  if (screenInteractive) return false;
  if (inPip) return false;
  if (audioOnlyMode) return false;
  if (hasError) return false;
  return wasPlayingVideo || wasLoadingVideo;
}

/// What the page does with the sound mode it is in when the screen comes back
/// (lifecycle `resumed`).
enum LockReturnAction {
  /// The lock caused this sound mode and nothing cancelled it: go back to
  /// video.
  returnToVideo,

  /// The lock caused this sound mode, but the person paused the sound on the
  /// lock screen: stay in sound mode, paused, rather than starting a picture
  /// (with sound) they had just stopped. The page records the reason as
  /// [AudioModeReason.user] so nothing later returns to video by itself.
  stayInAudio,

  /// Not a lock-caused sound mode (video, manual, classifier-locked, or one
  /// the person already took over): leave everything as it is.
  none,
}

/// Decides the [LockReturnAction] for the current [reason].
///
/// Only [AudioModeReason.screenLock] ever returns to video. Any user action
/// during the lock (Stop, the manual toggle, a zap) has already replaced the
/// reason with [AudioModeReason.user] by the time this runs, which is how those
/// actions cancel the return without this function knowing about them.
/// [audioPausedByUser] is whether the person paused the sound during the lock
/// (and has not played it again).
LockReturnAction lockReturnActionFor({
  required AudioModeReason reason,
  required bool audioPausedByUser,
}) {
  if (reason != AudioModeReason.screenLock) return LockReturnAction.none;
  return audioPausedByUser
      ? LockReturnAction.stayInAudio
      : LockReturnAction.returnToVideo;
}
