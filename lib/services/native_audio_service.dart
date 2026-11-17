import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';
import 'package:tvninja/services/audio_recovery.dart';
import 'package:tvninja/services/mpv_options.dart';
import 'package:tvninja/services/network_reachability.dart';
import 'package:tvninja/services/video/stream_diagnostics.dart';
import 'package:tvninja/services/video/stream_format_hint.dart';
import 'package:tvninja/services/video/stream_url_resolver.dart';

class _CancellationException implements Exception {}

class NativeAudioService {
  static const MethodChannel _channel =
      MethodChannel('io.github.giuig.tvninja/audio');
  static const EventChannel _eventChannel =
      EventChannel('io.github.giuig.tvninja/audio_events');

  static StreamSubscription<dynamic>? _eventSubscription;
  static StreamSubscription<bool>? _playerBufferingSubscription;
  static StreamSubscription<bool>? _playerPlayingSubscription;
  static StreamSubscription<bool>? _playerCompletedSubscription;
  static StreamSubscription<Duration>? _playerPositionSubscription;
  static final _playbackStateController =
      StreamController<PlaybackState>.broadcast();
  static final _metadataController =
      StreamController<TrackMetadata>.broadcast();
  static final _controlController =
      StreamController<PlaybackControl>.broadcast();
  static final _bufferingController = StreamController<bool>.broadcast();
  static final _errorController = StreamController<String>.broadcast();

  static Stream<PlaybackState> get playbackStateStream =>
      _playbackStateController.stream;
  static Stream<TrackMetadata> get metadataStream => _metadataController.stream;
  static Stream<PlaybackControl> get controlStream => _controlController.stream;
  static Stream<bool> get bufferingStream => _bufferingController.stream;

  /// A playback failure the user should see, worded like the video path's
  /// (see [StreamDiagnostics.userMessage]). Emitted once per failure, when
  /// the service has stopped trying — never for a drop it is still
  /// reconnecting from.
  static Stream<String> get errorStream => _errorController.stream;

  /// The last message sent on [errorStream], cleared by every [play].
  ///
  /// Exists because the page only listens while its audio mode is active, and
  /// that flag is set *after* [play] returns — so a failure can land before
  /// anyone is listening for it. The page re-reads this after [play], the same
  /// way it re-reads [isBuffering].
  static String? get lastError => _lastError;
  static String? _lastError;

  static bool _isInitialized = false;
  static bool _isBackgroundMode = false;
  static PlaybackState _currentState = PlaybackState();
  static bool _isBuffering = false;

  /// The channel's own URL — the session's **identity**, not what mpv was
  /// handed. [play]'s same-URL guard, [currentUrl]'s readers (the home page
  /// and channel list, deciding whether a leftover session needs [stop]) and
  /// the reachability check all compare against a channel, so this must stay
  /// the channel URL even when sound mode pins something narrower.
  static String? _currentUrl;

  /// What mpv was actually told to open: the pinned audio rendition or
  /// lowest-bandwidth variant where there was one to pick, otherwise the same
  /// thing as [_masterUrl]. The reconnect chain reopens *this*.
  static String? _openedUrl;

  /// The resolved master playlist, kept as the fallback for when a pinned URI
  /// turns out to be unusable (a stale CDN token, a variant that 404s, a
  /// relinker whose redirect target moved between the probe and now).
  ///
  /// Null when nothing was pinned, i.e. when [_openedUrl] is already this.
  static String? _masterUrl;

  /// The session's sound-mode pin, **relative and unjoined**, as the master
  /// playlist wrote it — or null when this channel is not pinned, or when a
  /// pin has been abandoned by [_abandonPin].
  ///
  /// Kept rather than only its joined result because [_refreshOpenUrl] rebuilds
  /// the absolute URL before every open, the first and each reconnect alike.
  static String? _soundModeUri;

  /// Bounds the master resolution [_refreshOpenUrl] may need. The pin is an
  /// optimisation, so it must never hold up an open or a reconnect for long;
  /// overrunning this just means the channel plays unpinned.
  static const Duration _pinResolveBudget = Duration(seconds: 2);

  @visibleForTesting
  static String? get debugOpenedUrl => _openedUrl;

  @visibleForTesting
  static String? get debugMasterUrl => _masterUrl;

  @visibleForTesting
  static String? get debugSoundModeUri => _soundModeUri;

  /// Runs the pin rebuild on its own, so a test can prove that a second call
  /// re-resolves the master instead of reusing the URL built by the first.
  @visibleForTesting
  static Future<void> resolveOpenUrlForTest() => _refreshOpenUrl();

  /// Runs one reconnect attempt, the way the recovery chain does.
  @visibleForTesting
  static Future<void> reopenForTest() => _reopenCurrentUrl();
  static StreamSubscription<String>? _errorSubscription;
  static int _playRequestId = 0;
  static Completer<void>? _playCanceller;

  /// True from the moment [startForegroundEarly] asks for the foreground
  /// service until a [stop], a refusal or a failed [play] ends it. While it is
  /// set, [play] does not start the service a second time after opening the
  /// stream. Set before the native call returns, so a [stop] that arrives in
  /// between still knows there is a service to stop.
  static bool _foregroundStartedEarly = false;

  /// Bumped by everything that ends or supersedes an early foreground start
  /// ([stop], a refusal, a failed [play]), so a [startForegroundEarly] that was
  /// awaiting the native side can tell its result is no longer wanted.
  static int _foregroundEpoch = 0;

  static final _foregroundRefusedController =
      StreamController<void>.broadcast();

