import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:tvninja/services/video/buffering_watchdog.dart';
import 'package:tvninja/services/video/reconnect_controller.dart';

/// What the service does when mpv reports that the current media has ended
/// (`completed`).
enum StreamEndAction {
  /// A finished file: start it again, as it always did.
  replay,

  /// A live stream that ended is a dropped connection: reconnect directly.
  reconnect,

  /// A live stream ended while nobody wants it reconnected (stopped, given up,
  /// a failed start): leave it alone.
  ignore,
}

/// Whether a media with this [duration] is a live stream.
///
/// mpv publishes a `duration` only when the demuxer knows one. A live HLS
/// playlist (no end marker) and a progressive radio stream have none, so
/// media_kit leaves `state.duration` at zero, while a file or a finished
/// playlist reports its length. media_kit exposes no `seekable` flag, but the
/// same streams answer a seek with "Cannot seek in this stream" (measured on
/// both an HLS channel and an Icecast station), which is the other face of the
/// same fact. A duration that is wrongly non-zero for a live stream only
/// sends it down the replay road, which is how every stream ended before this
/// check existed.
bool isLiveDuration(Duration duration) => duration <= Duration.zero;

/// Decides what a `completed` event means.
///
/// Replaying a live stream is the wrong answer: `Player.play()` on a completed
/// player seeks to the start first, a live stream refuses that seek, and the
/// refusal (two error events with mpv's own wording) was what used to start the
/// reconnect by accident.
StreamEndAction streamEndAction({
  required Duration duration,
  required bool mayReconnect,
}) {
  if (!isLiveDuration(duration)) return StreamEndAction.replay;
  return mayReconnect ? StreamEndAction.reconnect : StreamEndAction.ignore;
}

/// What the service does with a stream error event.
enum StreamErrorAction {
  /// Nothing: reconnecting is not wanted, or another event of the same
  /// failure is already being looked into.
  ignore,

  /// Start the reconnect chain (a no-op while one is running).
  reconnect,

  /// Ask the server why first (`StreamDiagnostics.probe`); a permanent answer
  /// ends the session with its message, anything else reconnects.
  probe,
}

/// Failed reconnect attempts in a row after which a stream that used to play
/// is probed for a permanent failure (404, 403, 401).
const int probeAfterFailedAttempts = 2;

/// Decides what to do with a stream error.
///
/// The probe used to sit in front of every first reconnect, so a plain drop
/// waited up to four seconds before its two-second backoff even started. A
/// drop is the likely case; a stream that has been removed is the rare one and
/// shows itself by failing again. So:
///
/// * a stream that never produced audio since `NativeAudioService.play` (a dead
///   URL at the first open) is probed at once, as before;
/// * a stream that did play reconnects immediately and is probed only once
///   [probeAfterFailedAttempts] attempts have failed in a row;
/// * while a probe for this stream is running, further error events (mpv
///   reports one failure as several lines) do nothing.
StreamErrorAction streamErrorAction({
  required bool mayReconnect,
  required bool hasPlayed,
  required int failedAttempts,
  required bool probeInFlight,
}) {
  if (!mayReconnect || probeInFlight) return StreamErrorAction.ignore;
  if (!hasPlayed || failedAttempts >= probeAfterFailedAttempts) {
    return StreamErrorAction.probe;
  }
  return StreamErrorAction.reconnect;
}

/// How long a drop that has used up its reconnect budget keeps waiting for the
/// network to come back before the session really gives up.
const Duration defaultOfflineBudget = Duration(minutes: 30);

/// How often the offline wait asks whether the network is back.
const Duration defaultOfflinePollInterval = Duration(seconds: 30);

/// What to do once the reconnect budget is spent (or, while already waiting,
/// at each poll).
enum OfflineAction {
  /// Surface the usual "Stream lost" error.
  giveUp,

  /// The network is down: stay in "Reconnecting" and ask again later.
  wait,

  /// The network is back: reconnect now with a full budget.
  retry,
}

/// Decides between giving up, waiting and retrying.
///
/// [reachable] is the answer of the reachability lookup, [waiting] whether the
/// offline wait is already running (a poll) rather than being entered (the
/// budget just ran out), and [waited] how long this outage has lasted so far
/// (zero before the first check; kept across a retry that fails again, so a
/// flapping network does not restart the bound).
///
/// * reachable while the budget is spent: the stream itself is the problem and
///   waiting will not fix it: give up. This is also the answer when the
///   lookup cannot tell (see `hostResolves`), i.e. exactly today's behaviour.
/// * reachable during the wait: the network is back, retry at once.
/// * unreachable: wait, until [budget] is used up.
OfflineAction offlineAction({
  required bool reachable,
  required bool waiting,
  required Duration waited,
  Duration budget = defaultOfflineBudget,
}) {
  if (reachable) {
    return waiting ? OfflineAction.retry : OfflineAction.giveUp;
  }
  return waited >= budget ? OfflineAction.giveUp : OfflineAction.wait;
}

