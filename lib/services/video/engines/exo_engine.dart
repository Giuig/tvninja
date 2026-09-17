import 'dart:async';
import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';
import '../stream_format_hint.dart';
import '../stream_url_resolver.dart';
import 'player_engine.dart';

/// ExoPlayer (Media3-backed `video_player`/`video_player_android`) playback
/// engine. Android only (PLAN.md decision 2) — new in Phase 3.
///
/// `video_player` exposes state via a `ChangeNotifier` (`controller.value`),
/// not media_kit's per-purpose streams, so [_onControllerTick] diffs
/// `value.isPlaying`/`value.position`/`value.isBuffering`/`value.hasError`
/// against the last-seen values itself (Task 3.4) and fans changes out
/// through the same [onPlaying]/[onPosition]/[onBuffering]/[onEngineError]
/// sinks `MpvEngine` uses, so `UnifiedVideoPlayerState` sees an identical
/// event shape from both engines.
class ExoEngine extends PlayerEngine {
  ExoEngine({
    required super.onPlaying,
    required super.onPosition,
    required super.onBuffering,
    required super.onEngineError,
  });

  VideoPlayerController? _controller;

  /// Bumped by every call that supersedes an in-flight [_createAndOpen]: a new
  /// open/switch, a [stop], or a [dispose].
  ///
  /// Needed because [_createAndOpen] now `await`s [StreamUrlResolver.resolve]
  /// *before* it constructs the controller, so there is a window — seconds
  /// long, for exactly the relinker URLs that feature targets — where an open
  /// is genuinely in flight while `_controller` is still null. [stop] no-ops
  /// when `_controller` is null, so without this counter a user tapping
  /// audio-only mode during that window (`player_page.dart`'s
  /// `_enableAudioMode`) would have its stop silently swallowed: the resolve
  /// would finish, build a controller and — the original `open()` having asked
  /// for `autoPlay` — start playing video *after* the caller believed
  /// playback was stopped, decoding the same stream alongside
  /// `NativeAudioService`. Before the resolve await existed, `_controller` was
  /// assigned synchronously and the window could not occur at all.
  ///
  /// The `!identical(_controller, controller)` check further down does not
  /// cover this: it guards the *post*-construction `initialize()` window only.
  int _openGeneration = 0;

  /// Remembered so [play] can lazily recreate a controller after [stop]
  /// disposes it (Task 3.4a — `video_player` has no `stop()`).
  String? _lastUrl;
  Map<String, String>? _lastHeaders;

  // Last-seen values, diffed on every tick: video_player's ChangeNotifier
  // fires on *every* value change (including the ~100ms position timer),
  // unlike media_kit's separate playing/buffering streams which only emit on
  // an actual change. onPosition still fires every tick (matches mpv's own
  // position stream cadence); the other three are deduplicated here so
  // callers see the same "only on change" shape from both engines.
  bool _lastIsPlaying = false;
  bool _lastIsBuffering = false;
  bool _lastHasError = false;

  /// Disposes [controller] **without awaiting it**.
  ///
  /// Bug fix (found via live testing: rapid channel zaps ending on a
  /// genuinely unresponsive stream deadlocked the whole reconnect chain with
  /// **zero** further activity — no new attempt, no error screen, no manual
  /// Retry reachable — for 3+ minutes straight, worse than the original
  /// hang-forever bug this was supposed to fix). Root cause, traced
  /// precisely: `VideoPlayerController.dispose()` awaits the pending
  /// creation/init machinery before actually tearing down the native
  /// ExoPlayer instance — and releasing a native player that's still
  /// blocked on an unresponsive network read can itself block for as long as
  /// that read never resolves (there's no OS-level socket timeout for this
  /// specific class of stream). Every one of [switchTo]/[stop]/[dispose]
  /// used to `await` this, so once one controller got stuck mid-
  /// `initialize()`, disposing it (to make way for the *next* attempt) blocked
  /// too — every subsequent reconnect attempt queued up behind the exact same
  /// zombie controller, forever, even though each individual `.timeout()`
  /// (`unified_video_player.dart`) *was* firing correctly on its own await.
  /// The `.timeout()` calls only ever stopped their own caller from waiting
  /// — they can't cancel this method or the controller's own disposal.
  ///
  /// Fire-and-forget disposal is the fix: never let tearing down an old
  /// controller block progress on the next one. The [_createAndOpen] identity
  /// check (`if (!identical(_controller, controller)) return;`) is what
  /// already protects against this same controller's `initialize()` — or,
  /// now, its backgrounded `dispose()` — eventually resolving late and
  /// touching now-stale state.
  ///
  /// Scoped to `ExoEngine` only: `MpvEngine`/media_kit has never shown this
  /// failure mode in any live test this plan has run, and mpv's own
  /// teardown model is different enough that copying this workaround there
  /// speculatively isn't warranted.
  void _disposeInBackground(VideoPlayerController? controller) {
    if (controller == null) return;
    unawaited(controller.dispose().catchError((_) {
      // Nothing actionable to do with a disposal error from an already-
      // abandoned controller — this call was never awaited by anything.
    }));
  }