  /// Emits each time the system refuses a foreground start. That is reported
  /// by the service after the start call has already returned, so it is how a
  /// caller learns that a [startForegroundEarly] that returned `true` did not
  /// last: the early-start state is already cleared when it fires, and the
  /// caller must abort whatever it was doing on the strength of that `true`.
  ///
  /// A listener that attaches late misses the event: compare
  /// [foregroundRefusalCount] taken before the start with its value now.
  static Stream<void> get foregroundRefused =>
      _foregroundRefusedController.stream;

  /// How many refusals [foregroundRefused] has reported since the app started.
  /// Safe to read at any time, unlike the stream.
  static int get foregroundRefusalCount => _foregroundRefusalCount;
  static int _foregroundRefusalCount = 0;

  /// Debug builds only: delays the early foreground start (milliseconds), to
  /// see how late it can be before the system objects.
  static const int _debugForegroundDelayMs =
      int.fromEnvironment('TVNINJA_DEBUG_LOCK_FGS_DELAY_MS');

  /// Debug builds only: makes a [play] that follows an early foreground start
  /// fail, to exercise the path that has to stop that service again.
  static const bool _debugFailAudio =
      bool.fromEnvironment('TVNINJA_DEBUG_LOCK_FAIL_AUDIO');

  /// Set by [_surfaceError], cleared by [play]: the current stream failed and
  /// the service stopped trying.
  ///
  /// A flag rather than clearing [_currentUrl], which is what this first did.
  /// The home page and channel list read [currentUrl] to decide whether a
  /// leftover audio session needs [stop] before opening another channel, so a
  /// null URL there leaked the foreground service and its notification.
  static bool _gaveUp = false;

  /// True from the moment [play] adopts a URL until [play] fails, [stop] or
  /// [dispose] runs. A [play] that returned `false` has told its caller there
  /// is no audio session (the page falls back to video), yet [_currentUrl]
  /// stays set and the mpv player may still be alive and later report an error;
  /// without this flag that error would probe and reconnect, starting audio
  /// over the video.
  static bool _sessionWanted = false;

  /// Whether a failure or stall of the current stream may start reconnecting.
  static bool get _mayReconnect =>
      _sessionWanted && !_gaveUp && _currentUrl != null;

  /// Reconnect chain (2/4/8/16/30 s, five tries), stall detection and the
  /// decision that a reconnect worked, shared with the video player's pieces.
  /// A static is fine: the service is a process-wide singleton.
  static final AudioRecovery _recovery = AudioRecovery(
    reopen: _reopenCurrentUrl,
    onGiveUp: () =>
        // Same wording the video path uses when its reconnects give up.
        _surfaceError('Stream lost — connection timed out'),
    canRecover: () => _mayReconnect,
    onStalled: () {
      debugPrint('[Audio] Stalled: position stopped moving, reconnecting');
      _reflectDisconnected();
    },
    onRecovered: () => debugPrint('[Audio] Playback recovered'),
    onEarlyProgress: () => debugPrint(
        '[Audio] Position moved while a reconnect is pending: not a recovery '
        'until it is sustained'),
    // When the five attempts are spent, a stream whose host no longer resolves
    // is an outage, not a dead stream: keep "Reconnecting" and poll every 30 s
    // (for up to 30 min) instead of showing the error. Only for a stream that
    // has played this session; one that never worked still ends in the error.
    // See [hostResolves] for what the lookup does and does not prove.
    isReachable: () => hostResolves(_currentUrl ?? ''),
    onOffline: () {
      debugPrint('[Audio] Reconnects used up and no network, waiting');
      // Show "Reconnecting" for the wait: the last failed attempt may have left
      // the UI on ready / not playing.
      _reflectDisconnected();
    },
    onNetworkBack: () =>
        debugPrint('[Audio] Network is back, reconnecting now'),
  );

  /// Whether the current stream had a duration while it played; see
  /// [StreamLengthEvidence]. Reset on every open.
  static final StreamLengthEvidence _lengthEvidence = StreamLengthEvidence();

  /// Builds the mpv [Player] behind the background audio.
  ///
  /// A field only so a widget test can run the real `PlayerPage` in sound
  /// mode on a host without libmpv (a real [Player] cannot be constructed
  /// there); the app always uses the default.
  @visibleForTesting
  static Player Function() playerFactory = Player.new;

  static late Player _audioPlayer;

  static PlaybackState get currentState => _currentState;
  static bool get isBuffering => _isBuffering;
  static String? get currentUrl => _currentUrl;

  static Future<void> initialize() async {
    if (_isInitialized) return;
    _isInitialized = true;

    _audioPlayer = playerFactory();
    await applyLiveStreamMpvOptions(_audioPlayer, soundOnly: true);

    _listenToNativeEvents();

    await _setupPlayerListeners();
  }

  /// Starts listening to the native side's events (notification buttons, a
  /// refused foreground start). Idempotent: [stop] leaves the subscription in
  /// place, and listening again would only leak the old one.
  ///
  /// Also called by [startForegroundEarly], which runs before [initialize]:
  /// the native side drops events while nobody listens, and a refusal of that
  /// very start would otherwise be lost.
  static void _listenToNativeEvents() {
    if (_eventSubscription != null) return;
    _eventSubscription = _eventChannel.receiveBroadcastStream().listen(
      (dynamic event) {
        if (event is Map) {
          _handleNativeEvent(Map<String, dynamic>.from(event));
        }
      },
      onError: (dynamic error) {
        // Handle error
      },
    );
  }

