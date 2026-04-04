import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

class VideoPlayerWidget extends StatefulWidget {
  final String url;
  final bool isWeb;
  final bool autoPlay;
  final void Function(bool isPlaying)? onPlayingChanged;
  final void Function(Duration position)? onPositionChanged;
  final void Function(String? error)? onError;
  final void Function()? onCompleted;
  final Widget? loadingWidget;
  final Widget? errorWidget;

  const VideoPlayerWidget({
    super.key,
    required this.url,
    this.isWeb = false,
    this.autoPlay = true,
    this.onPlayingChanged,
    this.onPositionChanged,
    this.onError,
    this.onCompleted,
    this.loadingWidget,
    this.errorWidget,
  });

  @override
  State<VideoPlayerWidget> createState() => VideoPlayerWidgetState();
}

class VideoPlayerWidgetState extends State<VideoPlayerWidget> {
  late Player _player;
  late VideoController _videoController;
  bool _isInitialized = false;
  bool _hasError = false;
  String _errorMessage = '';
  bool _isPlaying = false;
  
  StreamSubscription<bool>? _playingSubscription;
  StreamSubscription<Duration>? _positionSubscription;
  StreamSubscription<Duration>? _durationSubscription;

  @override
  void initState() {
    super.initState();
    _initializePlayer();
  }

  Future<void> _initializePlayer() async {
    try {
      _player = Player();
      _videoController = VideoController(_player);
      
      _playingSubscription = _player.stream.playing.listen((playing) {
        _isPlaying = playing;
        widget.onPlayingChanged?.call(playing);
      });
      
      _positionSubscription = _player.stream.position.listen((position) {
        widget.onPositionChanged?.call(position);
      });
      
      _durationSubscription = _player.stream.duration.listen((duration) {
        // Duration updated
      });

      await _player.open(Media(widget.url), play: widget.autoPlay);
      
      setState(() {
        _isInitialized = true;
      });
    } catch (e) {
      setState(() {
        _hasError = true;
        _errorMessage = e.toString();
      });
      widget.onError?.call(e.toString());
    }
  }

  @override
  void dispose() {
    _playingSubscription?.cancel();
    _positionSubscription?.cancel();
    _durationSubscription?.cancel();
    _player.dispose();
    super.dispose();
  }

  Future<void> play() => _player.play();
  Future<void> pause() => _player.pause();
  Future<void> stop() => _player.stop();
  Future<void> seek(Duration position) => _player.seek(position);
  Future<void> setVolume(double volume) => _player.setVolume(volume);
  bool get isPlaying => _isPlaying;
  Duration get position => _player.state.position;

  @override
  Widget build(BuildContext context) {
    if (_hasError) {
      return widget.errorWidget ?? _buildDefaultError();
    }

    if (!_isInitialized) {
      return widget.loadingWidget ?? _buildDefaultLoading();
    }

    return Video(
      controller: _videoController,
      controls: NoVideoControls,
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
            Text(
              _errorMessage,
              style: const TextStyle(color: Colors.white70, fontSize: 12),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }
}
