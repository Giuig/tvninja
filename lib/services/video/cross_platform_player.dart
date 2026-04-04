import 'package:flutter/foundation.dart';

abstract class CrossPlatformPlayer {
  final String url;
  final void Function(bool isPlaying)? onPlayingChanged;
  final void Function(Duration position)? onPositionChanged;
  final void Function(String? error)? onError;
  final void Function()? onCompleted;

  CrossPlatformPlayer({
    required this.url,
    this.onPlayingChanged,
    this.onPositionChanged,
    this.onError,
    this.onCompleted,
  });

  Future<void> initialize();
  Future<void> play();
  Future<void> pause();
  Future<void> stop();
  Future<void> seek(Duration position);
  Future<void> setVolume(double volume);
  bool get isPlaying;
  Duration get position;
  Duration? get duration;
  Future<void> dispose();

  factory CrossPlatformPlayer.create({
    required String url,
    required bool isWeb,
    void Function(bool isPlaying)? onPlayingChanged,
    void Function(Duration position)? onPositionChanged,
    void Function(String? error)? onError,
    void Function()? onCompleted,
  }) {
    if (isWeb) {
      return WebVideoPlayer(
        url: url,
        onPlayingChanged: onPlayingChanged,
        onPositionChanged: onPositionChanged,
        onError: onError,
        onCompleted: onCompleted,
      );
    } else {
      return NativeVideoPlayer(
        url: url,
        onPlayingChanged: onPlayingChanged,
        onPositionChanged: onPositionChanged,
        onError: onError,
        onCompleted: onCompleted,
      );
    }
  }
}

class WebVideoPlayer extends CrossPlatformPlayer {
  WebVideoPlayer({
    required super.url,
    super.onPlayingChanged,
    super.onPositionChanged,
    super.onError,
    super.onCompleted,
  });

  @override
  Future<void> initialize() async {
    // Handled by WebVideoWidget
  }

  @override
  Future<void> play() async {}

  @override
  Future<void> pause() async {}

  @override
  Future<void> stop() async {}

  @override
  Future<void> seek(Duration position) async {}

  @override
  Future<void> setVolume(double volume) async {}

  @override
  bool get isPlaying => false;

  @override
  Duration get position => Duration.zero;

  @override
  Duration? get duration => null;

  @override
  Future<void> dispose() async {}
}

class NativeVideoPlayer extends CrossPlatformPlayer {
  NativeVideoPlayer({
    required super.url,
    super.onPlayingChanged,
    super.onPositionChanged,
    super.onError,
    super.onCompleted,
  });

  @override
  Future<void> initialize() async {}

  @override
  Future<void> play() async {}

  @override
  Future<void> pause() async {}

  @override
  Future<void> stop() async {}

  @override
  Future<void> seek(Duration position) async {}

  @override
  Future<void> setVolume(double volume) async {}

  @override
  bool get isPlaying => false;

  @override
  Duration get position => Duration.zero;

  @override
  Duration? get duration => null;

  @override
  Future<void> dispose() async {}
}