  static Future<void> _setupPlayerListeners() async {
    // Cancel existing subscriptions
    await _playerPlayingSubscription?.cancel();
    await _playerBufferingSubscription?.cancel();
    await _playerCompletedSubscription?.cancel();
    await _playerPositionSubscription?.cancel();
    await _errorSubscription?.cancel();

    // Reattach listeners
    // The player these listeners belong to: [_audioPlayer] is swapped by
    // [play], and what to judge is the stream of the player that reported it.
    final player = _audioPlayer;
    _playerPlayingSubscription = _audioPlayer.stream.playing.listen((playing) {
      _recovery.playingChanged(playing);
      if (playing) unawaited(_reportAudioOutput(player));
      if (_currentState.isPlaying == playing) return;
      _currentState = _currentState.copyWith(isPlaying: playing);
      _playbackStateController.add(_currentState);
      if (_isBackgroundMode) {
        _channel.invokeMethod('updatePlaybackState', {
          'isPlaying': playing,
          'isBuffering': _isBuffering,
          'title': _currentState.metadata?.title ?? 'TV Ninja',
        });
      }
    });

    _playerBufferingSubscription =
        _audioPlayer.stream.buffering.listen((buffering) {
      _recovery.bufferingChanged(buffering);
      if (_isBuffering == buffering) return;
      _isBuffering = buffering;
      _bufferingController.add(buffering);
      if (buffering) {
        _currentState = _currentState.copyWith(state: PlayerState.buffering);
      } else if (_currentState.state == PlayerState.buffering) {
        _currentState = _currentState.copyWith(state: PlayerState.ready);
      }
      _playbackStateController.add(_currentState);
      if (_isBackgroundMode) {
        _channel.invokeMethod('updatePlaybackState', {
          'isPlaying': _currentState.isPlaying,
          'isBuffering': buffering,
          'title': _currentState.metadata?.title ?? 'TV Ninja',
        });
      }
    });

    _playerCompletedSubscription = player.stream.completed.listen((completed) {
      if (completed) unawaited(_handleCompleted(player));
    });

    _playerPositionSubscription = player.stream.position.listen((position) {
      _lengthEvidence.positionSeen(position, player.state.duration);
      _recovery.positionChanged(position);
    });

    _errorSubscription = _audioPlayer.stream.error.listen((error) {
      debugPrint('[Audio] Stream error: $error');
      _reflectDisconnected();
      // A reconnect attempt that was waiting to hear how it went has its
      // answer; the chain moves on to its next backoff.
      _recovery.attemptFailed();
      final url = _currentUrl;
      if (url != null) unawaited(_handleStreamError(url));
    });
  }

  /// The player whose audio output was last logged, so one player logs once.
  static Player? _audioOutputReportedFor;

  /// Logs which audio output mpv really opened for [player] (`audiotrack` or
  /// `opensles`), as `[Audio] mpv audio output: <name>`, once per player.
  ///
  /// This is the e2e hook's way to tell the sound-mode engine apart: since
  /// both mpv and ExoPlayer now play through an `android.media.AudioTrack`,
  /// the player type in `dumpsys audio` no longer says which engine owns a
  /// track (see `scripts/ci/e2e_hook.sh`). It also shows whether the
  /// AudioTrack output held or mpv fell back to OpenSL ES. `current-ao` is
  /// empty until mpv has opened the output, so it is polled for up to 5 s;
  /// `unknown` means it never answered.
  static Future<void> _reportAudioOutput(Player player) async {
    if (identical(_audioOutputReportedFor, player)) return;
    _audioOutputReportedFor = player;
    var name = 'unknown';
    try {
      final native = player.platform as dynamic;
      for (var i = 0; i < 20; i++) {
        final String value = await (native.getProperty('current-ao') as Future)
            .timeout(const Duration(milliseconds: 500));
        if (value.isNotEmpty) {
          name = value;
          break;
        }
        await Future<void>.delayed(const Duration(milliseconds: 250));
      }
    } catch (_) {
      // Disposed or unreadable: reported as `unknown`.
    }
    debugPrint('[Audio] mpv audio output: $name');
  }

  /// mpv reports the end of the current media. A live stream that ends is a
  /// dropped connection; a file that ends is played again.
  ///
  /// "Live" is not read from the duration at this moment: a device run showed
  /// mpv had already filled in a non-zero duration when `completed` fired for
  /// an HLS channel and an Icecast station, which sent them down the replay
  /// road (a refused seek, an error, a chain started by accident). See
  /// [isLiveStream] for the evidence used instead. The values are logged so a
  /// device run shows what each signal said.
  static Future<void> _handleCompleted(Player player) async {
    final requestId = _playRequestId;
    final epoch = _recovery.epoch;
    final duration = player.state.duration;
    final position = player.state.position;
    final playedWithoutDuration = _lengthEvidence.playedWithoutDuration;
    final seekable = await _readSeekable(player);
    // Superseded while asking mpv: a zap, a stop, a swapped player, or audio
    // flowing again. This end belongs to a stream nobody is waiting on.
    if (!identical(player, _audioPlayer) ||
        requestId != _playRequestId ||
        epoch != _recovery.epoch) {
      return;
    }
    final action = streamEndAction(
      duration: duration,
      seekable: seekable,
      playedWithoutDuration: playedWithoutDuration,
      mayReconnect: _mayReconnect,
    );
    debugPrint('[Audio] Stream ended: duration=$duration position=$position '
        'seekable=$seekable playedWithoutDuration=$playedWithoutDuration '
        '-> ${action.name}');
    switch (action) {
      case StreamEndAction.replay:
        unawaited(player.play());
      case StreamEndAction.reconnect:
        // Do not call play(): on a completed player it seeks to 0, which a
        // live stream refuses, and that refusal is an error event nobody
        // should depend on.
        _reflectDisconnected();
        // A reconnect attempt that reopened and ended at once has failed.
        _recovery.attemptFailed();
        _recovery.schedule();
      case StreamEndAction.ignore:
        break;
    }
  }