  void _onControllerTick() {
    final controller = _controller;
    if (controller == null) return;
    final value = controller.value;

    if (value.isPlaying != _lastIsPlaying) {
      _lastIsPlaying = value.isPlaying;
      onPlaying(_lastIsPlaying);
    }
    onPosition(value.position);
    if (value.isBuffering != _lastIsBuffering) {
      _lastIsBuffering = value.isBuffering;
      onBuffering(_lastIsBuffering);
    }
    if (value.hasError) {
      if (!_lastHasError) {
        _lastHasError = true;
        onEngineError(value.errorDescription ?? 'video_player playback error');
      }
    } else {
      _lastHasError = false;
    }
  }

  /// The `formatHint` analogue of mpv_options.dart's `applyFormatHint()` —
  /// reuses the same suffix-matching logic (`guessStreamFormat`) rather than
  /// duplicating it, mapped onto `video_player`'s own format enum. A *known*
  /// non-HLS suffix (`.ts`/`.mp4`) falls through to `VideoFormat.other`,
  /// letting ExoPlayer's own bundled progressive extractors handle it
  /// directly (there's no dedicated `VideoFormat` value for mpegts/mp4).
  ///
  /// Bug fix (found live-testing RAI on-device, post-UA-fix): a URL with
  /// **no** recognizable suffix at all used to fall through to
  /// `VideoFormat.other`/progressive too — indistinguishable, in this
  /// method, from "known non-HLS suffix". That's wrong for this app's actual
  /// traffic. RAI's whole lineup (4+ channels) is served through a
  /// relinker/redirect URL —
  /// `mediapolis.rai.it/relinker/relinkerServlet.htm?cont=...` — with no
  /// `.m3u8` anywhere in it; the real `.m3u8` only appears after 2 redirects.
  /// `DefaultMediaSourceFactory` picks its `MediaSource` type from the
  /// *original* request URI before any redirect is followed and never
  /// reconsiders once the response turns out to be HLS, so with no format
  /// hint it picked `ProgressiveMediaSource` (generic byte-sniffing
  /// extractors) — which cannot parse an HLS playlist and threw
  /// `UnrecognizedInputFormatException` outright. mpv/libmpv instead does
  /// real content-sniffing regardless of URL shape, which is why this exact
  /// class of URL always worked on the mpv path and only surfaced here once
  /// the UA fix stopped a 403 from masking it. In this app's actual channel
  /// list, a no-suffix URL is overwhelmingly a relinker/redirect-style
  /// live-TV service that resolves to HLS — so `unknown` now defaults to
  /// `VideoFormat.hls`, split out from the *known*-non-HLS-suffix cases
  /// below, which are unaffected and still map to `VideoFormat.other`.
  ///
  /// Since [StreamUrlResolver] now runs first, this is normally called with
  /// the *resolved* URL, which usually does carry a real `.m3u8` suffix —
  /// so the `unknown` branch has become the fallback for the cases where
  /// resolution was skipped or failed, not the normal path for relinker URLs.
  VideoFormat _formatHintFor(String url) {
    switch (guessStreamFormat(url)) {
      case StreamFormatHint.hls:
      case StreamFormatHint.unknown:
        return VideoFormat.hls;
      case StreamFormatHint.mpegTs:
      case StreamFormatHint.mp4:
        return VideoFormat.other;
    }
  }

