import 'dart:async';
import 'dart:math';

/// Engine-agnostic exponential-backoff reconnect controller.
///
/// Modeled on `native_audio_service.dart`'s `_scheduleReconnect()` (background
/// audio's proven backoff): the same 5-attempt ceiling, the same
/// reset-on-success semantics, and the schedule `min(30, 2 * (1 << attempt))`
/// → 2s / 4s / 8s / 16s / 30s — except that a caller may shorten the **first**
/// step of one particular [schedule] call (foreground video does, for a stream
/// that was playing; see [schedule] for why and for why it must stay per call).
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

  /// The wait before attempt number [attempt] (0-based): 2s, 4s, 8s, 16s, 30s.
  static Duration delayFor(int attempt) =>
      Duration(seconds: min(30, 2 * (1 << attempt)));

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

  /// Schedules the next reconnect attempt with exponential backoff (2, 4, 8,
  /// 16, 30 seconds). Safe to call repeatedly/redundantly — e.g. from more
  /// than one external trigger (a watchdog timer, a failed open()) — since it
  /// simply (re)arms the pending timer at the current attempt's delay rather
  /// than double-counting attempts.
  ///
  /// If 5 attempts have already been made, calls [onGiveUp] immediately
  /// instead of scheduling another one.
  ///
  /// [firstDelay] replaces the wait of the **first** attempt of a chain only
  /// (`_attempt == 0`); every later step keeps its backoff, so a source that
  /// stays dead is not hammered. It is per call, not per controller, on
  /// purpose (2026-11-13):
  ///
  /// - It is for a caller that knows the engine is already dead and that the
  ///   wait is lost broadcast: a live stream that was playing and then raised a
  ///   fatal error (`ExoPlayer` goes IDLE and nothing re-prepares it, and the
  ///   re-prepared stream resumes at the live edge). Measured on Rete 4: 2.0s
  ///   of a ~2.4s skip was this wait.
  /// - It is wrong for a load that never started, and for the restart after
  ///   [onGiveUp]. There the error screen is only shown after a diagnostic
  ///   probe (a real HTTP GET, hundreds of ms) returns, and it is discarded if
  ///   a rebuild began in the meantime — a first step faster than the probe
  ///   made a dead channel spin forever instead of showing its error. Those
  ///   callers pass nothing and keep the 2s.
  ///
  /// A timer for `Duration.zero` still fires on the next event-loop turn, not
  /// synchronously, so a caller can ask from inside the engine's own
  /// notification. A plain [schedule] arriving while a shortened first timer is
  /// pending re-arms it at the full first step, like any redundant call.
  void schedule({Duration? firstDelay}) {
    _timer?.cancel();
    if (_attempt >= _maxAttempts) {
      _attempt = 0;
      onGiveUp();
      return;
    }
    final delay =
        _attempt == 0 && firstDelay != null ? firstDelay : delayFor(_attempt);
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
  /// the backoff over again from 2s. Also invalidates any attempt currently
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