  /// mpv's `seekable` property of the media that just ended: `false` when the
  /// demuxer refuses seeks (what a live stream does), `null` when it cannot be
  /// read.
  static Future<bool?> _readSeekable(Player player) async {
    try {
      final native = player.platform as dynamic;
      final String value = await (native.getProperty('seekable') as Future)
          .timeout(const Duration(milliseconds: 500));
      return switch (value) {
        'yes' => true,
        'no' => false,
        _ => null,
      };
    } catch (_) {
      return null;
    }
  }

  /// Immediately reflects a lost stream so the UI stops showing "playing".
  static void _reflectDisconnected() {
    if (_currentState.isPlaying ||
        _currentState.state != PlayerState.buffering) {
      _isBuffering = true;
      _currentState = _currentState.copyWith(
        state: PlayerState.buffering,
        isPlaying: false,
      );
      _playbackStateController.add(_currentState);
      _bufferingController.add(true);
    }
  }

  /// Which stream a probe is running for (its [_playRequestId]), or null.
  /// mpv reports one failure as several error events; while a probe for the
  /// current stream runs, the others have nothing to add.
  static int? _probingRequestId;

  /// Decides what a stream error means: a drop to reconnect from, or a dead
  /// URL to report.
  ///
  /// mpv reports a dead URL and a dropped connection the same way ("Failed to
  /// open ..."), and a dead URL used to loop through five reconnects and a
  /// silent stop. Asking the server (the probe the video path uses) tells the
  /// two apart, but it takes up to four seconds, so it no longer stands in
  /// front of a drop's first retry: see [streamErrorAction]. A stream that
  /// never produced audio is probed at once; one that did is probed only after
  /// two failed reconnects in a row. Only a permanent answer (404/403/401)
  /// ends the session; any other answer leaves the chain to carry on.
  ///
  /// An error that arrives before background mode is on (while [play] is still
  /// starting the foreground service) takes the same road: the first retry is
  /// at least two seconds away, by which time [play] has finished, and a [play]
  /// that fails outright cancels the chain itself.
  static Future<void> _handleStreamError(String url) async {
    final requestId = _playRequestId;
    switch (streamErrorAction(
      mayReconnect: _mayReconnect,
      hasPlayed: _recovery.hasProgressed,
      failedAttempts: _recovery.attempt,
      probeInFlight: _probingRequestId == requestId,
    )) {
      case StreamErrorAction.ignore:
        return;
      case StreamErrorAction.reconnect:
        // A no-op while a chain is already running (the usual case for the
        // error of a reconnect attempt, and for a second line of one failure).
        _recovery.schedule();
        return;
      case StreamErrorAction.probe:
        break;
    }

    final epoch = _recovery.epoch;
    _probingRequestId = requestId;
    final StreamProbeResult probe;
    try {
      probe = await StreamDiagnostics.probe(url, null);
    } finally {
      if (_probingRequestId == requestId) _probingRequestId = null;
    }
    // Superseded while probing: a zap, a stop, or playback flowing again. This
    // result describes a stream nobody is waiting on any more.
    if (requestId != _playRequestId ||
        url != _currentUrl ||
        epoch != _recovery.epoch ||
        !_mayReconnect) {
      return;
    }

    if (StreamDiagnostics.isPermanent(probe)) {
      _surfaceError(StreamDiagnostics.userMessage(probe)!);
    } else {
      _recovery.schedule();
    }
  }

  /// Stops trying and tells the page why. Leaves the service in a terminal,
  /// non-buffering state; [play] starts over from it.
  static void _surfaceError(String message) {
    debugPrint('[Audio] Giving up: $message');
    _recovery.reset();
    // Lets a Retry of the same channel past the same-URL guard at the top of
    // [play]. [_currentUrl] stays set on purpose — see [_gaveUp].
    _gaveUp = true;
    _isBuffering = false;
    _currentState = _currentState.copyWith(
      state: PlayerState.ended,
      isPlaying: false,
    );
    _playbackStateController.add(_currentState);
    _bufferingController.add(false);
    if (_isBackgroundMode) {
      _channel.invokeMethod('updatePlaybackState', {
        'isPlaying': false,
        'isBuffering': false,
        'title': _currentState.metadata?.title ?? 'TV Ninja',
      });
    }
    _lastError = message;
    _errorController.add(message);
  }

  /// Joins a sound-mode URI against the master it was read from.
  ///
  /// An absolute URI comes back unchanged — [Uri.resolve]'s own behaviour —
  /// which is the safest case, since nothing about the master's path can make
  /// it wrong. Anything unparseable falls back to [master], the URL the app
  /// opened before any pinning existed.
  @visibleForTesting
  static String joinSoundModeUriForTest(String master, String soundModeUri) =>
      _joinSoundModeUri(master, soundModeUri);

  static String _joinSoundModeUri(String master, String soundModeUri) {
    try {
      return Uri.parse(master).resolve(soundModeUri).toString();
    } catch (_) {
      return master;
    }
  }