  Future<void> _createAndOpen(
    String url,
    Map<String, String>? headers, {
    required bool autoPlay,
  }) async {
    final generation = ++_openGeneration;

    // Deliberately the *original* URL, not the resolved one: a resolved CDN
    // URL carries a short-lived token (RAI's is ~150s), so play()'s lazy
    // recreate after stop() must re-resolve from scratch rather than replay a
    // stale one.
    _lastUrl = url;
    _lastHeaders = headers;
    _lastIsPlaying = false;
    _lastIsBuffering = false;
    _lastHasError = false;

    // Redirect/relinker URLs are refused outright by ExoPlayer's HTTP stack on
    // some providers (see StreamUrlResolver) — resolve on Dart's stack first
    // and hand ExoPlayer the real playlist URL. Returns `url` untouched for
    // direct playlist URLs and for every failure mode, so this is a no-op for
    // the overwhelming majority of channels.
    final playbackUrl = await StreamUrlResolver.resolve(url, headers);

    // Superseded while we were resolving (stop/dispose, or a newer
    // open/switch). Bail out before constructing anything — there is no
    // controller to tear down yet, and whatever bumped the counter owns the
    // engine's state now.
    if (generation != _openGeneration) return;

    final controller = VideoPlayerController.networkUrl(
      Uri.parse(playbackUrl),
      httpHeaders: headers ?? const {},
      formatHint: _formatHintFor(playbackUrl),
    );
    _controller = controller;
    controller.addListener(_onControllerTick);
    // Can throw (e.g. PlatformException on a 404/unreachable host reported
    // before the platform's "initialized" event ever arrives) — left
    // unguarded so it propagates to the same try/catch callers already use
    // around open() (UnifiedVideoPlayerState._initializePlayer).
    await controller.initialize();

    // Use-after-dispose guard (Bug 1 fix, `unified_video_player.dart`):
    // `_initializePlayer()` wraps its call into this engine with a 10s
    // `.timeout()`. `.timeout()` only stops the *caller* waiting — it can't
    // cancel this method, which keeps running in the background. So if
    // `initialize()` above was genuinely hung, the caller may already have
    // given up and, via the public `stop()`/`dispose()` API (e.g. switching
    // to audio-only mode while a channel is still loading), acted on this
    // same `ExoEngine` instance — which disposes `controller` (the one we're
    // holding) and replaces `_controller` with something else entirely
    // (`null`, for `stop()`/`dispose()`; every reconnect/channel-switch path
    // builds a brand-new `ExoEngine` instance instead of reusing this one —
    // see Bug 5 in `unified_video_player.dart` — so that specific race no
    // longer applies, but this same-instance stop/dispose race still can).
    // If that happened, touching `controller` further (`play()`, or writing
    // to `_controller`) would act on an already-disposed object. Bail out
    // here instead — whatever superseded this call owns `_controller`now.
    if (!identical(_controller, controller)) return;

    if (autoPlay) {
      await controller.play();
    }
  }

  @override
  Future<void> open(
    String url,
    Map<String, String>? headers, {
    required bool autoPlay,
  }) async {
    await _createAndOpen(url, headers, autoPlay: autoPlay);
  }

  @override
  Future<void> switchTo(String url, Map<String, String>? headers) async {
    // Task 3.4b: video_player cannot swap a live controller's data source —
    // dispose and recreate. This loses mpv's "keep the surface mounted"
    // trick for zapping (MpvEngine reuses the same Player/VideoController
    // across switchTo() calls); PLAN.md flags that as a known trade-off to
    // *measure*, not a defect to hide. Not measured on-device this phase —
    // no working build/emulator install was available (see TASKS.md).
    final old = _controller;
    _controller = null;
    old?.removeListener(_onControllerTick);
    _disposeInBackground(old);
    await _createAndOpen(url, headers, autoPlay: true);
  }

  @override
  Future<void> play() async {
    if (_controller == null) {
      // stop() disposed the controller (Task 3.4a) — lazily recreate it on
      // the last known URL instead of silently doing nothing.
      final url = _lastUrl;
      if (url == null) return;
      await _createAndOpen(url, _lastHeaders, autoPlay: true);
      return;
    }
    await _controller!.play();
  }

  @override
  Future<void> pause() async => _controller?.pause();

