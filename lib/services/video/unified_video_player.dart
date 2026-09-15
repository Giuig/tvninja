import 'dart:async';
import 'dart:io' show Platform;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'engines/exo_engine.dart';
import 'engines/mpv_engine.dart';
import 'engines/player_engine.dart';
import 'reconnect_controller.dart';
import 'stream_diagnostics.dart';
import 'web_video_player.dart';

class UnifiedVideoPlayer extends StatefulWidget {
  final String url;
  final String? userAgent;
  final String channelName;
  final String? channelLogo;
  final bool autoPlay;
  final void Function(bool isPlaying)? onPlayingChanged;
  final void Function(Duration position)? onPositionChanged;
  final void Function(String? error)? onError;
  final void Function()? onCompleted;
  final VoidCallback? onToggleFullscreen;
  final Widget? loadingWidget;
  final Widget? errorWidget;

  const UnifiedVideoPlayer({
    super.key,
    required this.url,
    this.userAgent,
    this.channelName = '',
    this.channelLogo,
    this.autoPlay = true,
    this.onPlayingChanged,
    this.onPositionChanged,
    this.onError,
    this.onCompleted,
    this.onToggleFullscreen,
    this.loadingWidget,
    this.errorWidget,
  });

  @override
  State<UnifiedVideoPlayer> createState() => UnifiedVideoPlayerState();
}

class UnifiedVideoPlayerState extends State<UnifiedVideoPlayer> {
  /// The active playback engine: `ExoEngine` (Media3-backed `video_player`)
  /// on Android, `MpvEngine` (media_kit) everywhere else non-web. `kIsWeb`
  /// never reaches this field at all — see `build()`'s early return to
  /// `WebVideoPlayerWidget`, unchanged since before Phase 3.
  PlayerEngine? _engine;
  bool _isInitialized = false;
  bool _hasError = false;
  String _errorMessage = '';
  bool _isPlaying = false;
  bool _isBuffering = false;
  bool _hasStartedPlaying = false;

  /// True from the moment a reconnect attempt is first scheduled until it
  /// either succeeds (first frame observed) or gives up after 5 attempts.
  /// Exposed via [isReconnecting] / [reconnectAttempt] the same way
  /// [isPlaying] is exposed, for a future "reconnecting (n/5)" UI — no such
  /// UI exists yet, so this phase only makes the state available.
  bool _isReconnecting = false;

  /// Engine-agnostic backoff controller (Phase 2). Nothing about its
  /// logic/API changed in Phase 3 — it still only ever calls through
  /// [_reopenCurrentUrl] / [_teardownPlayback] / [_attemptReconnect], which
  /// now delegate to whichever [PlayerEngine] is active instead of touching
  /// mpv directly.
  late final ReconnectController _reconnect;

  Timer? _bufferingWatchdog;
  bool _isSwitching = false;
  String? _pendingUrl;

  /// The M3U's `#EXTVLCOPT:http-user-agent=` value, if any — some IPTV
  /// providers (e.g. RAI's relinker) reject requests with the wrong UA. Built
  /// once here (Task 3.3) so both engines take the same map rather than each
  /// re-deriving it.
  Map<String, String>? get _httpHeaders {
    final ua = widget.userAgent;
    return (ua == null || ua.isEmpty) ? null : {'User-Agent': ua};
  }