  /// Works out what to open for [channelUrl] and the relative [pin], touching
  /// **no** shared state.
  ///
  /// Pure on purpose. It awaits a master resolution of up to
  /// [_pinResolveBudget], and every static field of this service can be
  /// replaced in that window by a zap or a [stop]. An earlier version wrote
  /// `_openedUrl`/`_masterUrl` itself after that await, which let a slow
  /// resolve for the channel being left overwrite the fields of the channel
  /// now playing — so it opened the previous stream under the new channel's
  /// identity. Returning the answer instead means the caller applies it only
  /// after its own staleness check.
  ///
  /// A direct `.m3u8` is joined as it stands. A suffix-less URL (a relinker)
  /// is resolved first, under [_pinResolveBudget], and if that does not yield
  /// a different URL the channel is left **unpinned** rather than joined
  /// against a base known to be wrong — which is exactly today's behaviour, so
  /// the worst case is no saving, never a broken channel.
  static Future<({String openUrl, String? masterUrl})> _computeOpenUrl(
    String channelUrl,
    String? pin,
  ) async {
    if (pin == null) return (openUrl: channelUrl, masterUrl: null);

    var master = channelUrl;
    var mayPin = true;
    if (guessStreamFormat(channelUrl) == StreamFormatHint.unknown) {
      try {
        final resolved = await StreamUrlResolver.resolve(channelUrl, null)
            .timeout(_pinResolveBudget);
        if (resolved.url != channelUrl) {
          master = resolved.url;
        } else {
          mayPin = false;
        }
      } catch (_) {
        mayPin = false;
      }
    }

    final pinned = mayPin ? _joinSoundModeUri(master, pin) : channelUrl;
    if (pinned == master) {
      debugPrint('[Audio] Sound-mode pin skipped, opening $channelUrl');
      return (openUrl: channelUrl, masterUrl: null);
    }
    debugPrint('[Audio] Sound-mode pin: $pinned (master $master)');
    return (openUrl: pinned, masterUrl: master);
  }

  /// Rebuilds [_openedUrl] and [_masterUrl] for the session that is current
  /// **when the rebuild finishes**, and does nothing at all if that is no
  /// longer the session it started for.
  ///
  /// Used by the reconnect chain, where there is no [play] canceller to lean
  /// on. The identity it checks is the whole of what a new session replaces:
  /// the play request id, the channel URL and the pin.
  static Future<void> _refreshOpenUrl() async {
    final requestId = _playRequestId;
    final channelUrl = _currentUrl;
    if (channelUrl == null) return;
    final pin = _soundModeUri;

    final computed = await _computeOpenUrl(channelUrl, pin);

    if (requestId != _playRequestId ||
        _currentUrl != channelUrl ||
        _soundModeUri != pin) {
      debugPrint('[Audio] Pin rebuild superseded, dropping its result');
      return;
    }
    _openedUrl = computed.openUrl;
    _masterUrl = computed.masterUrl;
  }

  /// Gives up this session's pin for good, falling back to the master (or the
  /// channel URL), and says why.
  ///
  /// Used where the pin itself is the suspect: a first open that never
  /// produced audio, or a start that failed outright. Clearing
  /// [_soundModeUri] is what makes it stick — [_refreshOpenUrl] would
  /// otherwise rebuild the pin on the next attempt.
  static void _abandonPin(String why) {
    if (_soundModeUri == null) return;
    debugPrint('[Audio] Dropping the sound-mode pin: $why');
    _soundModeUri = null;
    _openedUrl = _masterUrl ?? _currentUrl;
    _masterUrl = null;
  }

  /// The recovery chain's `reopen`: starts the current URL again.
  ///
  /// Works with or without background mode: the notification is only updated
  /// when the foreground service is up.
  static Future<void> _reopenCurrentUrl() async {
    if (_currentUrl == null || !_mayReconnect) return;
    final requestId = _playRequestId;

    // A pin that never produced audio is itself the suspect — a stale token on
    // the very first open, a variant that 404s, a base that was wrong — so it
    // is given up for good, per the ruling's "fall back to the master after
    // the first failed attempt".
    //
    // A pin that *did* play is kept: on a flaky mobile link reconnects are
    // constant and have nothing to do with which URL was opened, and dropping
    // it on any dropout would surrender the whole saving in the one case the
    // fix exists for. It is still rebuilt below rather than reused, so a token
    // that expired while it played is replaced with a fresh one.
    if (_soundModeUri != null && !_recovery.hasProgressed) {
      _abandonPin('it never played');
    }
    await _refreshOpenUrl();
    // The resolve above may have taken up to [_pinResolveBudget]: a zap or a
    // stop in that window owns the state now.
    if (requestId != _playRequestId || !_mayReconnect) return;

    final url = _openedUrl ?? _currentUrl;
    if (url == null) return;
    debugPrint('[Audio] Reconnect attempt ${_recovery.attempt}');
    _lengthEvidence.reset();
    try {
      // Emit buffering state so the UI reflects the reconnect attempt
      _isBuffering = true;
      _currentState = _currentState.copyWith(
        state: PlayerState.buffering,
        isPlaying: false,
      );
      _playbackStateController.add(_currentState);
      _bufferingController.add(true);
      if (_isBackgroundMode) {
        await _channel.invokeMethod('updatePlaybackState', {
          'isPlaying': false,
          'isBuffering': true,
          'title': _currentState.metadata?.title ?? 'TV Ninja',
        });
        // A zap or a stop during the call above: this attempt is for a stream
        // nobody is waiting on any more. Compared against [_openedUrl], which
        // is what `url` was read from — against [_currentUrl] this would be
        // unequal for every pinned channel and no reconnect would ever run.
        if (requestId != _playRequestId ||
            url != _openedUrl ||
            !_mayReconnect) {
          return;
        }
      }
      await _audioPlayer.open(Media(url), play: true);
    } catch (e) {
      debugPrint('[Audio] Reconnect failed: $e');
      rethrow;
    }
  }

