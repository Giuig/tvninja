import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';
import 'package:tvninja/services/audio_recovery.dart';
import 'package:tvninja/services/mpv_options.dart';
import 'package:tvninja/services/video/stream_diagnostics.dart';

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
  static String? _currentUrl;
  static StreamSubscription<String>? _errorSubscription;
  static int _playRequestId = 0;
  static Completer<void>? _playCanceller;

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
  );

  static late Player _audioPlayer;

  static PlaybackState get currentState => _currentState;
  static bool get isBuffering => _isBuffering;
  static String? get currentUrl => _currentUrl;

  static Future<void> initialize() async {
    if (_isInitialized) return;
    _isInitialized = true;

    _audioPlayer = Player();
    await applyLiveStreamMpvOptions(_audioPlayer);

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

    await _setupPlayerListeners();
  }

  static Future<void> _setupPlayerListeners() async {
    // Cancel existing subscriptions
    await _playerPlayingSubscription?.cancel();
    await _playerBufferingSubscription?.cancel();
    await _playerCompletedSubscription?.cancel();
    await _playerPositionSubscription?.cancel();
    await _errorSubscription?.cancel();

    // Reattach listeners
    _playerPlayingSubscription = _audioPlayer.stream.playing.listen((playing) {
      _recovery.playingChanged(playing);
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

    _playerCompletedSubscription =
        _audioPlayer.stream.completed.listen((completed) {
      if (completed) {
        _audioPlayer.play();
      }
    });

    _playerPositionSubscription =
        _audioPlayer.stream.position.listen(_recovery.positionChanged);

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

  /// Decides whether a failed stream is worth reconnecting to.
  ///
  /// mpv reports a dead URL and a dropped connection the same way ("Failed to
  /// open ..."), so this used to treat every error as a drop: buffering, then
  /// up to five reconnects over about a minute, then a silent stop. For a 404
  /// that meant a minute of "Loading stream..." and no reason given — and when
  /// the error arrived before background mode was on, no reconnect was
  /// scheduled at all, so the spinner never stopped. Asking the server first
  /// (same probe the video path uses) tells the two apart.
  ///
  /// An error that arrives before background mode is on (while [play] is still
  /// starting the foreground service) takes the same road: the first retry is
  /// at least two seconds away, by which time [play] has finished, and a [play]
  /// that fails outright cancels the chain itself.
  static Future<void> _handleStreamError(String url) async {
    // Already reported: a further error event from the same failed stream must
    // not start reconnecting again.
    if (!_mayReconnect) return;
    final requestId = _playRequestId;
    final probe = await StreamDiagnostics.probe(url, null);
    // Superseded while probing: a zap or a stop. This result describes a
    // stream nobody is waiting on any more.
    if (requestId != _playRequestId || url != _currentUrl || !_mayReconnect) {
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

  /// The recovery chain's `reopen`: starts the current URL again.
  ///
  /// Works with or without background mode: the notification is only updated
  /// when the foreground service is up.
  static Future<void> _reopenCurrentUrl() async {
    final url = _currentUrl;
    if (url == null || !_mayReconnect) return;
    final requestId = _playRequestId;
    debugPrint('[Audio] Reconnect attempt ${_recovery.attempt}');
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
        // nobody is waiting on any more.
        if (requestId != _playRequestId ||
            url != _currentUrl ||
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
        _controlController.add(PlaybackControl.stop);
        break;
    }
  }

  static Future<bool> play({
    required String url,
    String? title,
    String? logo,
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

      _currentUrl = url;
      _sessionWanted = true;
      _recovery.reset();

      // Reuse or replace the current player.
      // After stop(), _audioPlayer is already a fresh unconfigured Player —
      // configure it in place to avoid a redundant alloc/dispose cycle.
      // Otherwise (play→play), swap to a new one and dispose the old.
      final Player? oldPlayer = _isInitialized ? _audioPlayer : null;
      _isInitialized = true;
      if (oldPlayer == null) {
        // Reuse the fresh player left by stop()
        await applyLiveStreamMpvOptions(_audioPlayer);
        await checkCancelled();
        await _setupPlayerListeners();
        await checkCancelled();
      } else {
        // Create new player first so mpv has a valid callback target during old-player teardown
        _audioPlayer = Player();
        await applyLiveStreamMpvOptions(_audioPlayer);
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

      await _audioPlayer
          .open(Media(url), play: true)
          .timeout(const Duration(seconds: 10));
      await checkCancelled();
      debugPrint('[Audio] Media opened successfully');

      // Start background service immediately (shows notification)
      debugPrint('[Audio] Calling startBackground service...');
      await _channel.invokeMethod('startBackground', {
        'title': title ?? 'TV Ninja',
        'logo': logo,
      });
      await checkCancelled();
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
    try {
      await _audioPlayer.stop();
    } catch (_) {}
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

  static Future<bool> stop() async {
    try {
      if (!_isInitialized) return true;
      if (kIsWeb) return true;

      _isBackgroundMode = false;
      _currentUrl = null;
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
      _audioPlayer = Player();
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
    _recovery.reset();
    _audioPlayer.dispose();
    _audioPlayer = Player();
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