  /// Maps a thrown error (mpv path) or an `ExoEngine.onEngineError` value
  /// (Exo path, Phase 4/REQ-016) to a user-facing message.
  ///
  /// COUPLING NOTE — read before changing any returned string here:
  /// `player_page.dart`'s `_errorIcon()` string-matches this method's
  /// *output* to choose an icon (see the matching note on that method).
  /// Every string below must stay byte-identical to what it already was, or
  /// the icon mapping silently breaks. Add new *inputs* to classify (new
  /// `contains()` checks), never reword an existing *output* string.
  static String _friendlyError(Object e) {
    if (e is TimeoutException)
      return 'Connection timed out — stream did not respond';
    final msg = e.toString().toLowerCase();

    // Media3/ExoPlayer errors are deliberately NOT string-matched here, and
    // no amount of extra `contains()` rules would help. Verified against the
    // pinned `video_player_android 2.9.5` in the pub cache:
    // `ExoPlayerEventListener.onPlayerError` reports only
    // `"Video player had error " + PlaybackException.toString()`, and for the
    // entire `TYPE_SOURCE` category — every HTTP failure — the derived
    // message is the hardcoded literal `"Source error"`. A 404, a 403 and a
    // DNS failure all arrive here as the byte-identical string
    // `"...exoplaybackexception: source error"`, which matches none of the
    // rules below and falls through to `'Stream unavailable'`.
    //
    // That is why the *specific* Android message comes from
    // [_surfaceError]'s [StreamDiagnostics] probe instead — it re-requests
    // the URL on Dart's HTTP stack and reads the status code Media3 won't
    // hand over. This method stays the synchronous best-effort classifier
    // (and remains exactly right for the mpv path, whose exceptions do carry
    // real text); the probe refines its result when it can.
    if (msg.contains('404')) return 'Stream not found (404)';
    if (msg.contains('403')) return 'Access denied (403)';
    if (msg.contains('401')) return 'Authentication required (401)';
    if (msg.contains('network') ||
        msg.contains('socket') ||
        msg.contains('connection'))
      return 'Network error — check your connection';
    if (msg.contains('codec') ||
        msg.contains('format') ||
        msg.contains('unsupported')) return 'Unsupported stream format';
    if (msg.contains('cors')) return 'Stream blocked by browser (CORS)';
    return 'Stream unavailable';
  }

  @override
  void initState() {
    super.initState();
    _reconnect = ReconnectController(
      onRetry: _attemptReconnect,
      onGiveUp: _handleReconnectGiveUp,
    );
    _initializePlayer();
  }