  static void _handleNativeEvent(Map<String, dynamic> event) {
    final eventType = event['event'] as String?;

    switch (eventType) {
      case 'playRequested':
        _controlController.add(PlaybackControl.play);
        break;
      case 'pauseRequested':
        _controlController.add(PlaybackControl.pause);
        break;
      case 'stopRequested':
        // Stop from the notification or a media key. When the service was
        // started early it is over now (the notification's own Stop takes the
        // service down itself; a media-session stop does not, so it is asked
        // to stop here too, which is harmless when it is already gone). Left
        // set, a later [play] would skip its own start and play with no
        // service.
        if (_foregroundStartedEarly) {
          _clearEarlyForeground();
          unawaited(_stopServiceQuietly());
        }
        _controlController.add(PlaybackControl.stop);
        break;
      case 'foregroundRefused':
        // The system refused the foreground start and the service tore itself
        // down: there is no service and no notification to update.
        debugPrint('[Audio] The system refused the foreground service');
        _clearEarlyForeground();
        _foregroundRefusalCount++;
        _foregroundRefusedController.add(null);
        break;
    }
  }

  /// Forgets an early foreground start: nothing is running for it any more, or
  /// it is being ended right now. Also tells a [startForegroundEarly] still
  /// awaiting the native side that its result is no longer wanted.
  static void _clearEarlyForeground() {
    _foregroundStartedEarly = false;
    _isBackgroundMode = false;
    _foregroundEpoch++;
  }

  /// Asks the native side to stop the service, logging instead of throwing.
  static Future<void> _stopServiceQuietly() async {
    try {
      await _channel.invokeMethod('stopBackground');
    } catch (e) {
      debugPrint('[Audio] Stopping the foreground service failed: $e');
    }
  }

  /// Whether the screen is on and usable (Android's `PowerManager.isInteractive`).
  /// False on a locked phone with the display off.
  ///
  /// `true` on the web, where there is no such thing, and `true` whenever the
  /// answer is unavailable: the safe reading for a caller deciding whether to
  /// act on a lock is "not locked".
  static Future<bool> isScreenInteractive() async {
    if (kIsWeb) return true;
    try {
      return await _channel.invokeMethod<bool>('isInteractive') ?? true;
    } on PlatformException {
      return true;
    } on MissingPluginException {
      return true;
    }
  }

  /// Starts the foreground service and its notification now, before [play]
  /// opens the stream, so the app is already allowed to keep playing when it
  /// goes to the background. [play] then skips its own start after the stream
  /// opened.
  ///
  /// Returns `true` once the system accepted the request, `false` when it was
  /// refused (`FGS_NOT_ALLOWED`), failed, was superseded by a [stop] while it
  /// ran, or on the web. After `false` there is nothing to stop. After `true`
  /// the caller owns the service: it ends with [stop], or with a [play] that
  /// fails.
  static Future<bool> startForegroundEarly({
    required String title,
    String? logo,
  }) async {
    if (kIsWeb) return false;

    // Before the native call: a refusal of this very start is reported as an
    // event, and the native side drops events while nobody listens.
    _listenToNativeEvents();
    final epoch = _foregroundEpoch;
    _foregroundStartedEarly = true;
    try {
      if (kDebugMode && _debugForegroundDelayMs > 0) {
        debugPrint('[Audio] Debug: delaying the early foreground start by '
            '${_debugForegroundDelayMs}ms');
        await Future<void>.delayed(
            const Duration(milliseconds: _debugForegroundDelayMs));
        if (epoch != _foregroundEpoch) return false;
      }
      await _channel.invokeMethod('startBackground', {
        'title': title,
        'logo': logo,
      });
      // A stop, a refusal or a failed play ended this start while the native
      // side was answering: whoever did that already dealt with the service.
      if (epoch != _foregroundEpoch) return false;
      _isBackgroundMode = true;
      return true;
    } on PlatformException catch (e) {
      debugPrint('[Audio] Early foreground start failed: ${e.code} ${e.message}');
      if (epoch == _foregroundEpoch) {
        _foregroundStartedEarly = false;
        _foregroundEpoch++;
      }
      return false;
    } on MissingPluginException {
      if (epoch == _foregroundEpoch) {
        _foregroundStartedEarly = false;
        _foregroundEpoch++;
      }
      return false;
    }
  }

