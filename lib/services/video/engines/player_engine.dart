import 'package:flutter/widgets.dart';

/// Internal engine seam between `UnifiedVideoPlayerState`
/// (`unified_video_player.dart`) and whichever underlying playback engine is
/// in use: `MpvEngine` (media_kit/mpv — iOS/desktop; also Android's fallback
/// before Phase 3, now superseded there) or `ExoEngine` (`video_player`/
/// Media3 — Android only, per PLAN.md decision 2). `UnifiedVideoPlayerState`
/// talks to exactly this surface; no engine-specific type or API leaks above
/// it. Web never reaches either engine — `kIsWeb` keeps its own early return
/// to `WebVideoPlayerWidget` in `unified_video_player.dart`, unchanged.
///
/// This is the exact shape Phase 2's reconnect machinery
/// (`reconnect_controller.dart` + `UnifiedVideoPlayerState._teardownPlayback`/
/// `_attemptReconnect`) calls through: [open] is what `_initializePlayer`
/// calls for every first load, reconnect attempt, and channel switch alike
/// (Bug 5 removed the "reopen on a live engine" optimization entirely — see
/// that method's own doc comment — so nothing in `unified_video_player.dart`
/// calls [switchTo] any more), and [dispose] is what `_teardownPlayback`
/// calls. [switchTo] itself is left implemented on both engines below since
/// removing it from the interface was a larger, unrequested surface change
/// for no behavioural benefit — it's simply unused from this class's
/// perspective now.
abstract class PlayerEngine {
  PlayerEngine({
    required this.onPlaying,
    required this.onPosition,
    required this.onBuffering,
    required this.onEngineError,
  });

  /// Fired whenever the engine's playing/paused state changes.
  final void Function(bool playing) onPlaying;

  /// Fired on every position update the engine reports.
  final void Function(Duration position) onPosition;

  /// Fired whenever the engine's buffering state changes (not on every tick —
  /// callers are expected to have already deduplicated, matching mpv's own
  /// stream semantics).
  final void Function(bool buffering) onBuffering;

  /// Fired when the engine reports an out-of-band playback error (i.e. not
  /// one thrown synchronously from [open]/[switchTo], which callers already
  /// catch directly) — e.g. a `video_player` `ChangeNotifier` tick where
  /// `value.hasError` becomes true. Wiring this into the Phase 2 reconnect
  /// controller is Phase 4's job (REQ-016); this phase only needs the sink to
  /// exist and, for `ExoEngine`, to actually fire.
  final void Function(Object error) onEngineError;

  /// Opens [url] fresh — the first open for this engine instance (construct
  /// the underlying player, wire its native event stream to the callbacks
  /// above, then open). [headers] is the (optional) `User-Agent` map built
  /// once in `UnifiedVideoPlayerState` from `widget.userAgent`; both engines
  /// take the same map so the EXTVLCOPT user-agent chain keeps working
  /// unchanged regardless of engine. [autoPlay] mirrors `widget.autoPlay`.
  Future<void> open(String url, Map<String, String>? headers,
      {required bool autoPlay});

  /// Switches to a new [url] on an already-open engine instance — a channel
  /// zap, or the light (attempt-1) reconnect path. Always resumes playback
  /// (mirrors `widget.autoPlay` being unconditionally `true` in this app's
  /// only call site, `player_page.dart`; unlike [open], this has no
  /// `autoPlay` parameter, since PLAN.md's interface for it doesn't carry
  /// one). Some engines reuse their existing player instance for this
  /// (`MpvEngine`); others cannot swap the data source on a live player and
  /// must dispose and recreate one internally (`ExoEngine` — see its own
  /// doc comment for the resulting zap-flicker trade-off).
  Future<void> switchTo(String url, Map<String, String>? headers);

  Future<void> play();
  Future<void> pause();

  /// Stops playback and — this matters for `player_page._enableAudioMode()`,
  /// which calls [stop] right before handing the stream off to
  /// `NativeAudioService` — actually releases the underlying network
  /// connection, so the device isn't pulling the same live stream twice.
  Future<void> stop();

  Future<void> seek(Duration position);
  Future<void> setVolume(double volume);

  bool get isPlaying;
  Duration get position;

  /// Builds this engine's video surface widget. `UnifiedVideoPlayerState`
  /// calls this fresh on every `build()`; engines whose underlying player
  /// object can be replaced out from under it (`ExoEngine`, on [switchTo])
  /// rely on that rebuild to pick up the new instance.
  Widget buildSurface(BuildContext context);

  Future<void> dispose();
}
