/// Whether the player page should keep the display lit.
///
/// Pure, so the rule can be tested without a player. `player_page.dart`'s
/// `_syncWakelock` applies it after every change to one of its inputs.
///
/// Picture-in-picture is deliberately not an input: a video playing in PiP
/// keeps the screen on like any other playing video, and pausing it lets the
/// screen sleep. Owner decision 2026-10-29, replacing the 2026-09-17 rule that
/// dropped the lock in PiP entirely. The accepted cost: a PiP video left
/// playing keeps the display lit until it is paused or closed.
bool shouldKeepScreenOn({
  required bool isPlaying,
  required bool audioOnlyMode,
  required bool hasError,
}) =>
    isPlaying && !audioOnlyMode && !hasError;
