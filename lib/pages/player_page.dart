import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tvninja/config/config.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import 'package:tvninja/l10n/app_localizations.dart';
import 'package:tvninja/services/native_audio_service.dart';
import 'package:tvninja/services/pip_service.dart';
import 'package:tvninja/services/video/unified_video_player.dart';
import 'package:tvninja/widgets/channel_logo.dart';

class PlayerPage extends StatefulWidget {
  final Channel channel;
  final List<Channel>? channels;
  final int? initialIndex;
  final bool initialAudioOnly;

  const PlayerPage({
    super.key,
    required this.channel,
    this.channels,
    this.initialIndex,
    this.initialAudioOnly = false,
  });

  @override
  State<PlayerPage> createState() => _PlayerPageState();
}

class _PlayerPageState extends State<PlayerPage> with WidgetsBindingObserver {
  final GlobalKey<UnifiedVideoPlayerState> _playerKey = GlobalKey();
  bool _hasError = false;
  String _errorMessage = '';
  bool _audioOnlyMode = false;
  bool _isPlaying = false;
  bool _isBuffering = false;
  bool _isAudioModeActive = false;
  bool _isInPipMode = false;
  bool _channelListExpanded = false;

  /// Drives the quick channel list so it can be centred on the current channel.
  ///
  /// The list is only mounted while [_channelListExpanded] is true, so every use
  /// must check `hasClients` first — zapping with the list closed is the common
  /// case, not the exception.
  final ScrollController _channelListScrollController = ScrollController();

  /// Height of one row in the quick channel list.
  ///
  /// Derived, not hardcoded. The rows happen to be uniform today because the
  /// 32px logo box is taller than the text column, so the conditional group line
  /// (`if (channel.displayGroup != null)`) changes nothing — but that stops being true
  /// somewhere above 1.15x font scale, and nothing in this app clamps
  /// textScaler. Same reasoning as the grid extent in `playlist_page.dart`.
  ///
  /// The 28.0 is this list's own two text lines at stock scale (`fontSize: 13`
  /// for the name plus `fontSize: 10` for the group) — revisit it if either
  /// changes.
  double _channelRowExtent(BuildContext context) {
    final textScale = MediaQuery.textScalerOf(context).scale(1);
    final textHeight = 28.0 * textScale;
    final content = textHeight < 32.0 ? 32.0 : textHeight;
    return content + 16; // vertical padding, 8 top + 8 bottom
  }

  /// Offset that puts row [index] in the middle of the viewport, clamped so the
  /// ends of the list do not overscroll.
  double _offsetToCentre(int index, double extent) {
    final position = _channelListScrollController.position;
    final target =
        index * extent - (position.viewportDimension - extent) / 2;
    return target.clamp(0.0, position.maxScrollExtent);
  }

  /// Whether row [index] is currently on screen.
  bool _rowIsVisible(int index, double extent) {
    final position = _channelListScrollController.position;
    final top = index * extent;
    return top + extent > position.pixels &&
        top < position.pixels + position.viewportDimension;
  }

  /// Centres the quick list on the current channel.
  ///
  /// [animate] is false when the list is opening: it is appearing on screen at
  /// that same moment, and an animated scroll from offset 0 would read as the
  /// list scrolling itself *after* it appeared. On a zap the list is already on
  /// screen and the user is watching it, so the movement should be animated.
  void _centreOnCurrentChannel({required bool animate}) {
    if (!_channelListScrollController.hasClients) return;
    final extent = _channelRowExtent(context);
    final target = _offsetToCentre(_currentIndex, extent);
    if (animate) {
      _channelListScrollController.animateTo(
        target,
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOut,
      );
    } else {
      _channelListScrollController.jumpTo(target);
    }
  }

  /// Re-centres after a zap, but only when the user is actually looking at the
  /// current channel.
  ///
  /// If they have scrolled off to browse, leaving the list where they put it
  /// matters more than keeping the highlight centred — yanking it away mid-scroll
  /// is the usual complaint about always-follow list behaviour.
  void _followCurrentChannelIfVisible() {
    if (!_channelListExpanded) return;
    if (!_channelListScrollController.hasClients) return;
    final extent = _channelRowExtent(context);
    if (!_rowIsVisible(_currentIndex, extent)) return;
    _centreOnCurrentChannel(animate: true);
  }
  bool _isFullscreen = false;

  /// Fullscreen-only: fill the screen instead of letterboxing.
  ///
  /// **Persisted, and deliberately so — owner decision, 2026-09-21.** This
  /// reverses the original rule, which reset it on leaving fullscreen on the
  /// grounds that stretching distorts the picture and nobody should be able to
  /// leave it on by accident and later wonder why everyone looks wide. The
  /// owner was shown that reasoning and overruled it: the choice now survives
  /// leaving fullscreen, leaving the player, and restarting the app.
  ///
  /// The scope was specified with it: the fullscreen fit button is the **only**
  /// way to change this. Do not add a Settings row for it.
  ///
  /// So if a later session finds this surprising — it is not a missing reset.
  bool _stretchToFill = false;

  /// SharedPreferences key for [_stretchToFill].
  static const String _stretchToFillPrefKey = 'stretch_to_fill';

  /// Whether the *video* engine is currently buffering.
  ///
  /// Separate from [_isBuffering] on purpose, not by oversight. That field is
  /// fed from `NativeAudioService` behind an `_isAudioModeActive` guard, so it
  /// describes the audio path only and is stale during video — which makes it
  /// exactly the wrong thing to gate a video control on, while looking exactly
  /// like the right thing. Unifying the two is a bigger change than the bug
  /// that prompted this, and would put the working audio placeholder at risk.
  ///
  /// Starts **true**, and that default is the fix rather than a detail: the
  /// player reports only *transitions*, and on a fresh open there is no
  /// transition to report until the engine is up — so a `false` default left
  /// the control live for the entire initial load, which is the exact case
  /// that was reported. `UnifiedVideoPlayer._lastReportedBusy` starts true to
  /// match.
  bool _isVideoBuffering = true;

