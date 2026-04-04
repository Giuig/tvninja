import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:tvninja/services/mpv_options.dart';
import 'web_video_player.dart';

class UnifiedVideoPlayer extends StatefulWidget {
  final String url;
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
  Player? _player;
  VideoController? _videoController;
  bool _isInitialized = false;
  bool _hasError = false;
  String _errorMessage = '';
  bool _isPlaying = false;
  bool _isBuffering = false;
  bool _hasStartedPlaying = false;

  StreamSubscription<bool>? _playingSubscription;
  StreamSubscription<Duration>? _positionSubscription;
  StreamSubscription<bool>? _bufferingSubscription;
  Timer? _bufferingWatchdog;
  bool _isSwitching = false;
  String? _pendingUrl;

  static String _friendlyError(Object e) {
    if (e is TimeoutException)
      return 'Connection timed out — stream did not respond';
    final msg = e.toString().toLowerCase();
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
    _initializePlayer();
  }

  @override
  void didUpdateWidget(UnifiedVideoPlayer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.url != widget.url) {
      if (_player != null && _isInitialized) {
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
    _playingSubscription?.cancel();
    _positionSubscription?.cancel();
    _bufferingSubscription?.cancel();
    _player?.dispose();
    _player = null;
    _videoController = null;
    _isInitialized = false;
    _hasError = false;
    _isPlaying = false;
    _isBuffering = false;
    _hasStartedPlaying = false;
    _errorMessage = '';
  }

  Future<void> _switchToUrl(String url) async {
    if (_isSwitching) {
      // Queue the latest request — drop intermediate ones (rapid zapping)
      _pendingUrl = url;
      return;
    }
    _isSwitching = true;
    _pendingUrl = null;

    // Cancel watchdog from the previous channel
    _bufferingWatchdog?.cancel();
    _bufferingWatchdog = null;

    // Reset per-channel state — keep _isInitialized = true so the Video
    // widget stays mounted (no surface destruction/recreation)
    _hasStartedPlaying = false;
    if (mounted) setState(() { _isBuffering = true; _hasError = false; });

    // Start a fresh watchdog. The buffering subscription won't restart it
    // because _isBuffering is already true (early-exit guard fires).
    _bufferingWatchdog = Timer(const Duration(seconds: 20), () {
      if (mounted) {
        widget.onError?.call(_hasStartedPlaying
            ? 'Stream lost — connection timed out'
            : 'Stream not responding — no data received');
      }
    });

    try {
      applyFormatHint(_player!, url);  // sync — no yield before open()
      // No .timeout() — the 20 s watchdog above handles unresponsive streams
      await _player!.open(Media(url), play: widget.autoPlay);
    } catch (e) {
      _isSwitching = false;
      // Hard open() failure — fall back to full player recreation
      _cleanup();
      _initializePlayer();
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

  Future<void> _initializePlayer() async {
    if (kIsWeb) {
      return;
    }

    try {
      _player = Player();
      _videoController = VideoController(_player!);
      await applyLiveStreamMpvOptions(_player!);
      applyFormatHint(_player!, widget.url);  // sync — no yield before open()

      _playingSubscription = _player!.stream.playing.listen((playing) {
        _isPlaying = playing;
        widget.onPlayingChanged?.call(playing);
      });

      _positionSubscription = _player!.stream.position.listen((position) {
        if (position > Duration.zero && !_hasStartedPlaying && !_isSwitching) {
          // _isSwitching guard: the old stream keeps playing while player.open()
          // is in flight — its position events must not be counted as first frame
          // of the new stream.
          _hasStartedPlaying = true;
          _bufferingWatchdog?.cancel();
          _bufferingWatchdog = null;
        }
        widget.onPositionChanged?.call(position);
      });

      _bufferingSubscription = _player!.stream.buffering.listen((buffering) {
        if (_isBuffering == buffering) return;
        if (mounted) {
          setState(() => _isBuffering = buffering);
        }
        if (buffering) {
          // Watchdog fires on every buffering start (initial load or mid-play reconnect)
          _bufferingWatchdog?.cancel();
          _bufferingWatchdog = Timer(const Duration(seconds: 20), () {
            if (mounted) {
              widget.onError?.call(_hasStartedPlaying
                  ? 'Stream lost — connection timed out'
                  : 'Stream not responding — no data received');
            }
          });
        } else {
          _bufferingWatchdog?.cancel();
          _bufferingWatchdog = null;
        }
      });

      await _player!
          .open(Media(widget.url), play: widget.autoPlay)
          .timeout(const Duration(seconds: 10));

      if (mounted) {
        setState(() {
          _isInitialized = true;
        });
      }
    } catch (e) {
      final msg = _friendlyError(e);
      if (mounted) {
        setState(() {
          _hasError = true;
          _errorMessage = msg;
        });
      }
      widget.onError?.call(msg);
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
      await _player?.play();
    }
  }

  Future<void> pause() async {
    if (kIsWeb) {
      widget.onPlayingChanged?.call(false);
    } else {
      await _player?.pause();
    }
  }

  Future<void> stop() async {
    if (!kIsWeb) {
      await _player?.stop();
    }
  }

  Future<void> seek(Duration position) async {
    if (!kIsWeb) {
      await _player?.seek(position);
    }
  }

  Future<void> setVolume(double volume) async {
    if (!kIsWeb) {
      await _player?.setVolume(volume);
    }
  }

  bool get isPlaying => _isPlaying;
  Duration get position => _player?.state.position ?? Duration.zero;

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

    final insets = MediaQuery.of(context).padding;

    // Custom fullscreen button - only on non-web, uses our callback
    final fullscreenButton = kIsWeb
        ? null
        : IconButton(
            onPressed: widget.onToggleFullscreen,
            icon: const Icon(Icons.fullscreen),
            iconSize: 32,
            color: Colors.white,
          );

    final bottomButtonBar = [
      const Spacer(),
      if (fullscreenButton != null) fullscreenButton,
    ];

    return Stack(
      children: [
        MaterialVideoControlsTheme(
          normal: MaterialVideoControlsThemeData(
            padding: insets,
            displaySeekBar: false,
            bottomButtonBar: bottomButtonBar,
            seekOnDoubleTap: false,
            seekOnDoubleTapEnabledWhileControlsVisible: false,
          ),
          fullscreen: MaterialVideoControlsThemeData(
            padding: insets,
            displaySeekBar: false,
            bottomButtonBar: bottomButtonBar,
            seekOnDoubleTap: false,
            seekOnDoubleTapEnabledWhileControlsVisible: false,
          ),
          child: Video(
            controller: _videoController!,
            controls: MaterialVideoControls,
          ),
        ),
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