  @override
  Future<void> stop() async {
    // Task 3.4a: video_player has no stop(). player_page._enableAudioMode()
    // calls stop() right before handing the stream to NativeAudioService.
    // Pause, then dispose the controller; play() re-creates lazily, above.
    //
    // Disposal is backgrounded (_disposeInBackground — see its doc comment
    // for the deadlock this fixes), which reopens a narrow window Task 3.4a
    // originally closed: if this controller happens to be stuck exactly
    // like the bug that motivated the change, the native ExoPlayer instance
    // may not be *fully* released by the time this method returns and
    // NativeAudioService starts its own stream. Accepted deliberately —
    // that window only exists for a controller that's already stuck
    // mid-`initialize()` (i.e. not actually pulling data yet in the first
    // place), versus the alternative of `stop()` itself hanging indefinitely
    // and never handing off to audio mode at all. The common case (a
    // healthy, already-initialized controller) disposes just as fast as
    // before — nothing here changes when disposal isn't blocked.
    // Before the null check: an open may be in flight but pre-controller (see
    // [_openGeneration]). Bumping here makes that open abandon itself rather
    // than start playing after this stop.
    _openGeneration++;

    final controller = _controller;
    if (controller == null) return;
    await controller.pause();
    _controller = null;
    controller.removeListener(_onControllerTick);
    _disposeInBackground(controller);
  }

  @override
  Future<void> seek(Duration position) async => _controller?.seekTo(position);

  @override
  Future<void> setVolume(double volume) async => _controller?.setVolume(volume);

  @override
  bool get isPlaying => _controller?.value.isPlaying ?? false;

  @override
  Duration get position => _controller?.value.position ?? Duration.zero;

  @override
  Widget buildSurface(BuildContext context, {bool stretch = false}) {
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized) {
      // Between switchTo()'s dispose and the new controller's initialize()
      // completing, or before the very first open() finishes, there's
      // nothing to show yet. UnifiedVideoPlayerState's own loadingWidget
      // overlay (driven by _isBuffering/_isInitialized) covers this window;
      // an empty box here just avoids touching a torn-down/not-yet-ready
      // controller.
      return const SizedBox.shrink();
    }

    // No `GestureDetector` at this layer, deliberately. `player_page.dart`
    // owns a `Positioned.fill` `GestureDetector` (`onDoubleTap:
    // _toggleFullscreen`) over the whole player body; adding a tap handler
    // here would collide with it — a genuine double-tap would fire this
    // widget's single-tap half first and then that `onDoubleTap`, a visible
    // flicker the mpv path never had (there a tap only revealed/hid the
    // control bar, so the two never meant the same thing).
    //
    // `video_player` ships no controls UI at all (Task 3.5), and per the
    // owner's standing no-NEW-gestures rule nothing may be added here to
    // compensate. Taps and double-taps pass straight through to
    // `player_page.dart`'s overlay, unchanged from the mpv path.
    // Video only — this engine renders no chrome of its own.
    //
    // It used to stack an always-visible fullscreen `IconButton` over the
    // video. That leaked into Picture-in-Picture: `player_page`'s own chrome
    // hides itself when `_isInPipMode`, but a button drawn *inside*
    // `buildSurface` knows nothing about PiP, so it stayed painted over the
    // PiP thumbnail (confirmed on-device, 2026-09-16). The mpv path never
    // showed it because media_kit's control bar is reveal-on-tap and hidden
    // by default.
    //
    // Fullscreen is now `player_page`'s AppBar action plus its in-fullscreen
    // exit button, both of which already gate on `_isInPipMode`. Do not
    // reintroduce chrome at this layer — an engine cannot see the widget
    // state that decides whether chrome should be visible.
    // `VideoPlayer` is a `Texture`, which fills whatever constraints it is
    // given — the `AspectRatio` around it is the only thing preserving the
    // stream's shape. So stretching is simply not wrapping it.
    if (stretch) {
      return VideoPlayer(controller);
    }
    return AspectRatio(
      aspectRatio: controller.value.aspectRatio,
      child: VideoPlayer(controller),
    );
  }

  @override
  Future<void> dispose() async {
    // Backgrounded for the same reason as switchTo()/stop() — see
    // _disposeInBackground's doc comment. This matters here specifically
    // because `UnifiedVideoPlayerState._teardownPlayback()` (which calls
    // this) is itself un-timed and sits directly in front of
    // `_attemptReconnect()`'s heavy-path `_initializePlayer()` call — if this
    // used to block on a stuck controller, the heavy reconnect path's own
    // 10s `open()` timeout would never even be reached, no matter how well
    // *that* timeout worked on its own.
    _openGeneration++;
    final controller = _controller;
    _controller = null;
    controller?.removeListener(_onControllerTick);
    _disposeInBackground(controller);
  }
}
