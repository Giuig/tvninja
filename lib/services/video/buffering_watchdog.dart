import 'dart:async';

import 'package:flutter/foundation.dart';

/// Decides when a buffering stream has been stuck long enough to act on.
///
/// Two different situations, split on whether a frame was ever seen.
///
/// A stream that **was** playing and stalls is worth recovering: that is a
/// live channel blipping, and the reconnect chain (2/4/8/16/30s, five
/// attempts) exists for exactly that. [onStalled] starts it.
///
/// A stream that has **never started** is not worth retrying five times.
/// Each attempt re-armed this same watchdog, so a dead stream took roughly
/// 160 seconds to reach the error screen — a spinner for most of three
/// minutes, with nothing to act on. Owner asked for a loading timeout
/// (2026-09-22); [onFirstLoadTimeout] is it. Going straight to the give-up
/// path reuses the existing error screen, which already carries a Retry
/// button and already words itself differently for this case.
///
/// A playing stream can also fail without any single long stall: the
/// live-edge sawtooth (seen on MSI App Player, 2026-10-26 and 10-29), where
/// the buffer runs dry and every 4s HLS segment plays as soon as it arrives,
/// then waits for the next one. Each brief resume used to cancel the 20s
/// timer, so that pattern ran for 40s+ before one stall happened to be long
/// enough. So [onStalled] also fires once the stream has spent
/// [stalledBudget] of the last [stallWindow] buffering. It measures stalled
/// *time*, not the number of flips, so the ms-long true/false/true blips the
/// engine reports in between don't count for anything.
class BufferingWatchdog {
  BufferingWatchdog({
    required this.hasStartedPlaying,
    required this.onFirstLoadTimeout,
    required this.onStalled,
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;

  /// Read live, not captured: a stream can start and stall again inside the
  /// window.
  final bool Function() hasStartedPlaying;
  final VoidCallback onFirstLoadTimeout;
  final VoidCallback onStalled;
  final DateTime Function() _now;

  /// How long a stream that has **never started** may buffer before it is
  /// called dead.
  ///
  /// 15s rather than something tighter on purpose: real streams are sometimes
  /// genuinely slow to start, and the cost of being wrong is a user tapping
  /// Retry on something that would have worked.
  static const Duration firstLoadTimeout = Duration(seconds: 15);

  /// How long an **established** stream may rebuffer before reconnecting.
  /// Unchanged; this is the value the watchdog always had.
  static const Duration rebufferTimeout = Duration(seconds: 20);

  /// The sliding window [stalledBudget] is measured over.
  static const Duration stallWindow = Duration(seconds: 30);

  /// Stalled time within [stallWindow] that counts as a stream which no
  /// longer recovers by itself. A normal rebuffer of a few seconds stays well
  /// under it; the sawtooth (~3.5s stalled per 4s) reaches it in about 15s.
  /// Only finished stalls count, so one long stall is still left to
  /// [rebufferTimeout] rather than cut short at 12s.
  static const Duration stalledBudget = Duration(seconds: 12);

  Timer? _timer;

  /// Finished stalls of the current stream that may still fall inside
  /// [stallWindow], as (start, end).
  final List<(DateTime, DateTime)> _stalls = [];

  /// Start of the stall in progress, if the stream is buffering right now.
  DateTime? _stallStart;

  /// Call on every buffering *change* (not on repeats of the same value).
  void bufferingChanged(bool buffering) {
    _timer?.cancel();
    _timer = null;
    final now = _now();
    if (!buffering) {
      final start = _stallStart;
      _stallStart = null;
      if (start != null) _stalls.add((start, now));
      return;
    }
    if (hasStartedPlaying()) {
      _stallStart = now;
      if (_stalledWithinWindow(now) >= stalledBudget) {
        _clearHistory();
        onStalled();
        return;
      }
    }
    final firstLoad = !hasStartedPlaying();
    _timer = Timer(firstLoad ? firstLoadTimeout : rebufferTimeout, () {
      _timer = null;
      // Re-checked rather than trusting the captured value.
      if (!hasStartedPlaying()) {
        onFirstLoadTimeout();
      } else {
        onStalled();
      }
    });
  }

  /// Stops the pending timer.
  void cancel() {
    _timer?.cancel();
    _timer = null;
  }

  /// Forgets everything about the current stream: a new load, a channel
  /// switch or a first frame starts from a clean slate.
  void reset() {
    cancel();
    _clearHistory();
  }

  void _clearHistory() {
    _stalls.clear();
    _stallStart = null;
  }

  /// Total finished-stall time inside the window ending at [now], each stall
  /// clipped to the window. Drops stalls that ended before it.
  Duration _stalledWithinWindow(DateTime now) {
    final windowStart = now.subtract(stallWindow);
    _stalls.removeWhere((s) => !s.$2.isAfter(windowStart));
    var total = Duration.zero;
    for (final (start, end) in _stalls) {
      total +=
          end.difference(start.isBefore(windowStart) ? windowStart : start);
    }
    return total;
  }
}