/// Turns mpv's raw playing / buffering / position signals into two decisions:
/// "the stream is making progress" and "the stream has stalled".
///
/// Why position and not just `buffering`: the background audio player runs
/// with `cache-pause=no`, so mpv never pauses for a low cache and the
/// `paused-for-cache` flag that would announce a stall stays false. What a
/// dead live stream does show is a playing, non-idle core whose position stops
/// moving. Position that changes while the core is playing and not idle is
/// also the one signal that means audio is really coming out, which is what
/// "the reconnect worked" has to mean.
///
/// Pure: no mpv, no platform channel. Time comes from [Timer], so tests drive
/// it with `fakeAsync`.
class PlaybackProgressMonitor {
  PlaybackProgressMonitor({
    required this.onProgress,
    required this.onStallChanged,
    this.stallAfter = const Duration(seconds: 4),
  });

  /// Fires once each time playback goes from not-progressing to progressing
  /// (the first position change after a load, after a stall, after a pause).
  /// An edge, not a heartbeat: position events arrive many times a second.
  final VoidCallback onProgress;

  /// Fires when the stream starts or stops being stalled.
  final ValueChanged<bool> onStallChanged;

  /// How long a playing, non-idle stream may go without its position moving
  /// before it counts as stalled. Well above the gap between position events
  /// of a healthy stream, well below the watchdog's own 20 s.
  final Duration stallAfter;

  bool _playing = false;
  bool _buffering = false;
  bool _stalled = false;
  bool _progressing = false;
  Duration? _lastPosition;
  Timer? _timer;

  bool get isStalled => _stalled;

  void playingChanged(bool playing) {
    _playing = playing;
    _evaluate(moved: false);
  }

  void bufferingChanged(bool buffering) {
    _buffering = buffering;
    _evaluate(moved: false);
  }

  void positionChanged(Duration position) {
    // Zero is what mpv reports the instant a stream is (re)opened, before any
    // audio has played; real progress reads a few hundred ms or more. Counting
    // it would announce a recovery that has not happened.
    final moved = position != _lastPosition && position != Duration.zero;
    _lastPosition = position;
    _evaluate(moved: moved);
  }

  void _evaluate({required bool moved}) {
    final active = _playing && !_buffering;
    if (!active) {
      _timer?.cancel();
      _timer = null;
      _progressing = false;
      _setStalled(false);
      return;
    }
    if (moved) {
      _setStalled(false);
      if (!_progressing) {
        _progressing = true;
        onProgress();
      }
      _arm();
    } else if (_timer == null && !_stalled) {
      // Just became active: give the position a chance to move.
      _arm();
    }
  }

  void _arm() {
    _timer?.cancel();
    _timer = Timer(stallAfter, () {
      _timer = null;
      _progressing = false;
      _setStalled(true);
    });
  }

  void _setStalled(bool stalled) {
    if (_stalled == stalled) return;
    _stalled = stalled;
    onStallChanged(stalled);
  }

  /// Forgets the stream: a new player has none of the old one's state. Fires
  /// no callbacks.
  void reset() {
    _timer?.cancel();
    _timer = null;
    _playing = false;
    _buffering = false;
    _stalled = false;
    _progressing = false;
    _lastPosition = null;
  }
}

