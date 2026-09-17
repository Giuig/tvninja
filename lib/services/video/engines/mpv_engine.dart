import 'dart:async';
import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:tvninja/services/mpv_options.dart';
import 'player_engine.dart';

/// mpv (`media_kit`) playback engine. Serves iOS/desktop unconditionally,
/// and was Android's only engine before Phase 3 introduced [ExoEngine] there
/// (PLAN.md decision 2 — Android always routes to Exo now; this engine is
/// Android's fallback for nothing, but the two coexist per that decision).
///
/// Moved out of `unified_video_player.dart` largely unchanged (Task 3.3):
/// same `Player()` / `VideoController()` / `applyLiveStreamMpvOptions` /
/// `applyFormatHint` / three `stream.*.listen` subscriptions /
/// `Media(url, httpHeaders:)` construction, same
/// `MaterialVideoControlsTheme` + `MaterialVideoControls` UI, as before —
/// this phase relocates that code, it does not rewrite its behaviour.
class MpvEngine extends PlayerEngine {
  MpvEngine({
    required super.onPlaying,
    required super.onPosition,
    required super.onBuffering,
    required super.onEngineError,
  });

  Player? _player;
  VideoController? _videoController;
  StreamSubscription<bool>? _playingSubscription;
  StreamSubscription<Duration>? _positionSubscription;
  StreamSubscription<bool>? _bufferingSubscription;

  /// mpv's `stream.buffering` already only emits on actual state changes
  /// (verified against the original `unified_video_player.dart` code this
  /// was lifted from, which additionally deduplicated with
  /// `if (_isBuffering == buffering) return;` before forwarding) — kept here
  /// so `MpvEngine` behaves identically standalone, without relying on the
  /// caller to dedupe.
  bool? _lastBuffering;

  @override
  Future<void> open(
    String url,
    Map<String, String>? headers, {
    required bool autoPlay,
  }) async {
    _player = Player();
    _videoController = VideoController(_player!);
    await applyLiveStreamMpvOptions(_player!);

    _playingSubscription = _player!.stream.playing.listen(onPlaying);
    _positionSubscription = _player!.stream.position.listen(onPosition);
    _bufferingSubscription = _player!.stream.buffering.listen((buffering) {
      if (_lastBuffering == buffering) return;
      _lastBuffering = buffering;
      onBuffering(buffering);
    });

    applyFormatHint(_player!, url); // sync — no yield before open()
    await _player!.open(Media(url, httpHeaders: headers), play: autoPlay);
  }

  @override
  Future<void> switchTo(String url, Map<String, String>? headers) async {
    applyFormatHint(_player!, url); // sync — no yield before open()
    await _player!.open(Media(url, httpHeaders: headers), play: true);
  }

  @override
  Future<void> play() async => _player?.play();

  @override
  Future<void> pause() async => _player?.pause();

  @override
  Future<void> stop() async => _player?.stop();

  @override
  Future<void> seek(Duration position) async => _player?.seek(position);

  @override
  Future<void> setVolume(double volume) async => _player?.setVolume(volume);

  @override
  bool get isPlaying => _player?.state.playing ?? false;

  @override
  Duration get position => _player?.state.position ?? Duration.zero;

  @override
  Widget buildSurface(BuildContext context, {bool stretch = false}) {
    final insets = MediaQuery.of(context).padding;

    // Empty on purpose. This bar used to hold a fullscreen `IconButton`;
    // fullscreen is now owned by `player_page` (an AppBar action plus an
    // in-fullscreen exit button), so keeping one here would render a second,
    // duplicate control on this path. The override itself stays — dropping
    // it would restore media_kit's *default* bottom bar (position readout,
    // volume, its own fullscreen button), which is not wanted either.
    const bottomButtonBar = <Widget>[];

    return MaterialVideoControlsTheme(
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
        // `fill` distorts to fill the box; `contain` is media_kit's own
        // default and preserves the stream's shape.
        fit: stretch ? BoxFit.fill : BoxFit.contain,
      ),
    );
  }

  @override
  Future<void> dispose() async {
    _playingSubscription?.cancel();
    _positionSubscription?.cancel();
    _bufferingSubscription?.cancel();
    _playingSubscription = null;
    _positionSubscription = null;
    _bufferingSubscription = null;
    final playerToDispose = _player;
    _player = null;
    _videoController = null;
    await playerToDispose?.dispose();
  }
}