  /// [soundModeUri] is the URI `StreamKindClassifier.peekSoundModeUri` found
  /// for this channel — the audio rendition, or the lowest-bandwidth variant,
  /// **as the master playlist wrote it** and therefore unjoined. Passing it
  /// implements the owner's 2026-11-17 ruling, "sound mode takes the smallest
  /// stream": without it mpv is handed the master, picks the top variant, and
  /// streams its full video+audio while only the audio is played (352 MB /
  /// 10 min measured, ~2.1 GB/h), plus a 2-9 MB first-segment prefix of every
  /// other variant on each open and each reconnect.
  ///
  /// It is joined here, against a master resolved on this call, rather than
  /// stored joined: the value is cached per channel for up to 30 days and a
  /// CDN token in an absolute URL would not survive that.
  static Future<bool> play({
    required String url,
    String? title,
    String? logo,
    String? soundModeUri,
  }) async {
    if (kIsWeb) {
      debugPrint('[Audio] Web mode - not starting background audio');
      return false;
    }

    // If same URL is already playing/buffering, skip recreation.
    // Guard with _isInitialized to avoid LateInitializationError when
    // play() is called before initialize() (lazy-init path).
    if (_isInitialized &&
        !_gaveUp &&
        url == _currentUrl &&
        (_audioPlayer.state.playing || _audioPlayer.state.buffering)) {
      debugPrint(
          '[Audio] Same URL already playing/buffering, skipping recreation');
      return true;
    }

    final requestId = ++_playRequestId;
    _lastError = null;
    _gaveUp = false;
    debugPrint('[Audio] Starting playback $requestId: $url');
    debugPrint('[Audio] Title: $title');

    // Cancel previous pending play by completing its canceller
    _playCanceller?.complete();
    _playCanceller = Completer<void>();
    final canceller = _playCanceller!;

    // Helper to check if this play request has been superseded
    Future<void> checkCancelled() async {
      if (canceller.isCompleted) throw _CancellationException();
      // Also check via requestId
      if (requestId != _playRequestId) throw _CancellationException();
    }

    try {
      // Self-initialize when play() is called before initialize() (lazy-init
      // path: video-only PlayerPage that defers audio Player creation).
      if (!_isInitialized) await initialize();

      await checkCancelled();

      // Every field describing this session is set together, with no await in
      // between, and the old chain is reset before [_refreshOpenUrl] below can
      // yield. The previous session's recovery can still fire in that window,
      // and it must never find this channel's identity paired with the last
      // one's URLs.
      _currentUrl = url;
      _soundModeUri = soundModeUri;
      _openedUrl = url;
      _masterUrl = null;
      _sessionWanted = true;
      _lengthEvidence.reset();
      _recovery.reset();

      // Computed first, applied only once [checkCancelled] has confirmed this
      // play is still the current one — a zap or a stop during the resolve
      // throws here, so a superseded play never writes these fields.
      final computed = await _computeOpenUrl(url, soundModeUri);
      await checkCancelled();
      _openedUrl = computed.openUrl;
      _masterUrl = computed.masterUrl;

      // Reuse or replace the current player.
      // After stop(), _audioPlayer is already a fresh unconfigured Player —
      // configure it in place to avoid a redundant alloc/dispose cycle.
      // Otherwise (play→play), swap to a new one and dispose the old.
      final Player? oldPlayer = _isInitialized ? _audioPlayer : null;
      _isInitialized = true;
      if (oldPlayer == null) {
        // Reuse the fresh player left by stop()
        await applyLiveStreamMpvOptions(_audioPlayer, soundOnly: true);
        await checkCancelled();
        await _setupPlayerListeners();
        await checkCancelled();
      } else {
        // Create new player first so mpv has a valid callback target during old-player teardown
        _audioPlayer = playerFactory();
        await applyLiveStreamMpvOptions(_audioPlayer, soundOnly: true);
        await checkCancelled();
        await _setupPlayerListeners();
        await checkCancelled();
        await oldPlayer.stop();
        await checkCancelled();
        await oldPlayer.dispose();
        await checkCancelled();
      }

      // The new player's listeners are attached: nothing the old player sent
      // while it was being replaced may count towards this stream.
      _recovery.reset();

      // Set state to buffering before opening
      _currentState = _currentState.copyWith(
        state: PlayerState.buffering,
        isPlaying: false,
        metadata: TrackMetadata(
          title: title ?? 'TV Ninja',
          artist: '',
          albumTitle: 'TV Ninja',
        ),
      );
      _playbackStateController.add(_currentState);

      if (kDebugMode && _debugFailAudio && _foregroundStartedEarly) {
        throw StateError('debug: audio start failure forced');
      }

      await _audioPlayer
          .open(Media(_openedUrl ?? url), play: true)
          .timeout(const Duration(seconds: 10));
      await checkCancelled();
      debugPrint('[Audio] Media opened successfully');

      if (_foregroundStartedEarly) {
        // The service was started before the stream opened, see
        // [startForegroundEarly]; starting it again would only repeat its setup.
        debugPrint('[Audio] Foreground service already started early');
      } else {
        // Start background service immediately (shows notification)
        debugPrint('[Audio] Calling startBackground service...');
        await _channel.invokeMethod('startBackground', {
          'title': title ?? 'TV Ninja',
          'logo': logo,
        });
        await checkCancelled();
      }
      _isBackgroundMode = true;
      debugPrint('[Audio] startBackground called');

      // Update notification to show buffering state
      debugPrint('[Audio] Updating notification to show buffering...');
      await _channel.invokeMethod('updatePlaybackState', {
        'isPlaying': false,
        'isBuffering': true,
        'title': title ?? 'TV Ninja',
        'logo': logo,
      });
      debugPrint('[Audio] Buffering notification sent');

      return true;
    } on _CancellationException {
      debugPrint('[Audio] Play $requestId cancelled');
      return false;
    } on PlatformException catch (e) {
      debugPrint('[Audio] PlatformException: ${e.message}');
      await _abandonFailedStart(requestId);
      return false;
    } catch (e) {
      debugPrint('[Audio] Error: $e');
      await _abandonFailedStart(requestId);
      return false;
    }
  }

  /// [play] is about to return `false`: the caller treats that as "no audio
  /// session", so nothing may reconnect it later and its player must not keep
  /// running. Ignored when a newer [play] has already taken over.
  static Future<void> _abandonFailedStart(int requestId) async {
    if (requestId != _playRequestId) return;
    _sessionWanted = false;
    _recovery.reset();
    // The open threw or timed out, so a pin is the one new thing that could
    // have caused it. Dropping it here means the Retry the page offers, and
    // any later start of this same channel, goes back to the URL the app
    // opened before pinning existed — the plan's guarantee that a bad pin can
    // never make a channel less playable than it is today. Only the
    // asynchronous `stream.error` route fell back before this.
    _abandonPin('the start failed');

    // Everything is decided and both stops are issued before the first await,
    // and nothing static is read after one. The stop of the service can take a
    // while (the native side holds it back while a start is still pending), and
    // a zap in that time starts a newer [play] that swaps [_audioPlayer]: a
    // stop issued after the wait would stop the newer play's player.
    final player = _audioPlayer;
    // The service was started for this session and there will be no audio to
    // keep it for: end it, so no empty notification and no wake lock is left.
    final endEarlyService = _foregroundStartedEarly;
    if (endEarlyService) _clearEarlyForeground();

    Future<void> stopPlayer() async {
      try {
        await player.stop();
      } catch (_) {}
    }

    await Future.wait([
      if (endEarlyService) _stopServiceQuietly(),
      stopPlayer(),
    ]);
  }