/// Sound-mode recovery from a dropped or stalled live stream: the video
/// path's [ReconnectController] (2/4/8/16/30 s, five tries, budget back to
/// full once a retry works) and [BufferingWatchdog], fed from the signals
/// mpv really sends in the audio-only player.
///
/// The service forwards raw player events in and supplies [reopen]; every
/// decision about *when* lives here so it can be tested without mpv.
class AudioRecovery {
  AudioRecovery({
    required this.reopen,
    required this.onGiveUp,
    this.canRecover,
    this.onStalled,
    this.onRecovered,
    this.isReachable,
    this.onOffline,
    this.onNetworkBack,
    this.attemptTimeout = const Duration(seconds: 15),
    this.reachabilityTimeout = const Duration(seconds: 4),
    this.offlinePollInterval = defaultOfflinePollInterval,
    this.offlineBudget = defaultOfflineBudget,
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now {
    _controller = ReconnectController(onRetry: _retry, onGiveUp: _giveUp);
    _watchdog = BufferingWatchdog(
      // Always "started": for sound mode a stream that never produced audio
      // goes through the same retry chain as one that dropped, which is what
      // it did before the watchdog was wired in. The first-load shortcut
      // (give up after 15 s) is a video-player decision, not taken here.
      hasStartedPlaying: () => true,
      onFirstLoadTimeout: () {},
      onStalled: _watchdogStalled,
      now: _now,
    );
    _monitor = PlaybackProgressMonitor(
      onProgress: _progress,
      onStallChanged: (stalled) {
        _stalled = stalled;
        _feedWatchdog();
      },
    );
  }

  /// Reopens the current stream. Returns once the open call has returned,
  /// which for mpv is long before audio flows; whether it worked is learned
  /// from progress (see [_progress]) or from [attemptFailed].
  final Future<void> Function() reopen;

  /// Called once, after the fifth attempt in a row failed.
  final VoidCallback onGiveUp;

  /// Asked before a stall starts a recovery; `false` (no session wanted any
  /// more, already given up) leaves the stall alone. Defaults to always.
  final bool Function()? canRecover;

  /// Called when a stall starts a recovery the stream error path did not.
  final VoidCallback? onStalled;

  /// Called when playback is flowing again after at least one reconnect.
  final VoidCallback? onRecovered;

  /// Whether the network is usable right now (a DNS lookup of the stream's
  /// host, see `hostResolves`). Asked when the reconnect budget runs out: if
  /// it says no, the chain keeps waiting instead of giving up. `null` (the
  /// default) means the session gives up as soon as the budget is spent. A
  /// lookup that throws counts as "can't tell" (true); one that does not
  /// answer within [reachabilityTimeout] counts as "no".
  final Future<bool> Function()? isReachable;

  /// Called once when the budget ran out and the network is down, so the
  /// chain starts waiting.
  final VoidCallback? onOffline;

  /// Called when the wait ends because the network is back (just before the
  /// immediate reconnect).
  final VoidCallback? onNetworkBack;

  /// How long one reachability check may take.
  final Duration reachabilityTimeout;

  /// How often to ask again while waiting for the network.
  final Duration offlinePollInterval;

  /// Total time one outage may be waited out before the usual give-up.
  final Duration offlineBudget;

  final DateTime Function() _now;

  /// How long an attempt is given to fail or succeed before the chain moves
  /// on. mpv reports a failed open after its own network timeout (5 s, a few
  /// reads), so this only matters if it reports nothing at all.
  final Duration attemptTimeout;

  late final ReconnectController _controller;
  late final BufferingWatchdog _watchdog;
  late final PlaybackProgressMonitor _monitor;

  bool _chainActive = false;
  bool _hasProgressed = false;
  int _epoch = 0;
  bool _realBuffering = false;
  bool _stalled = false;
  bool _fedBuffering = false;
  Completer<void>? _outcome;

  /// Pending poll of the offline wait.
  Timer? _offlineTimer;

  /// When this outage was first found to be offline; null when there is none.
  /// Survives a retry that fails again; cleared by progress, [reset] and the
  /// final give-up.
  DateTime? _offlineSince;

  /// The chain is waiting for the network (budget spent, lookup failing).
  bool get isWaitingForNetwork => _offlineTimer != null;

  /// Reconnect attempts fired since the last recovery or [reset].
  int get attempt => _controller.attempt;

  /// A reconnect chain is pending or running.
  bool get isRecovering => _chainActive;

  /// Audio has flowed since the last [reset]: the stream has worked at least
  /// once, so a failure now is a drop and not a dead URL.
  bool get hasProgressed => _hasProgressed;

  /// Changes whenever playback is seen flowing and on every [reset]. A caller
  /// that awaits something (a probe) captures it first and drops the result if
  /// it changed: the stream it described has recovered or been replaced.
  int get epoch => _epoch;

  void playingChanged(bool playing) => _monitor.playingChanged(playing);

  void bufferingChanged(bool buffering) {
    _realBuffering = buffering;
    _monitor.bufferingChanged(buffering);
    _feedWatchdog();
  }

  void positionChanged(Duration position) => _monitor.positionChanged(position);

  /// The stream reported a failure. Ends the attempt in flight, if any, so
  /// the chain moves to its next backoff without waiting out
  /// [attemptTimeout].
  void attemptFailed() => _finishAttempt();

  /// Starts the chain if none is running. A failure that arrives while a
  /// chain is already running must not push its pending retry back.
  void schedule() {
    if (_chainActive) return;
    _chainActive = true;
    _controller.schedule();
  }

  /// A new load, a stop or a dispose: forget everything, cancel anything
  /// pending.
  void reset() {
    _chainActive = false;
    _hasProgressed = false;
    _epoch++;
    _clearOffline();
    _controller.reset();
    _watchdog.reset();
    _monitor.reset();
    _realBuffering = false;
    _stalled = false;
    _fedBuffering = false;
    _finishAttempt();
  }

  Future<void> _retry() async {
    final outcome = _outcome = Completer<void>();
    try {
      await reopen();
      if (!outcome.isCompleted) {
        await outcome.future.timeout(attemptTimeout, onTimeout: () {});
      }
    } finally {
      if (identical(_outcome, outcome)) _outcome = null;
    }
  }

  void _finishAttempt() {
    final outcome = _outcome;
    if (outcome != null && !outcome.isCompleted) outcome.complete();
  }

  void _progress() {
    final recovered = _chainActive;
    _chainActive = false;
    _hasProgressed = true;
    _epoch++;
    _clearOffline();
    // Bumps the controller's generation too, so an attempt still awaiting its
    // outcome does not schedule the next one.
    _controller.reset();
    _finishAttempt();
    if (recovered) {
      // The stall that started the chain is history, not evidence against the
      // stream that just came back.
      _watchdog.reset();
      _fedBuffering = false;
      onRecovered?.call();
    }
  }

  /// The controller spent its five attempts. Before surfacing the error, ask
  /// whether the network is even there: an outage longer than the ~2 minutes
  /// the backoff covers is not the stream's fault, and giving up would leave
  /// the user on an error screen for a stream that would work the moment the
  /// connection returns. [_chainActive] stays true while waiting, so every
  /// other trigger (stream errors, `completed`, the stall watchdog) stays a
  /// no-op, exactly as during a normal chain.
  void _giveUp() {
    _watchdog.cancel();
    _finishAttempt();
    if (isReachable == null) {
      _finalGiveUp();
      return;
    }
    unawaited(_checkNetwork(waiting: false));
  }

  void _finalGiveUp() {
    _chainActive = false;
    _clearOffline();
    _watchdog.cancel();
    _finishAttempt();
    onGiveUp();
  }

  Future<bool> _lookup() async {
    try {
      return await isReachable!().timeout(reachabilityTimeout);
    } on TimeoutException {
      return false;
    } catch (_) {
      return true;
    }
  }

  /// One reachability check, either right after the budget ran out
  /// ([waiting] false) or from a poll of the wait ([waiting] true).
  ///
  /// Awaits a lookup, so it carries the same guard as every other await in the
  /// service: [_epoch] moves on [reset] (a stop, a new play, a give-up) and on
  /// progress, and a result that finds it changed describes a session that is
  /// gone. [canRecover] is asked again as well.
  Future<void> _checkNetwork({required bool waiting}) async {
    final epoch = _epoch;
    final reachable = await _lookup();
    if (epoch != _epoch) return;
    if (canRecover != null && !canRecover!()) {
      _chainActive = false;
      _clearOffline();
      return;
    }
    final since = _offlineSince;
    final waited = since == null ? Duration.zero : _now().difference(since);
    switch (offlineAction(
      reachable: reachable,
      waiting: waiting,
      waited: waited,
      budget: offlineBudget,
    )) {
      case OfflineAction.giveUp:
        _finalGiveUp();
      case OfflineAction.wait:
        if (since == null) {
          _offlineSince = _now();
          onOffline?.call();
        }
        _offlineTimer = Timer(offlinePollInterval, () {
          _offlineTimer = null;
          unawaited(_checkNetwork(waiting: true));
        });
      case OfflineAction.retry:
        onNetworkBack?.call();
        // A full budget for the reconnect that follows, and the first attempt
        // now rather than after the 2 s backoff.
        _controller.reset();
        _controller.retryNow();
    }
  }

  void _clearOffline() {
    _offlineTimer?.cancel();
    _offlineTimer = null;
    _offlineSince = null;
  }

  void _watchdogStalled() {
    if (_chainActive) return;
    if (canRecover != null && !canRecover!()) return;
    onStalled?.call();
    schedule();
  }

  void _feedWatchdog() {
    final buffering = _realBuffering || _stalled;
    if (buffering == _fedBuffering) return;
    _fedBuffering = buffering;
    _watchdog.bufferingChanged(buffering);
  }
}