  late List<Channel> _channels;
  late int _currentIndex;
  late Channel _currentChannel;

  StreamSubscription<PlaybackState>? _playbackStateSubscription;
  StreamSubscription<PlaybackControl>? _controlSubscription;
  StreamSubscription<bool>? _bufferingSubscription;
  StreamSubscription<bool>? _pipSubscription;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);

    // Initialize channel list
    _channels = widget.channels ?? [widget.channel];
    _currentIndex = widget.initialIndex ??
        _channels.indexWhere((c) => c.url == widget.channel.url);
    if (_currentIndex == -1) {
      _currentIndex = 0;
    }
    _currentChannel = _channels[_currentIndex];

    // If we are supposed to start in audio-only mode (audio already playing)
    if (widget.initialAudioOnly) {
      _audioOnlyMode = true;
      _isAudioModeActive = true;
    }

    unawaited(_restoreStretchToFill());
    _initializePlayer();
    _initializeNativeAudio();
    _listenToPipState();
    _syncDerivedPlaybackState();

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        context.read<AppStatsNotifier>().incrementViews();
        context.read<AppStatsNotifier>().addToRecentlyWatched(_currentChannel);
      }
    });
  }

  void _listenToPipState() {
    if (kIsWeb) return;
    _pipSubscription = PipService.pipStateStream.listen((isInPip) {
      if (mounted) {
        setState(() {
          _isInPipMode = isInPip;
        });
        // `_isInPipMode` is an input to the wakelock now, so entering or leaving
        // PiP has to reconcile it like every other mutation does. Without this
        // the flag would flip and the lock would keep whatever value it had —
        // the exact drift the sync helpers exist to prevent.
        _syncWakelock();
      }
    });
  }

  void _toggleFullscreen() {
    if (_isFullscreen) {
      _exitFullscreen();
    } else {
      _enterFullscreen();
    }
  }

  void _enterFullscreen() {
    // Show the overlay across the transition: in fullscreen it is the *only*
    // chrome, so entering with it hidden would leave a bare video and no
    // visible way back. The auto-hide timer then clears it as usual.
    _showControls();
    setState(() => _isFullscreen = true);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    if (!kIsWeb) {
      SystemChrome.setPreferredOrientations([
        DeviceOrientation.landscapeLeft,
        DeviceOrientation.landscapeRight,
      ]);
    }
    _syncWakelock();
  }

  void _exitFullscreen() {
    _showControls();
    // _stretchToFill is NOT reset here any more — see its declaration. It is a
    // persisted preference now, so leaving fullscreen must leave it alone.
    setState(() {
      _isFullscreen = false;
    });
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    if (!kIsWeb) {
      // Release the lock rather than "restoring" an orientation. This used to
      // pick landscape-or-portrait from whatever was captured on the way in,
      // which does not restore anything — it *pins* the app to that one
      // orientation for the rest of the process, so autorotate silently stopped
      // working until the app was killed and reopened.
      //
      // The empty list is Flutter's "no preference, follow the system", which is
      // what the rest of the app already runs on: main.dart never sets a
      // preference and the manifest declares screenOrientation="unspecified".
      SystemChrome.setPreferredOrientations([]);
    }
    _syncWakelock();
  }

  /// Holds the screen awake while there is video worth watching on screen.
  ///
  /// It used to be `enable()` in [_enterFullscreen] and `disable()` in
  /// [_exitFullscreen], which meant the **windowed** player never held the lock
  /// at all — the screen could sleep during ordinary playback, and leaving
  /// fullscreen dropped the lock rather than handing it back to the windowed
  /// player. Gated on the wrong condition, exactly like the PiP flag was.
  ///
  /// Audio-only deliberately does **not** hold it: the point of that mode is to
  /// put the phone down. Neither does an error screen, which has nothing to
  /// watch.
  ///
  /// **Nor does picture-in-picture.** A PiP window is something you glance at
  /// beside another app, not something that should defeat the screen timeout —
  /// and measured on 2026-09-17, it did: after leaving the app with video
  /// playing, `dumpsys power` showed a SCREEN_BRIGHT_WAKE_LOCK still attributed
  /// to this app's uid while only the PiP window was on screen. That was a
  /// regression introduced when this helper replaced the old
  /// fullscreen-only `WakelockPlus.enable()`, which never covered PiP because it
  /// only ever ran on entering fullscreen. The partial wakelocks ExoPlayer and
  /// the audio mixer hold are theirs and are correct — this is only about
  /// keeping the display lit.
  ///
  /// Call it *after* the `setState` that changes any input — it reads them.
  void _syncWakelock() {
    final watchable =
        _isPlaying && !_audioOnlyMode && !_hasError && !_isInPipMode;
    if (watchable) {
      WakelockPlus.enable();
    } else {
      WakelockPlus.disable();
    }
  }

  Future<void> _initializeNativeAudio() async {
    if (kIsWeb) return;

    // Only pay the Player() cold-start cost now if audio is already active.
    // For video mode, NativeAudioService.play() will initialize on demand
    // the first time the user switches to audio — saving ~200-400 ms on
    // every channel tap for the common video-only path.
    if (_audioOnlyMode) {
      await NativeAudioService.initialize();
    }

    _playbackStateSubscription =
        NativeAudioService.playbackStateStream.listen((state) {
      if (mounted && _isAudioModeActive) {
        final newPlaying = state.isPlaying;
        debugPrint(
            '[PlayerPage] playbackStateStream: isPlaying=${state.isPlaying}, _isPlaying=$_isPlaying, _isBuffering=$_isBuffering');
        if (_isPlaying != newPlaying) {
          debugPrint('[PlayerPage] updating _isPlaying=$newPlaying');
          setState(() {
            _isPlaying = newPlaying;
          });
          _syncWakelock();
        }
      }
    });

    _bufferingSubscription =
        NativeAudioService.bufferingStream.listen((buffering) {
      debugPrint(
          '[PlayerPage] bufferingStream: buffering=$buffering, _isBuffering=$_isBuffering, _isAudioModeActive=$_isAudioModeActive');
      if (mounted && _isAudioModeActive && _isBuffering != buffering) {
        debugPrint('[PlayerPage] setting _isBuffering = $buffering');
        setState(() => _isBuffering = buffering);
      }
    });

    _controlSubscription = NativeAudioService.controlStream.listen((control) {
      if (mounted) {
        switch (control) {
          case PlaybackControl.play:
            if (_isAudioModeActive) {
              NativeAudioService.resume();
            }
            break;
          case PlaybackControl.pause:
            if (_isAudioModeActive) {
              NativeAudioService.pause();
            }
            break;
          case PlaybackControl.stop:
            if (_isAudioModeActive) {
              _disableAudioMode();
            }
            break;
        }
      }
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _playbackStateSubscription?.cancel();
    _controlSubscription?.cancel();
    _bufferingSubscription?.cancel();
    _pipSubscription?.cancel();
    _controlsHideTimer?.cancel();
    _channelListScrollController.dispose();
    PipService.setFullscreenVideoMode(false);
    // Unconditionally, and NOT inside the `_isFullscreen` branch below where it
    // used to sit. That was harmless only while the lock was taken in
    // `_enterFullscreen` alone — a windowed player never held it, so there was
    // nothing to release. Now that it is held for any watchable video, leaving
    // the page while windowed would leak an awake screen for the rest of the
    // session.
    WakelockPlus.disable();
    if (_isFullscreen) {
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    }
    // Outside the `_isFullscreen` branch above, for the same reason
    // `WakelockPlus.disable()` is: cleanup gated on a flag leaks whenever the
    // flag does not match reality. Releasing when nothing was ever locked is a
    // no-op, so unconditional costs nothing and removes the whole class.
    if (!kIsWeb) {
      SystemChrome.setPreferredOrientations([]);
    }
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused) {
      // App going to background - audio continues via native foreground service
    } else if (state == AppLifecycleState.resumed) {
      // App coming to foreground
    }
  }

  Future<void> _initializePlayer() async {
    // Player initialization is handled by UnifiedVideoPlayer
  }

  void _toggleAudioOnlyMode() {
    if (_audioOnlyMode) {
      _disableAudioMode();
    } else {
      _enableAudioMode();
    }
  }

  /// Tells the native side whether picture-in-picture may be entered.
  ///
  /// The flag has **two** owners — audio-only mode and the error state — so it
  /// is derived here instead of being assigned at each call site. Assigning it
  /// per-site is what let it drift: `initState` set it unconditionally even
  /// when starting in audio-only mode, and `_enableAudioMode`'s failure path
  /// reverted `_audioOnlyMode` without restoring it, disabling PiP for the rest
  /// of the session.
  ///
  /// The predicate is not new. `_buildBody` already gates the fullscreen button
  /// and the control overlay on exactly `!_audioOnlyMode && !_hasError`; the
  /// native flag was the one consumer left out of that rule, which is why
  /// backgrounding a failed channel pinned its error screen into the PiP
  /// window.
  ///
  /// Call it *after* the `setState` that changes either field, never before —
  /// it reads them.
  /// Single point where state derived from playback is reconciled.
  ///
  /// PiP eligibility and the wakelock read overlapping inputs
  /// (`_audioOnlyMode`, `_hasError`, and for the wakelock `_isPlaying`), and
  /// both were previously set at individual call sites. That is what let each of
  /// them drift out of step with the state it was supposed to follow. Keeping
  /// one entry point means a new path that changes any of those inputs has one
  /// thing to remember, not two.
  ///
  /// Call it *after* the `setState` that changes any input — both helpers read
  /// current field values.
  void _syncDerivedPlaybackState() {
    _syncPipEligibility();
    _syncWakelock();
  }

  void _syncPipEligibility() {
    PipService.setFullscreenVideoMode(!_audioOnlyMode && !_hasError);
  }

  Future<void> _enableAudioMode() async {
    if (kIsWeb) {
      setState(() {
        _audioOnlyMode = true;
      });
      // Inert today twice over — this branch is unreachable while the toggle
      // that calls it is gated on `!kIsWeb`, and `setFullscreenVideoMode` itself
      // no-ops under `kIsWeb`. Synced anyway: "agrees because it cannot run" is
      // the same kind of luck this helper exists to remove, and it would start
      // drifting again the moment either guard moves.
      _syncDerivedPlaybackState();
      return;
    }

    try {
      await _playerKey.currentState?.stop();
      // Show the audio placeholder with spinner immediately — before play() is
      // called — so the user sees loading feedback from the very first frame.
      setState(() {
        _audioOnlyMode = true;
        _isBuffering = true;
      });
      // Pressing home in audio-only mode should background the app normally,
      // not enter picture-in-picture.
      _syncDerivedPlaybackState();

      final success = await NativeAudioService.play(
        url: _currentChannel.url,
        title: _currentChannel.name,
        logo: _currentChannel.logo,
      );

      if (success) {
        setState(() {
          _isAudioModeActive = true;
          // Re-read the live value rather than waiting for the next event.
          //
          // `_isBuffering` was set true above, before this flag existed, and the
          // buffering listener drops anything arriving while `_isAudioModeActive`
          // is still false. So when the stream settled *during* the await — the
          // common case on a fast connection — the "no longer buffering" event
          // was discarded and nothing later re-sent it, leaving the spinner
          // turning over audio that was already playing. That is the "sometimes"
          // in the report: it depends purely on whether the event beat this line.
          _isBuffering = NativeAudioService.isBuffering;
        });
      } else {
        setState(() {
          _audioOnlyMode = false;
          _isBuffering = false;
        });
        _syncDerivedPlaybackState();
        _playerKey.currentState?.play();
      }
    } catch (e) {
      debugPrint('Native audio failed: $e');
      try {
        _playerKey.currentState?.play();
      } catch (_) {}
    }
  }

  Future<void> _disableAudioMode() async {
    if (_isAudioModeActive) {
      await NativeAudioService.stop();
      _isAudioModeActive = false;
    }

    try {
      _playerKey.currentState?.play();
    } catch (_) {}

    setState(() {
      _audioOnlyMode = false;
    });
    _syncDerivedPlaybackState();
  }

  /// Whether the on-video control overlay is showing.
  ///
  /// Starts hidden, matching NewPipe (the reference the owner picked): a
  /// freshly opened channel shows clean video. Only the overlay participates
  /// — the AppBar and channel bar sit *beside* the video, not over it, so
  /// hiding them would resize the video and jump the layout on every toggle.
  bool _controlsVisible = false;

  /// Auto-hide timer. Without it, a tap to check the controls leaves them
  /// parked over the video for the rest of the channel.
  Timer? _controlsHideTimer;

  static const Duration _controlsHideAfter = Duration(seconds: 4);

  /// Reveals the overlay and (re)arms the auto-hide countdown.
  void _showControls() {
    _controlsHideTimer?.cancel();
    _controlsHideTimer = null;
    // Bail before arming a new timer, not just before setState. Every caller
    // today is a live UI callback so this cannot fire unmounted — but the
    // earlier shape created the timer unconditionally, so wiring this to any
    // async listener (as several others in this file are) would have started
    // a countdown on a disposed State. Narrowed now rather than left as a trap.
    if (!mounted) return;
    setState(() => _controlsVisible = true);
    _controlsHideTimer = Timer(_controlsHideAfter, () {
      if (mounted) setState(() => _controlsVisible = false);
    });
  }

  void _hideControls() {
    _controlsHideTimer?.cancel();
    _controlsHideTimer = null;
    if (mounted) setState(() => _controlsVisible = false);
  }

  /// Bound to `onTap` on the *same* `GestureDetector` as `onDoubleTap`, which
  /// is what lets Flutter disambiguate the two: a genuine double-tap resolves
  /// to `onDoubleTap` alone and never fires this first. Two separate detectors
  /// in different layers would not — that collision is what
  /// `exo_engine.dart`'s `buildSurface` comment warns about.
  ///
  /// Allowed under the owner's gesture rule because it performs no action of
  /// its own: it only surfaces buttons that are already real and tappable.
  ///
  /// Costs ~300ms of latency on every single tap: Flutter must wait out the
  /// double-tap window before it can rule out a double-tap and settle the
  /// arena on this callback. That delay is the price of the disambiguation
  /// above, not a bug — but it is why the reveal feels a beat behind the
  /// finger compared with NewPipe, which the owner noticed and reported.
  ///
  /// **Settled 2026-09-17: the delay is accepted and the double-tap stays.**
  /// The two cannot both be had while one surface carries both gestures, and
  /// the owner chose the double-tap. So this is not an open performance item —
  /// do not "optimise" it by dropping `onDoubleTap`, splitting the detectors
  /// (which reintroduces the collision `exo_engine.dart`'s `buildSurface`
  /// warns about), or shortening the arena timeout. If it is ever revisited,
  /// it is a product decision to reopen first, not a refactor.
  void _toggleControls() {
    if (_controlsVisible) {
      _hideControls();
    } else {
      _showControls();
    }
  }

  /// Loads the persisted fullscreen fit.
  ///
  /// Async and unawaited on purpose: the default is false and the value only
  /// matters once the user reaches fullscreen, which is many frames away. Do
  /// not turn this into a blocking read to make the first frame "correct" —
  /// there is nothing to correct.
  Future<void> _restoreStretchToFill() async {
    final prefs = await SharedPreferences.getInstance();
    final stored = prefs.getBool(_stretchToFillPrefKey) ?? false;
    if (!mounted || stored == _stretchToFill) return;
    setState(() => _stretchToFill = stored);
  }

  Future<void> _persistStretchToFill(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_stretchToFillPrefKey, value);
  }

  void _togglePlayPause() {
    if (_isAudioModeActive) {
      if (_isPlaying) {
        NativeAudioService.pause();
      } else {
        NativeAudioService.resume();
      }
    } else {
      if (_isPlaying) {
        _playerKey.currentState?.pause();
      } else {
        _playerKey.currentState?.play();
      }
    }
  }

  void _playNextChannel() {
    if (_channels.length <= 1) return;
    setState(() {
      _currentIndex = (_currentIndex + 1) % _channels.length;
      _currentChannel = _channels[_currentIndex];
      _hasError = false;
      _errorMessage = '';
      // The new stream has not reported anything yet. Assume buffering
      // rather than leaving the play/pause control live on the strength of
      // the *previous* channel's last engine event.
      _isVideoBuffering = true;
    });
    _syncDerivedPlaybackState();
    _followCurrentChannelIfVisible();
    context.read<AppStatsNotifier>().addToRecentlyWatched(_currentChannel);
    _switchAudioChannelIfNeeded();
  }

  void _playPreviousChannel() {
    if (_channels.length <= 1) return;
    setState(() {
      _currentIndex = (_currentIndex - 1 + _channels.length) % _channels.length;
      _currentChannel = _channels[_currentIndex];
      _hasError = false;
      _errorMessage = '';
      // The new stream has not reported anything yet. Assume buffering
      // rather than leaving the play/pause control live on the strength of
      // the *previous* channel's last engine event.
      _isVideoBuffering = true;
    });
    _syncDerivedPlaybackState();
    _followCurrentChannelIfVisible();
    context.read<AppStatsNotifier>().addToRecentlyWatched(_currentChannel);
    _switchAudioChannelIfNeeded();
  }

  void _toggleChannelList() {
    setState(() => _channelListExpanded = !_channelListExpanded);
    if (!_channelListExpanded) return;
    // The ListView does not exist yet at the moment the flag flips, so the
    // controller has no clients until after this frame lays it out.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _centreOnCurrentChannel(animate: false);
    });
  }

  void _selectChannel(int index) {
    setState(() {
      _channelListExpanded = false;
      _currentIndex = index;
      _currentChannel = _channels[index];
      _hasError = false;
      _errorMessage = '';
      // Same reason as the next/previous paths: the new stream has reported
      // nothing yet, so do not leave the control live on stale state.
      _isVideoBuffering = true;
    });
    _syncDerivedPlaybackState();
    context.read<AppStatsNotifier>().addToRecentlyWatched(_currentChannel);
    _switchAudioChannelIfNeeded();
  }

  /// When in audio-only mode, tell NativeAudioService to switch to the
  /// new channel. Calling play() again replaces the current media stream.
  Future<void> _switchAudioChannelIfNeeded() async {
    debugPrint(
        '[PlayerPage] _switchAudioChannelIfNeeded: _isAudioModeActive=$_isAudioModeActive');
    if (!_isAudioModeActive) return;
    debugPrint('[PlayerPage] setting _isBuffering = true');
    setState(() => _isBuffering = true);
    final success = await NativeAudioService.play(
      url: _currentChannel.url,
      title: _currentChannel.name,
      logo: _currentChannel.logo,
    );
    if (!success && mounted) {
      setState(() => _isBuffering = false);
    }
  }

  Widget _buildExpandableChannelList() {
    return AnimatedSize(
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeInOut,
      child: _channelListExpanded
          ? Container(
              height: 240,
              color: const Color(0xFF111111),
              child: Column(
                children: [
                  // Collapse handle
                  GestureDetector(
                    onTap: _toggleChannelList,
                    child: Container(
                      width: double.infinity,
                      padding: const EdgeInsets.symmetric(vertical: 7),
                      color: const Color(0xFF1A1A1A),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          const Icon(Icons.keyboard_arrow_down,
                              color: Colors.white38, size: 16),
                          const SizedBox(width: 6),
                          const Text('Channels',
                              style: TextStyle(
                                  color: Colors.white60, fontSize: 12)),
                          const SizedBox(width: 6),
                          Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 6, vertical: 1),
                            decoration: BoxDecoration(
                              color: Colors.white10,
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: Text(
                              '${_currentIndex + 1}/${_channels.length}',
                              style: const TextStyle(
                                  color: Colors.white38, fontSize: 10),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  // Channel list
                  Expanded(
                    child: ListView.builder(
                      controller: _channelListScrollController,
                      // Fixed extent: makes the centring arithmetic exact rather
                      // than approximate, and saves the list measuring every row.
                      itemExtent: _channelRowExtent(context),
                      itemCount: _channels.length,
                      itemBuilder: (context, index) {
                        final channel = _channels[index];
                        // Index, not URL. Two channels can carry the same
                        // stream, and comparing urls lit both of them up as
                        // "current" at once.
                        final isCurrent = index == _currentIndex;
                        return InkWell(
                          onTap: () => _selectChannel(index),
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 16, vertical: 8),
                            decoration: BoxDecoration(
                              color: isCurrent
                                  ? Colors.blue.withValues(alpha: 0.1)
                                  : Colors.transparent,
                              border: Border(
                                left: BorderSide(
                                  color: isCurrent
                                      ? Colors.blue
                                      : Colors.transparent,
                                  width: 3,
                                ),
                              ),
                            ),
                            child: Row(
                              children: [
                                Container(
                                  width: 32,
                                  height: 32,
                                  decoration: BoxDecoration(
                                    color: Colors.white.withValues(alpha: 0.06),
                                    borderRadius: BorderRadius.circular(6),
                                  ),
                                  child: ClipRRect(
                                    borderRadius: BorderRadius.circular(6),
                                    child: ChannelLogo(
                                      url: channel.logo,
                                      fit: BoxFit.contain,
                                      fallbackBuilder: (_) => Icon(
                                        Icons.tv,
                                        color: isCurrent
                                            ? Colors.blue
                                            : Colors.white38,
                                        size: 16,
                                      ),
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 12),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        channel.name,
                                        style: TextStyle(
                                          color: isCurrent
                                              ? Colors.blue[300]
                                              : Colors.white,
                                          fontSize: 13,
                                          fontWeight: isCurrent
                                              ? FontWeight.w600
                                              : FontWeight.normal,
                                        ),
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                      if (channel.displayGroup != null)
                                        Text(
                                          channel.displayGroup!,
                                          style: const TextStyle(
                                              color: Colors.white38,
                                              fontSize: 10),
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                        ),
                                    ],
                                  ),
                                ),
                                if (isCurrent)
                                  const Icon(Icons.graphic_eq,
                                      color: Colors.blue, size: 16)
                                else
                                  Text(
                                    '${index + 1}',
                                    style: const TextStyle(
                                        color: Colors.white24, fontSize: 10),
                                  ),
                              ],
                            ),
                          ),
                        );
                      },
                    ),
                  ),
                ],
              ),
            )
          : const SizedBox.shrink(),
    );
  }

  /// Unified placeholder widget for both video loading and audio mode
  Widget _buildPlaceholder({
    required bool showControls,
    required bool isBuffering,
    required bool isPlaying,
    required VoidCallback onPlayPause,
    String? title,
    String? subtitle,
    String? hintText,
    double logoSize = 120,
  }) {
    // Spinner widget used for both video and audio buffering
    final spinner = const Center(
      child: SizedBox(
        width: 64,
        height: 64,
        child: CircularProgressIndicator(
          color: Colors.white54,
          strokeWidth: 2.5,
        ),
      ),
    );

    return Container(
      color: Colors.black,
      child: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              width: logoSize,
              height: logoSize,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(12),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.5),
                    blurRadius: 20,
                    spreadRadius: 5,
                  ),
                ],
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: ChannelLogo(
                  url: _proxyImageUrl(_currentChannel.logo),
                  fit: BoxFit.contain,
                  fallbackBuilder: (_) => Container(
                    color: Colors.white24,
                    child: Icon(
                      showControls ? Icons.headphones : Icons.live_tv,
                      size: logoSize * 0.5,
                      color: Colors.white54,
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 24),
            // Title slot - always present, empty string if null
            Text(
              title ?? '',
              style: const TextStyle(color: Colors.white70, fontSize: 20),
            ),
            const SizedBox(height: 8),
            // Subtitle slot - always present, empty string if null
            Text(
              subtitle ?? '',
              style: const TextStyle(color: Colors.white38),
            ),
            const SizedBox(height: 4),
            // Hint slot - always present, empty string if null
            Text(
              hintText ?? '',
              style: const TextStyle(color: Colors.white24, fontSize: 12),
            ),
            const SizedBox(height: 24),
            // Controls / spinner area
            SizedBox(
              width: 80,
              height: 80,
              child: showControls
                  ? isBuffering
                      ? spinner
                      : IconButton(
                          icon: Icon(
                            isPlaying
                                ? Icons.pause_circle_filled
                                : Icons.play_circle_filled,
                            size: 64,
                            color: Colors.white54,
                          ),
                          onPressed: onPlayPause,
                        )
                  : spinner,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildChannelLogoWidget() {
    return _buildPlaceholder(
      showControls: false,
      isBuffering: true,
      isPlaying: false,
      onPlayPause: () {}, // Not used in this mode
      title: null,
      subtitle: null,
      hintText: AppLocalizations.of(context)!.loadingStream,
      logoSize: 120,
    );
  }

  Widget _buildAudioPlaceholder() {
    debugPrint(
        '[PlayerPage] _buildAudioPlaceholder: _isBuffering=$_isBuffering, _isAudioModeActive=$_isAudioModeActive');
    return _buildPlaceholder(
      showControls: true,
      isBuffering: _isBuffering,
      isPlaying: _isPlaying,
      onPlayPause: _togglePlayPause,
      title: _currentChannel.name,
      subtitle: _isAudioModeActive
          ? AppLocalizations.of(context)!.nativeBackgroundAudio
          : AppLocalizations.of(context)!.audioOnlyMode,
      hintText: _isBuffering && !_isPlaying
          ? AppLocalizations.of(context)!.loadingStream
          : _isAudioModeActive
              ? AppLocalizations.of(context)!.notificationControlsHint
              : null,
      logoSize: 120,
    );
  }

  @override
  Widget build(BuildContext context) {
    final hasMenuItems = !kIsWeb;
    final hasMultipleChannels = _channels.length > 1;

    return Scaffold(
      backgroundColor: Colors.black,
      appBar: (_isInPipMode || _isFullscreen)
          ? null
          : AppBar(
              backgroundColor: Colors.black,
              foregroundColor: Colors.white,
              title: Row(
                children: [
                  if (_currentChannel.logo != null &&
                      _currentChannel.logo!.isNotEmpty)
                    ClipRRect(
                      borderRadius: BorderRadius.circular(4),
                      child: ChannelLogo(
                        url: _currentChannel.logo,
                        width: 28,
                        height: 28,
                        fallbackBuilder: (_) => const SizedBox.shrink(),
                      ),
                    ),
                  if (_currentChannel.logo != null &&
                      _currentChannel.logo!.isNotEmpty)
                    const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      _currentChannel.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
              actions: [
                // Audio-only lives here, not in the on-video overlay:
                // tapping it makes the video disappear, so a control hosted on
                // the video would vanish along with the thing it just turned
                // off, and the way back would have to live somewhere else. As
                // an AppBar icon it is the same button in the same place in
                // both directions — the AppBar stays visible in audio mode.
                //
                // Promoted out of the overflow menu, which held this as its
                // only entry: two taps for one action, on the app's most
                // distinctive feature. The menu is removed rather than left
                // wrapping nothing — re-add it once there is more than one
                // thing to put in it (the sleep timer).
                if (hasMenuItems)
                  IconButton(
                    onPressed: _toggleAudioOnlyMode,
                    icon: Icon(
                      _audioOnlyMode ? Icons.videocam : Icons.headphones,
                      color: Colors.white,
                    ),
                    tooltip: _audioOnlyMode
                        ? AppLocalizations.of(context)!.switchToVideo
                        : AppLocalizations.of(context)!.audioOnlyMode,
                  ),
              ],
            ),
      body: Column(
        children: [
          Expanded(
            // Black behind everything in the player area. Without it the
            // letterbox bars around a centred video showed the Scaffold's own
            // background, so the control scrim — which covers this whole box —
            // visibly extended past the picture onto page-coloured margins.
            // Black is what every other player does with that slack, and it
            // makes the scrim read as belonging to the video.
            child: ColoredBox(
              color: Colors.black,
              child: Stack(
              // Belt and braces, and honestly inert as things stand: the
              // `Center` in unified_video_player is what actually fixes the
              // alignment, and it makes this Stack fill its parent anyway, so
              // this line changes nothing today. Adding it alone did NOT fix
              // fullscreen — measured 0/420 either way. Kept so that removing
              // the `Center` cannot silently reintroduce a top-start layout,
              // not because it is doing the work.
              alignment: Alignment.center,
              children: [
                _buildBody(),
                if (!_audioOnlyMode && !_hasError)
                  Positioned.fill(
                    child: GestureDetector(
                      behavior: HitTestBehavior.translucent,
                      // Same detector for both, deliberately: Flutter then
                      // disambiguates them, so a genuine double-tap resolves to
                      // onDoubleTap alone instead of firing onTap first. Two
                      // detectors in separate layers would collide — see the
                      // note in exo_engine.dart's buildSurface.
                      onTap: _toggleControls,
                      onDoubleTap: _toggleFullscreen,
                      child: const SizedBox.expand(),
                    ),
                  ),
                // On-video control overlay. Sits ABOVE the gesture layer so its
                // buttons win the hit test, but the scrim inside is wrapped in
                // its own IgnorePointer so a tap on empty space still falls
                // through to the detector and hides the overlay again.
                //
                // Gated on `!_isInPipMode` so it cannot repeat the PiP leak
                // that moving the fullscreen button out of
                // `ExoEngine.buildSurface` fixed — that button was invisible to
                // PiP state and painted itself over the thumbnail.
                if (!_isInPipMode && !_audioOnlyMode && !_hasError)
                  Positioned.fill(
                    child: IgnorePointer(
                      ignoring: !_controlsVisible,
                      child: AnimatedOpacity(
                        opacity: _controlsVisible ? 1 : 0,
                        duration: const Duration(milliseconds: 180),
                        child: Stack(
                          children: [
                            const IgnorePointer(
                              child: ColoredBox(
                                color: Color(0x59000000),
                                child: SizedBox.expand(),
                              ),
                            ),
                            // A fixed 64px slot either way: swapping a spinner
                            // for the icon must not reflow the overlay, or a
                            // stream that rebuffers repeatedly makes the
                            // control jump under the thumb.
                            //
                            // While the engine is buffering there is nothing
                            // to pause and nothing to resume, so the button is
                            // replaced rather than disabled — the same
                            // treatment `_buildPlaceholder` already gives the
                            // audio-only surface. This covers mid-playback
                            // rebuffering too, not just the first load.
                            Center(
                              child: SizedBox(
                                width: 64,
                                height: 64,
                                child: _isVideoBuffering
                                    ? const CircularProgressIndicator(
                                        color: Colors.white54,
                                        strokeWidth: 2.5,
                                      )
                                    : IconButton(
                                        padding: EdgeInsets.zero,
                                        onPressed: () {
                                          _togglePlayPause();
                                          // Re-arm the countdown: the user is
                                          // still interacting, so the overlay
                                          // should not vanish mid-use.
                                          _showControls();
                                        },
                                        icon: Icon(_isPlaying
                                            ? Icons.pause_circle_filled
                                            : Icons.play_circle_filled),
                                        iconSize: 64,
                                        color: Colors.white,
                                        tooltip: _isPlaying
                                            ? AppLocalizations.of(context)!
                                                .pause
                                            : AppLocalizations.of(context)!
                                                .play,
                                      ),
                              ),
                            ),
                            // Fullscreen toggle, bottom-right in *both*
                            // directions (owner request): the control does not
                            // move under the thumb when the mode changes, so
                            // entering and leaving fullscreen is the same tap
                            // target twice.
                            //
                            // It belongs here rather than in the AppBar or the
                            // channel bar because in fullscreen the AppBar is
                            // null and that bar is skipped — either would leave
                            // the double-tap as the only way back out, and a
                            // gesture must never be the sole route to a
                            // control. That bar also renders only when
                            // hasMultipleChannels, so a single-channel playlist
                            // would have lost fullscreen entirely.
                            // Aspect toggle, fullscreen only. Two states, as
                            // asked: original (letterboxed, the stream's own
                            // shape) and fill (stretched to the screen). An
                            // explicit, visible, tappable control rather than a
                            // pinch or a double-tap cycle — the standing rule is
                            // that no gesture may perform an action.
                            //
                            // Left of the fullscreen button so that button stays
                            // put in the corner across both modes, which is the
                            // reason it is pinned there in the first place.
                            if (_isFullscreen)
                              Positioned(
                                right: 56,
                                bottom: 8,
                                child: SafeArea(
                                  child: IconButton(
                                    onPressed: () {
                                      final next = !_stretchToFill;
                                      setState(() => _stretchToFill = next);
                                      // This button is the only way to change
                                      // the preference, so it is also the only
                                      // place that writes it.
                                      unawaited(_persistStretchToFill(next));
                                      // The user is still interacting; do not
                                      // let the overlay vanish mid-comparison.
                                      _showControls();
                                    },
                                    icon: Icon(_stretchToFill
                                        ? Icons.fit_screen
                                        : Icons.aspect_ratio),
                                    iconSize: 32,
                                    color: Colors.white,
                                    tooltip: _stretchToFill
                                        ? AppLocalizations.of(context)!
                                            .originalSize
                                        : AppLocalizations.of(context)!
                                            .fillScreen,
                                  ),
                                ),
                              ),
                            Positioned(
                              right: 8,
                              bottom: 8,
                              child: SafeArea(
                                child: IconButton(
                                  onPressed: _toggleFullscreen,
                                  icon: Icon(_isFullscreen
                                      ? Icons.fullscreen_exit
                                      : Icons.fullscreen),
                                  iconSize: 32,
                                  color: Colors.white,
                                  tooltip: _isFullscreen
                                      ? AppLocalizations.of(context)!
                                          .exitFullscreen
                                      : AppLocalizations.of(context)!
                                          .fullscreen,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
              ],
            ),
            ),
          ),
          if (hasMultipleChannels && !_isInPipMode && !_isFullscreen) ...[
            _buildExpandableChannelList(),
            _buildChannelControls(context),
          ],
        ],
      ),
    );
  }

  Widget _buildChannelControls(BuildContext context) {
    return SafeArea(
      child: Container(
        color: Colors.black,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            IconButton(
              onPressed: _playPreviousChannel,
              icon: const Icon(Icons.skip_previous,
                  color: Colors.white, size: 32),
              tooltip: AppLocalizations.of(context)!.previousChannel,
            ),
            GestureDetector(
              onTap: _toggleChannelList,
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                decoration: BoxDecoration(
                  color: _channelListExpanded
                      ? Colors.blue.withValues(alpha: 0.25)
                      : Colors.white.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      _channelListExpanded
                          ? Icons.keyboard_arrow_down
                          : Icons.view_list,
                      color: Colors.white,
                      size: 16,
                    ),
                    const SizedBox(width: 6),
                    Text(
                      '${_currentIndex + 1} / ${_channels.length}',
                      style: const TextStyle(
                          color: Colors.white,
                          fontSize: 12,
                          fontWeight: FontWeight.w500),
                    ),
                  ],
                ),
              ),
            ),
            IconButton(
              onPressed: _playNextChannel,
              icon: const Icon(Icons.skip_next, color: Colors.white, size: 32),
              tooltip: AppLocalizations.of(context)!.nextChannel,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildBody() {
    if (_hasError) {
      return _buildError();
    }

    if (_audioOnlyMode) {
      return _buildAudioPlaceholder();
    }

    final videoPlayer = UnifiedVideoPlayer(
      key: _playerKey,
      url: _currentChannel.url,
      userAgent: _currentChannel.userAgent,
      channelName: _currentChannel.name,
      channelLogo: _currentChannel.logo,
      autoPlay: true,
      loadingWidget: kIsWeb ? null : _buildChannelLogoWidget(),
      // Gated on `_isFullscreen` so the windowed player cannot end up stretched
      // by a stale value, and on `!_isInPipMode` because PiP is a third context
      // that neither flag describes: `onUserLeaveHint` auto-enters PiP whenever
      // the app is backgrounded during eligible playback, without touching
      // `_isFullscreen` or `_stretchToFill`. The PiP window's own aspect is
      // hardcoded `Rational(16, 9)` in MainActivity, so a stretched surface
      // there distorts any channel that is not already 16:9. Leaving PiP
      // restores the user's choice rather than discarding it, which is why this
      // gates rather than resetting the flag.
      stretchToFill: _isFullscreen && _stretchToFill && !_isInPipMode,
      onPlayingChanged: (playing) {
        if (mounted && !_isAudioModeActive && _isPlaying != playing) {
          setState(() {
            _isPlaying = playing;
          });
          _syncWakelock();
        }
      },
      onBufferingChanged: (buffering) {
        if (mounted && _isVideoBuffering != buffering) {
          debugPrint('[PlayerPage] _isVideoBuffering -> $buffering');
          setState(() => _isVideoBuffering = buffering);
        }
      },
      onError: (error) {
        if (!mounted) return;
        // Leave fullscreen before showing the error. While `_isFullscreen` the
        // AppBar is null, and `_buildError()` replaces the video entirely —
        // taking the overlay fullscreen button and the double-tap detector
        // with it, since both are gated on `!_hasError`. Without this, an
        // error raised while fullscreen leaves *no* on-screen route out of
        // fullscreen at all: not a button, not even the gesture. There is no
        // `PopScope` either, so Android back would pop the whole page rather
        // than return to windowed playback.
        //
        // Exiting is the right fix rather than un-gating the button: an error
        // screen has no video to watch, so immersive landscape is wrong for it
        // regardless. This predates the fullscreen-ownership change but that
        // change is what made guaranteed escapability the rule, so it is fixed
        // here rather than left as a known gap.
        if (_isFullscreen) _exitFullscreen();
        setState(() {
          _hasError = true;
          _errorMessage = error ?? AppLocalizations.of(context)!.unknownError;
        });
        // The reported bug: without this, backgrounding here pins the error
        // screen into the PiP window, where its layout also overflows.
        _syncDerivedPlaybackState();
      },
    );

    return videoPlayer;
  }

  String _proxyImageUrl(String? url) {
    if (url == null || url.isEmpty) return '';
    if (kIsWeb) {
      return 'https://images.weserv.nl/?url=${Uri.encodeComponent(url)}&w=200&h=200&fit=contain';
    }
    return url;
  }

  // COUPLING NOTE: this string-matches the *output* of
  // `unified_video_player.dart`'s `_friendlyError()` and `_surfaceError()`.
  //
  // There is no `errorCodeName` matching and never was — an earlier version
  // of this note claimed `_friendlyError()` classified "ExoPlayer/Media3
  // `errorCodeName`-shaped errors", which was wrong and contradicted that
  // method's own comment. Media3 surfaces every HTTP failure as the literal
  // string "Source error" with no code in it, so on Android the specific
  // message comes from `_surfaceError()`'s `StreamDiagnostics` probe instead,
  // which re-requests the URL and reads the real status.
  //
  // Both of those produce the same fixed set of message strings on purpose,
  // so this icon mapping needs no engine-aware branch. If either one's
  // wording changes, the `contains()` checks below must change to match —
  // see the matching notes there.
  IconData _errorIcon() {
    final msg = _errorMessage.toLowerCase();
    if (msg.contains('timed out') || msg.contains('not responding'))
      return Icons.timer_off_outlined;
    if (msg.contains('network') || msg.contains('connection'))
      return Icons.wifi_off_outlined;
    if (msg.contains('not found') || msg.contains('404')) return Icons.link_off;
    if (msg.contains('access denied') || msg.contains('40'))
      return Icons.lock_outline;
    if (msg.contains('format') || msg.contains('codec'))
      return Icons.videocam_off_outlined;
    return Icons.error_outline;
  }

  Widget _buildError() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24.0),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(_errorIcon(), size: 64, color: Colors.red),
            const SizedBox(height: 16),
            Text(
              AppLocalizations.of(context)!.failedToLoadStream,
              style: const TextStyle(color: Colors.white, fontSize: 18),
            ),
            const SizedBox(height: 8),
            Text(
              _errorMessage,
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.white70, fontSize: 12),
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
            ),
            const SizedBox(height: 24),
            ElevatedButton.icon(
              onPressed: () {
                setState(() {
                  _hasError = false;
                  _errorMessage = '';
                });
                _syncDerivedPlaybackState();
                // `_buildBody()` returns `_buildError()` while `_hasError` is
                // set, so the player is NOT in the tree here and
                // `currentState` is null — this call is a no-op today. What
                // actually restarts playback is the `setState` above: clearing
                // `_hasError` remounts `UnifiedVideoPlayer`, whose `initState`
                // reloads from scratch.
                //
                // The call is kept rather than deleted because it is the live
                // path the moment anyone keeps the player mounted behind an
                // error overlay instead of replacing it — at which point the
                // remount stops happening and this becomes the only thing that
                // reloads. Deleting it would make that future change silently
                // break Retry.
                _playerKey.currentState?.retry();
              },
              icon: const Icon(Icons.refresh),
              label: Text(AppLocalizations.of(context)!.retry),
            ),
          ],
        ),
      ),
    );
  }
}
