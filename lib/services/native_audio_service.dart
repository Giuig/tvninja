import 'dart:async';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';
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
  static int _reconnectAttempts = 0;
  static Timer? _reconnectTimer;
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
    await _errorSubscription?.cancel();

    // Reattach listeners
    _playerPlayingSubscription = _audioPlayer.stream.playing.listen((playing) {
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

    _errorSubscription = _audioPlayer.stream.error.listen((error) {
      debugPrint('[Audio] Stream error: $error');
      // Immediately reflect disconnected state so UI stops showing "playing"
      if (_currentState.isPlaying || _currentState.state != PlayerState.buffering) {
        _isBuffering = true;
        _currentState = _currentState.copyWith(
          state: PlayerState.buffering,
          isPlaying: false,
        );
        _playbackStateController.add(_currentState);
        _bufferingController.add(true);
      }
      final url = _currentUrl;
      if (url != null) unawaited(_handleStreamError(url));
    });
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
  static Future<void> _handleStreamError(String url) async {
    // Already reported: a further error event from the same failed stream must
    // not start reconnecting again.
    if (_gaveUp) return;
    final requestId = _playRequestId;
    final probe = await StreamDiagnostics.probe(url, null);
    // Superseded while probing: a zap or a stop. This result describes a
    // stream nobody is waiting on any more.
    if (requestId != _playRequestId || url != _currentUrl || _gaveUp) return;

    if (StreamDiagnostics.isPermanent(probe)) {
      _surfaceError(StreamDiagnostics.userMessage(probe)!);
    } else if (_isBackgroundMode) {
      _scheduleReconnect();
    } else {
      // Nothing would retry from here, so staying on "buffering" is the bug.
      _surfaceError(StreamDiagnostics.userMessage(probe) ??
          'Stream not responding — no data received');
    }
  }

  /// Stops trying and tells the page why. Leaves the service in a terminal,
  /// non-buffering state; [play] starts over from it.
  static void _surfaceError(String message) {
    debugPrint('[Audio] Giving up: $message');
    _reconnectTimer?.cancel();
    _reconnectAttempts = 0;
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

  static void _scheduleReconnect() {
    _reconnectTimer?.cancel();
    if (_reconnectAttempts >= 5) {
      debugPrint('[Audio] Max reconnect attempts reached, giving up');
      // Same wording the video path uses when its reconnects give up.
      _surfaceError('Stream lost — connection timed out');
      return;
    }
    final delaySeconds = min(30, 2 * (1 << _reconnectAttempts)); // 2,4,8,16,30
    debugPrint(
        '[Audio] Reconnecting in ${delaySeconds}s (attempt ${_reconnectAttempts + 1}/5)');
    _reconnectTimer = Timer(Duration(seconds: delaySeconds), () async {
      if (!_isBackgroundMode || _currentUrl == null || _gaveUp) return;
      _reconnectAttempts++;
      try {
        // Emit buffering state so the UI reflects the reconnect attempt
        _isBuffering = true;
        _currentState = _currentState.copyWith(
          state: PlayerState.buffering,
          isPlaying: false,
        );
        _playbackStateController.add(_currentState);
        _bufferingController.add(true);
        await _channel.invokeMethod('updatePlaybackState', {
          'isPlaying': false,
          'isBuffering': true,
          'title': _currentState.metadata?.title ?? 'TV Ninja',
        });
        await _audioPlayer.open(Media(_currentUrl!), play: true);
      } catch (e) {
        debugPrint('[Audio] Reconnect failed: $e');
      }
    });
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
      _reconnectAttempts = 0;
      _reconnectTimer?.cancel();

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
      return false;
    } catch (e) {
      debugPrint('[Audio] Error: $e');
      return false;
    }
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
      _gaveUp = false;
      _reconnectAttempts = 0;
      _reconnectTimer?.cancel();
      _reconnectTimer = null;
      _playCanceller?.complete();
      _playCanceller = null;
      await _playerPlayingSubscription?.cancel();
      _playerPlayingSubscription = null;
      await _playerBufferingSubscription?.cancel();
      _playerBufferingSubscription = null;
      await _playerCompletedSubscription?.cancel();
      _playerCompletedSubscription = null;
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
    await _errorSubscription?.cancel();
    _errorSubscription = null;
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