  static Future<bool> pause() async {
    try {
      await _audioPlayer.pause();
      _currentState = _currentState.copyWith(isPlaying: false);
      _playbackStateController.add(_currentState);

      await _channel.invokeMethod('updatePlaybackState', {
        'isPlaying': false,
        'title': _currentState.metadata?.title ?? 'TV Ninja',
      });

      return true;
    } on PlatformException {
      return false;
    }
  }

  static Future<bool> resume() async {
    try {
      await _audioPlayer.play();
      _currentState = _currentState.copyWith(isPlaying: true);
      _playbackStateController.add(_currentState);

      await _channel.invokeMethod('updatePlaybackState', {
        'isPlaying': true,
        'title': _currentState.metadata?.title ?? 'TV Ninja',
      });

      return true;
    } on PlatformException {
      return false;
    }
  }

  /// How many [stop] calls are running, and the completer [whenStopsSettled]
  /// hands out while any is.
  static int _stopsRunning = 0;
  static Completer<void>? _stopsDone;

  /// Completes once no [stop] is running any more (at once if none is).
  ///
  /// A [stop] sends `stopBackground` as its very last step, after tearing the
  /// player down, so a foreground service started while one is still running
  /// would be stopped by it. Whoever is about to start the service
  /// ([startForegroundEarly]) waits for this first.
  static Future<void> whenStopsSettled() =>
      _stopsDone?.future ?? Future<void>.value();

  static Future<bool> stop() async {
    _stopsRunning++;
    _stopsDone ??= Completer<void>();
    try {
      return await _stopNow();
    } finally {
      if (--_stopsRunning == 0) {
        _stopsDone!.complete();
        _stopsDone = null;
      }
    }
  }

  static Future<bool> _stopNow() async {
    try {
      if (kIsWeb) return true;

      // An early foreground start ends here whatever else is going on, including
      // when the player was never initialised (the early start comes before
      // [initialize]). The native side holds the stop back if the service is
      // still starting.
      final earlyForeground = _foregroundStartedEarly;
      _foregroundStartedEarly = false;
      _foregroundEpoch++;
      if (!_isInitialized) {
        if (earlyForeground) {
          _isBackgroundMode = false;
          await _channel.invokeMethod('stopBackground');
        }
        return true;
      }

      _isBackgroundMode = false;
      _currentUrl = null;
      _openedUrl = null;
      _masterUrl = null;
      _soundModeUri = null;
      _sessionWanted = false;
      _gaveUp = false;
      _recovery.reset();
      _playCanceller?.complete();
      _playCanceller = null;
      await _playerPlayingSubscription?.cancel();
      _playerPlayingSubscription = null;
      await _playerBufferingSubscription?.cancel();
      _playerBufferingSubscription = null;
      await _playerCompletedSubscription?.cancel();
      _playerCompletedSubscription = null;
      await _playerPositionSubscription?.cancel();
      _playerPositionSubscription = null;
      await _errorSubscription?.cancel();
      _errorSubscription = null;
      await _audioPlayer.stop();
      await _audioPlayer.dispose();
      _audioPlayer = playerFactory();
      _isInitialized = false;

      _currentState = PlaybackState();
      _playbackStateController.add(_currentState);
      _isBuffering = false;
      _bufferingController.add(false);

      await _channel.invokeMethod('stopBackground');

      return true;
    } on PlatformException {
      return false;
    }
  }

  static Future<bool> setVolume(double volume) async {
    try {
      await _audioPlayer.setVolume(volume.clamp(0.0, 1.0) * 100);
      return true;
    } on PlatformException {
      return false;
    }
  }

  static Future<bool> get isPlaying async {
    return _audioPlayer.state.playing;
  }

  static Future<void> dispose() async {
    await _eventSubscription?.cancel();
    _eventSubscription = null;
    await _playerPlayingSubscription?.cancel();
    _playerPlayingSubscription = null;
    await _playerBufferingSubscription?.cancel();
    _playerBufferingSubscription = null;
    await _playerCompletedSubscription?.cancel();
    _playerCompletedSubscription = null;
    await _playerPositionSubscription?.cancel();
    _playerPositionSubscription = null;
    await _errorSubscription?.cancel();
    _errorSubscription = null;
    _sessionWanted = false;
    _foregroundStartedEarly = false;
    _foregroundEpoch++;
    _recovery.reset();
    _audioPlayer.dispose();
    _audioPlayer = playerFactory();
    _currentState = PlaybackState();
    _isBuffering = false;
    _gaveUp = false;
    _isInitialized = false;
    _playCanceller?.complete();
    _playCanceller = null;
  }
}

enum PlayerState {
  idle,
  buffering,
  ready,
  ended,
}

class PlaybackState {
  final PlayerState state;
  final bool isPlaying;
  final TrackMetadata? metadata;

  PlaybackState({
    this.state = PlayerState.idle,
    this.isPlaying = false,
    this.metadata,
  });

  PlaybackState copyWith({
    PlayerState? state,
    bool? isPlaying,
    TrackMetadata? metadata,
  }) {
    return PlaybackState(
      state: state ?? this.state,
      isPlaying: isPlaying ?? this.isPlaying,
      metadata: metadata ?? this.metadata,
    );
  }
}

class TrackMetadata {
  final String title;
  final String artist;
  final String albumTitle;

  TrackMetadata({
    required this.title,
    required this.artist,
    required this.albumTitle,
  });
}

enum PlaybackControl {
  play,
  pause,
  stop,
}