  @override
  void didUpdateWidget(UnifiedVideoPlayer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.url != widget.url) {
      if (_isSwitching) {
        // A switch or a reconnect attempt is already in flight and using
        // `_engine`. Both go through the same full teardown+reinit cycle
        // (Bug 5), which briefly leaves `_engine == null` / `_isInitialized
        // == false` *before* `_initializePlayer()` finishes recreating them —
        // which would otherwise make the `else` branch below fire a second,
        // concurrent `_initializePlayer()` call racing the in-flight one.
        // `_isSwitching` stays true for the whole of `_attemptReconnect()`,
        // so checking it here — before looking at `_engine`/`_isInitialized`
        // at all — queues this URL the same way `_switchToUrl` already
        // queues rapid zaps, instead of falling through to the unguarded
        // branch. `_attemptReconnect()` (and `_switchToUrl` itself) drain
        // `_pendingUrl` once they finish.
        _pendingUrl = widget.url;
        return;
      }
      if (_engine != null && _isInitialized) {
        _switchToUrl(widget.url);
      } else {
        _cleanup();
        _initializePlayer();
      }
    }
  }

  void _cleanup() {
    _bufferingWatchdog?.cancel();
    _bufferingWatchdog = null;
    _isSwitching = false;
    _pendingUrl = null;
    // Cancels any pending retry timer *and* zeroes the attempt counter — a
    // fresh engine (recreated below by the caller, or none at all if this is
    // final teardown on dispose) starts reconnect state from scratch.
    _reconnect.reset();
    _isReconnecting = false;
    unawaited(_teardownPlayback());
    _hasError = false;
    _errorMessage = '';
  }

  /// Tears down the current playback engine: disposes it (which internally
  /// cancels whatever stream subscriptions/listeners it set up) and drops
  /// the reference. Every channel switch and reconnect attempt goes through
  /// this + [_initializePlayer] to build a fresh engine from scratch — see
  /// the "Bug 5" note on [_switchToUrl] for why `PlayerEngine.switchTo()`
  /// (reusing an existing engine instance) is no longer called at all.
  ///
  /// All state resets happen synchronously (before the `await`) so a caller
  /// that doesn't await this method (e.g. `_cleanup()`, which fires it via
  /// `unawaited`) still sees `_engine`/`_isInitialized` etc. updated
  /// immediately — matching the previous synchronous `_cleanup()` behaviour.
  /// Only the actual `PlayerEngine.dispose()` work happens in the background
  /// (or is awaited, for callers that need the old engine fully gone before
  /// recreating a new one).
  Future<void> _teardownPlayback() async {
    final engineToDispose = _engine;
    _engine = null;
    _isInitialized = false;
    _isPlaying = false;
    _isBuffering = false;
    _hasStartedPlaying = false;
    await engineToDispose?.dispose();
  }

  /// Constructs the platform-appropriate engine (Task 3.2): Android routes
  /// to [ExoEngine] (PLAN.md decision 2 — no heuristic, no try/fallback),
  /// everything else non-web uses [MpvEngine]. `kIsWeb` is checked by every
  /// caller of `_initializePlayer()` before this is ever reached, so
  /// `Platform.isAndroid` is never evaluated on web — but this method
  /// re-checks `!kIsWeb` defensively anyway, since a `dart:io` `Platform`
  /// access on web is the "classic web-build break" PLAN.md warns about (a
  /// runtime `UnsupportedError`, not a compile failure — `dart:io` itself is
  /// importable on web, most of its members just throw if used).
  ///
  /// This used to carry a `_exoBlockedUrlPatterns` carve-out forcing RAI's
  /// `mediapolis.rai.it` relinker onto [MpvEngine], because ExoPlayer's HTTP
  /// stack is 403'd by that host. That's now fixed at the cause instead:
  /// `ExoEngine` pre-resolves redirect-style URLs through [StreamUrlResolver]
  /// on Dart's HTTP stack, so ExoPlayer never requests the relinker at all and
  /// no per-host exception list is needed. Routing is back to a flat
  /// platform decision with no URL inspection.
  PlayerEngine _createEngine() {
    if (!kIsWeb && Platform.isAndroid) {
      return ExoEngine(
        onPlaying: _handleEnginePlaying,
        onPosition: _handleEnginePosition,
        onBuffering: _handleEngineBuffering,
        onEngineError: _handleEngineError,
        onToggleFullscreen: widget.onToggleFullscreen,
      );
    }
    return MpvEngine(
      onPlaying: _handleEnginePlaying,
      onPosition: _handleEnginePosition,
      onBuffering: _handleEngineBuffering,
      onEngineError: _handleEngineError,
      onToggleFullscreen: widget.onToggleFullscreen,
    );
  }

  void _handleEnginePlaying(bool playing) {
    _isPlaying = playing;
    widget.onPlayingChanged?.call(playing);
  }

  void _handleEnginePosition(Duration position) {
    if (position > Duration.zero && !_hasStartedPlaying && !_isSwitching) {
      // _isSwitching guard: the old stream keeps playing while the engine's
      // open()/switchTo() is in flight — its position events must not be
      // counted as first frame of the new stream.
      _hasStartedPlaying = true;
      _bufferingWatchdog?.cancel();
      _bufferingWatchdog = null;
      // First frame after a reconnect (or a plain successful load) — stop
      // the backoff chain and clear the reconnecting flag.
      _reconnect.reset();
      _isReconnecting = false;
    }
    widget.onPositionChanged?.call(position);
  }

  void _handleEngineBuffering(bool buffering) {
    if (_isBuffering == buffering) return;
    if (mounted) {
      setState(() => _isBuffering = buffering);
    }
    if (buffering) {
      // Watchdog fires on every buffering start (initial load or mid-play reconnect)
      _bufferingWatchdog?.cancel();
      _bufferingWatchdog = Timer(const Duration(seconds: 20), () {
        if (mounted) {
          _isReconnecting = true;
          _reconnect.schedule();
        }
      });
    } else {
      _bufferingWatchdog?.cancel();
      _bufferingWatchdog = null;
    }
  }

  /// Handles [PlayerEngine.onEngineError] — an out-of-band error the engine
  /// reports outside of a thrown `open()`/`switchTo()` exception. Today only
  /// `ExoEngine` ever calls this, when `video_player`'s `value.hasError`
  /// becomes true (already deduplicated there so this fires once per new
  /// error, not every tick); `MpvEngine` never does, matching mpv's
  /// pre-Phase-3 behaviour of not subscribing to `stream.error` either.
  ///
  /// Phase 4 (REQ-016): route a *reported* error into the same reconnect
  /// chain the 20s buffering watchdogs drive, exactly like they do —
  /// `_reconnect.schedule()` is safe to call redundantly (it just re-arms
  /// the pending timer at the current attempt count rather than
  /// double-counting, see `reconnect_controller.dart`), so this can fire
  /// alongside a watchdog without racing it. This matters because an Exo
  /// stream can report `hasError` without ever re-entering `isBuffering` —
  /// without this, that failure would go unrecovered until something else
  /// (or the user) noticed.
  void _handleEngineError(Object error) {
    debugPrint('[UnifiedVideoPlayer] engine-reported error: $error');
    if (!mounted) return;
    _isReconnecting = true;
    _reconnect.schedule();
  }

  /// Bug 5 (found live-testing rapid channel zaps): a genuinely unresponsive
  /// stream reached via `PlayerEngine.switchTo()` (reusing the existing
  /// engine instance rather than rebuilding it) could leave the buffering
  /// watchdog silently disarmed with no further recovery — confirmed via
  /// extensive on-device tracing (a heartbeat timer proved the isolate/event
  /// loop stayed healthy throughout; the watchdog `Timer` itself got
  /// cancelled from somewhere in the reused-engine path within seconds of
  /// being armed, well before its 20s deadline, with no corresponding
  /// buffering callback ever observed for the stuck stream). Every
  /// `_initializePlayer()`-driven load — the first channel, a hard
  /// open()-failure error, and the (former) heavy reconnect path — has been
  /// reliable in every test this session; only the reused-engine `switchTo()`
  /// path ever showed this failure mode, and its root cause resisted
  /// conclusive tracing even with targeted instrumentation.
  ///
  /// Fix: every channel switch now tears down the engine and rebuilds it
  /// from scratch via [_teardownPlayback] + [_initializePlayer], exactly like
  /// the first load and the (former) heavy reconnect path — `switchTo()` is
  /// no longer called anywhere in this class. This loses mpv's "keep the
  /// surface mounted" trick uniformly (already true for Exo per Task 3.4b;
  /// now also true for mpv), trading a little zap smoothness for a path
  /// that's actually proven not to deadlock. ExoPlayer opens fast enough
  /// (~0.4-1.6s measured throughout this session) that this is a reasonable
  /// trade — ~2-4x the RAI/Mediaset gap this whole plan exists to close, so
  /// still a large net win even paying full-reinit cost on every zap.
  Future<void> _switchToUrl(String url) async {
    if (_isSwitching) {
      // Queue the latest request — drop intermediate ones (rapid zapping)
      _pendingUrl = url;
      return;
    }
    _isSwitching = true;
    _pendingUrl = null;

    // A fresh, user-initiated channel switch supersedes any reconnect that
    // was in flight for the *previous* channel.
    _reconnect.reset();
    _isReconnecting = false;

    _bufferingWatchdog?.cancel();
    _bufferingWatchdog = null;

    if (mounted) setState(() { _isBuffering = true; _hasError = false; });

    try {
      // isReconnectAttempt: true so a failure rethrows here instead of
      // _initializePlayer showing the error screen directly — a
      // user-initiated switch gets the same reconnect/backoff chance a
      // background reconnect does before giving up.
      await _teardownPlayback();
      await _initializePlayer(isReconnectAttempt: true);
    } catch (e) {
      _isSwitching = false;
      _isReconnecting = true;
      _reconnect.schedule();
      // If the user zapped again while this open() was failing, let that
      // queued switch preempt the reconnect we just scheduled rather than
      // racing it.
      if (_pendingUrl != null && mounted && widget.url == _pendingUrl) {
        final next = _pendingUrl!;
        _pendingUrl = null;
        _reconnect.reset();
        _isReconnecting = false;
        _switchToUrl(next);
      }
      return;
    }

    _isSwitching = false;

    // If the user zapped again while we were opening, process that switch now
    if (_pendingUrl != null && mounted && widget.url == _pendingUrl) {
      final next = _pendingUrl!;
      _pendingUrl = null;
      _switchToUrl(next);
    }
  }

  /// The reconnect controller's `onRetry` callback. Always does a full
  /// teardown + recreate (Bug 5, see [_switchToUrl]'s doc comment) — there is
  /// no lighter "reuse the engine" attempt any more, for any attempt number.
  ///
  /// Sets `_isSwitching` for the duration of the attempt so a channel zap
  /// that arrives mid-reconnect gets queued into `_pendingUrl` (the same
  /// rapid-zap guard `_switchToUrl` uses) instead of racing this method's
  /// use of `_engine`. Any queued URL is processed once this attempt
  /// finishes, preempting the reconnect chain rather than letting it race a
  /// user-chosen channel.
  Future<void> _attemptReconnect() async {
    if (!mounted) return;
    // A stale first-frame flag would prevent the position listener from ever
    // detecting the reconnected stream's first frame again, which is what
    // calls _reconnect.reset() on success.
    _hasStartedPlaying = false;
    _isSwitching = true;
    try {
      await _teardownPlayback();
      await _initializePlayer(isReconnectAttempt: true);
    } catch (_) {
      // Swallow here too (in addition to the controller's own catch): this
      // is a reconnect attempt, not the initial load, so no widget.onError
      // call is appropriate — only onGiveUp surfaces an error to the UI.
      // The controller's chain (schedule() called again after onRetry
      // returns) picks up the next attempt automatically.
    } finally {
      _isSwitching = false;
    }

    if (_pendingUrl != null && mounted) {
      final next = _pendingUrl!;
      _pendingUrl = null;
      _reconnect.reset();
      _isReconnecting = false;
      unawaited(_switchToUrl(next));
    }
  }

  /// Shows a failure to the user, upgrading [fallback] to a specific,
  /// status-aware message when [StreamDiagnostics] can determine one.
  ///
  /// Needed because the Android engine cannot tell us *why* a load failed
  /// (see [_friendlyError]) — without this, every HTTP failure on Android
  /// reads as a generic message, a regression against the mpv path which
  /// always surfaced 404/403/network specifically.
  ///
  /// Every returned string is byte-identical to one [_friendlyError] already
  /// produces. That is mandatory, not stylistic: `player_page.dart`'s
  /// `_errorIcon()` string-matches these exact strings to pick an icon — see
  /// the COUPLING NOTE on [_friendlyError].
  ///
  /// A probe result of `ok` keeps [fallback] rather than claiming success:
  /// the two HTTP stacks genuinely disagree sometimes (RAI's relinker 403'd
  /// ExoPlayer while answering 200 to Dart in the same second), and "the
  /// server is fine" is not a reason to tell the user nothing went wrong.
  Future<void> _surfaceError(String fallback) async {
    final probe = await StreamDiagnostics.probe(widget.url, _httpHeaders);
    final msg = switch (probe) {
      StreamProbeResult.notFound => 'Stream not found (404)',
      StreamProbeResult.forbidden => 'Access denied (403)',
      StreamProbeResult.unauthorized => 'Authentication required (401)',
      StreamProbeResult.networkError => 'Network error — check your connection',
      StreamProbeResult.serverError ||
      StreamProbeResult.ok ||
      StreamProbeResult.unknown =>
        fallback,
    };
    if (!mounted) return;
    setState(() {
      _hasError = true;
      _errorMessage = msg;
    });
    widget.onError?.call(msg);
  }

  void _handleReconnectGiveUp() {
    _isReconnecting = false;
    if (!mounted) return;
    unawaited(_surfaceError(_hasStartedPlaying
        ? 'Stream lost — connection timed out'
        : 'Stream not responding — no data received'));
  }

  Future<void> _initializePlayer({bool isReconnectAttempt = false}) async {
    if (kIsWeb) {
      return;
    }

    try {
      _engine = _createEngine();
      await _engine!
          .open(widget.url, _httpHeaders, autoPlay: widget.autoPlay)
          .timeout(const Duration(seconds: 10));

      if (mounted) {
        setState(() {
          _isInitialized = true;
        });
      }
    } catch (e) {
      if (isReconnectAttempt) {
        // Don't surface an error mid auto-reconnect and don't set _hasError
        // (that would flash the error screen during an otherwise-invisible
        // retry) — rethrow so the reconnect controller's chain continues;
        // only onGiveUp (after 5 attempts) reaches widget.onError.
        rethrow;
      }
      // _friendlyError() is the synchronous best guess; _surfaceError()
      // upgrades it to a status-aware message when a probe can tell us more
      // (the Android engine can't — see _friendlyError's comment).
      await _surfaceError(_friendlyError(e));
    }
  }

  @override
  void dispose() {
    _cleanup();
    super.dispose();
  }

  Future<void> play() async {
    if (kIsWeb) {
      widget.onPlayingChanged?.call(true);
    } else {
      await _engine?.play();
    }
  }

  Future<void> pause() async {
    if (kIsWeb) {
      widget.onPlayingChanged?.call(false);
    } else {
      await _engine?.pause();
    }
  }

  Future<void> stop() async {
    if (!kIsWeb) {
      await _engine?.stop();
    }
  }

  Future<void> seek(Duration position) async {
    if (!kIsWeb) {
      await _engine?.seek(position);
    }
  }

  Future<void> setVolume(double volume) async {
    if (!kIsWeb) {
      await _engine?.setVolume(volume);
    }
  }

  /// Restarts playback of the current URL from scratch. Unlike the automatic
  /// reconnect path, this always does a full teardown + recreate rather than
  /// trying the lighter reopen first — by the time a user reaches for the
  /// manual Retry button, either auto-reconnect has already exhausted its 5
  /// attempts (which already tried the light path), or something else asked
  /// for an explicit hard reset, so there's no value in retrying the cheap
  /// path again first.
  Future<void> retry() async {
    if (kIsWeb) return;
    _reconnect.reset();
    _isReconnecting = false;
    if (mounted) {
      setState(() {
        _hasError = false;
        _errorMessage = '';
      });
    }
    await _teardownPlayback();
    await _initializePlayer();
  }

  bool get isPlaying => _isPlaying;
  bool get isReconnecting => _isReconnecting;
  int get reconnectAttempt => _reconnect.attempt;
  Duration get position => _engine?.position ?? Duration.zero;

  @override
  Widget build(BuildContext context) {
    if (kIsWeb) {
      return Stack(
        children: [
          WebVideoPlayerWidget(
            url: widget.url,
            channelName: widget.channelName,
            channelLogo: widget.channelLogo,
            autoPlay: widget.autoPlay,
            onPlayingChanged: widget.onPlayingChanged,
            onPositionChanged: widget.onPositionChanged,
            onError: widget.onError,
            onCompleted: widget.onCompleted,
          ),
          if (widget.loadingWidget != null) widget.loadingWidget!,
        ],
      );
    }

    if (_hasError) {
      return widget.errorWidget ?? _buildDefaultError();
    }

    if (!_isInitialized) {
      return widget.loadingWidget ?? _buildDefaultLoading();
    }

    return Stack(
      children: [
        _engine!.buildSurface(context),
        if (_isBuffering && widget.loadingWidget != null) widget.loadingWidget!,
      ],
    );
  }

  Widget _buildDefaultLoading() {
    return Container(
      color: Colors.black,
      child: const Center(
        child: CircularProgressIndicator(color: Colors.white),
      ),
    );
  }

  Widget _buildDefaultError() {
    return Container(
      color: Colors.black,
      child: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.error_outline, size: 48, color: Colors.red),
            const SizedBox(height: 16),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Text(
                _errorMessage,
                style: const TextStyle(color: Colors.white70, fontSize: 12),
                textAlign: TextAlign.center,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
