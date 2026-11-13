import 'dart:async';
import 'dart:math';

/// Engine-agnostic exponential-backoff reconnect controller.
///
/// Modeled on `native_audio_service.dart`'s `_scheduleReconnect()` (background
/// audio's proven backoff): the same 5-attempt ceiling, the same
/// reset-on-success semantics, and the schedule `min(30, 2 * (1 << attempt))`
/// → 2s / 4s / 8s / 16s / 30s — except that a caller may shorten the **first**
/// step with [firstDelay] (foreground video does, to 0.25s; see there for why).
/// Every later step is the same for every caller.
///
/// Unlike the audio service (static/singleton — one process-wide background
/// player), this is a plain instantiable class: foreground video needs one
/// instance per player state (`UnifiedVideoPlayerState`).
///
/// Deliberately has **zero engine dependencies** (no `media_kit` /
/// `video_player` imports) so it can drive both the mpv path (this phase) and
/// a future ExoPlayer path (a later phase) unchanged.
///
/// The native audio service's loop is externally re-triggered: each failed
/// reconnect attempt causes mpv to emit a fresh `stream.error` event, and
/// *that* is what calls `_scheduleReconnect()` again. The foreground video
/// player has no equivalent per-attempt error stream at this layer (only
/// buffering-watchdog timers), so this controller drives its own chain: once
/// [schedule] is called, it keeps invoking [onRetry] at increasing backoff
/// intervals — regardless of whether a given [onRetry] call throws — until
/// [reset] is called (success, or a fresh user action) or the 5-attempt
/// ceiling is reached, at which point [onGiveUp] fires once and the chain
/// stops. [cancel] stops the chain without notifying [onGiveUp] (used on
/// dispose, where nothing should fire after teardown).
class ReconnectController {
  ReconnectController({
    required this.onRetry,
    required this.onGiveUp,
    this.firstDelay = const Duration(seconds: 2),
  });

  /// Invoked to actually attempt a reconnect (e.g. reopen the current URL, or
  /// tear down and recreate the player). This controller does not inspect
  /// success/failure beyond catching a thrown error for safety — real success
  /// is expected to be signalled back via [reset] (e.g. once the caller sees
  /// a first frame from the reopened stream).
  final Future<void> Function() onRetry;

  /// Invoked once 5 attempts have been made without an intervening [reset].
  final void Function() onGiveUp;

  static const int _maxAttempts = 5;

  /// How long the first attempt of a chain waits. Defaults to 2s, the first
  /// step of `min(30, 2 * (1 << attempt))` and what every caller had before.
  ///
  /// Foreground video passes 0.25s (2026-11-13). On a live stream the wait is
  /// not neutral: by the time a reconnect is scheduled the engine is already
  /// dead (`ExoPlayer` goes IDLE on a source error and nothing in
  /// `video_player` re-prepares it), so every second spent waiting is
  /// broadcast the viewer never sees, and the re-prepared stream resumes at
  /// the live edge. Measured on Rete 4 (release 1.7.0, BlueStacks): a stale
  /// playlist raised a source error and the picture jumped forward ~2.4s, 2.0s
  /// of it this delay. The later steps are unchanged — they are what protects a
  /// genuinely dead source — and so is the 5-attempt ceiling.
  ///
  /// It stays a parameter rather than a new constant so a caller whose retry is
  /// not a cheap local rebuild keeps the 2s it was tuned for.
  final Duration firstDelay;

  /// The wait before attempt number [attempt] (0-based): [firstDelay], then
  /// 4s / 8s / 16s / 30s.
  Duration delayFor(int attempt) => attempt == 0
      ? firstDelay
      : Duration(seconds: min(30, 2 * (1 << attempt)));

  int _attempt = 0;
  Timer? _timer;

  /// Bumped by [reset] and [cancel]. [_fire] captures the current value
  /// before awaiting [onRetry] and compares it again afterward — if it
  /// changed, a [reset]/[cancel] ran while [onRetry] was in flight (the
  /// classic case: `dispose()` while a heavy reconnect attempt is mid-await),
  /// and the trailing self-reschedule below must NOT run. `Timer.cancel()`
  /// alone can't stop this: by the time [reset]/[cancel] runs, the timer has
  /// already fired and [_fire] is a live, executing coroutine — there is no
  /// pending [Timer] left to cancel.
  int _generation = 0;

  /// Number of reconnect attempts fired since the last [reset]/[cancel].
  int get attempt => _attempt;

  /// Schedules the next reconnect attempt with exponential backoff
  /// ([firstDelay], then 4, 8, 16, 30 seconds). Safe to call repeatedly/redundantly — e.g. from more
  /// than one external trigger (a watchdog timer, a failed open()) — since it
  /// simply (re)arms the pending timer at the current attempt's delay rather
  /// than double-counting attempts.
  ///
  /// If 5 attempts have already been made, calls [onGiveUp] immediately
  /// instead of scheduling another one.
  ///
  /// [immediate] skips even [firstDelay] — but only for the first attempt of a
  /// chain. It is for a caller that knows the engine is already dead and that
  /// waiting buys nothing (an engine-reported fatal error); the timer still
  /// fires on the next event-loop turn rather than synchronously, so the
  /// caller can be inside the engine's own notification when it asks. Every
  /// later attempt keeps its normal backoff, so a source that stays dead is
  /// not hammered.
  void schedule({bool immediate = false}) {
    _timer?.cancel();
    if (_attempt >= _maxAttempts) {
      _attempt = 0;
      onGiveUp();
      return;
    }
    final delay =
        immediate && _attempt == 0 ? Duration.zero : delayFor(_attempt);
    final generation = _generation;
    _timer = Timer(delay, () => _fire(generation));
  }

  Future<void> _fire(int generation) async {
    _attempt++;
    try {
      await onRetry();
    } catch (_) {
      // onRetry is responsible for any engine-specific error handling of its
      // own; a thrown error here just means this particular attempt didn't
      // succeed. Either way, keep the chain going below (unless superseded,
      // see the generation check) — real success is only known once the
      // caller observes it and calls reset().
    }
    if (generation != _generation) {
      // reset()/cancel() ran while onRetry() was awaiting above — this
      // attempt has been superseded (success, a fresh user action, or
      // dispose). Don't resurrect the chain.
      return;
    }
    // Keep retrying until reset() (success / user action) or cancel()
    // (dispose) stops the chain, or the attempt ceiling calls onGiveUp.
    schedule();
  }

  /// Cancels any pending attempt and zeroes the attempt counter. Call this on
  /// success (first frame received after a reconnect) or on a fresh
  /// user-initiated action (e.g. a channel switch) so the next failure starts
  /// the backoff over again from [firstDelay]. Also invalidates any attempt currently
  /// in flight (see [_generation]) so it won't reschedule itself once its
  /// `onRetry` await completes.
  void reset() {
    _timer?.cancel();
    _timer = null;
    _attempt = 0;
    _generation++;
  }

  /// Cancels any pending attempt without notifying [onGiveUp] and without
  /// resetting the attempt counter. Call this on dispose so neither a
  /// pending retry timer nor an attempt already in flight (see
  /// [_generation]) can fire/reschedule after the owning object is gone.
  void cancel() {
    _timer?.cancel();
    _timer = null;
    _generation++;
  }
}
