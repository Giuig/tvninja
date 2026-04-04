import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
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
  bool _isFullscreen = false;
  Orientation? _previousOrientation;

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

    _initializePlayer();
    _initializeNativeAudio();
    _listenToPipState();
    PipService.setFullscreenVideoMode(true);

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
    _previousOrientation = MediaQuery.of(context).orientation;
    setState(() => _isFullscreen = true);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    if (!kIsWeb) {
      SystemChrome.setPreferredOrientations([
        DeviceOrientation.landscapeLeft,
        DeviceOrientation.landscapeRight,
      ]);
    }
    WakelockPlus.enable();
  }

  void _exitFullscreen() {
    setState(() => _isFullscreen = false);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    if (!kIsWeb) {
      // Restore previous orientation if known
      if (_previousOrientation == Orientation.landscape) {
        SystemChrome.setPreferredOrientations([
          DeviceOrientation.landscapeLeft,
          DeviceOrientation.landscapeRight,
        ]);
      } else {
        // Default to portrait if previous orientation unknown or portrait
        SystemChrome.setPreferredOrientations([
          DeviceOrientation.portraitUp,
        ]);
      }
    }
    WakelockPlus.disable();
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
    PipService.setFullscreenVideoMode(false);
    if (_isFullscreen) {
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
      WakelockPlus.disable();
      // Restore previous orientation if we're disposing while still in fullscreen
      if (!kIsWeb && _previousOrientation != null) {
        if (_previousOrientation == Orientation.landscape) {
          SystemChrome.setPreferredOrientations([
            DeviceOrientation.landscapeLeft,
            DeviceOrientation.landscapeRight,
          ]);
        } else {
          SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
        }
      }
    }
    // No forced orientation change when leaving the page normally
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

  Future<void> _enableAudioMode() async {
    if (kIsWeb) {
      setState(() {
        _audioOnlyMode = true;
      });
      return;
    }

    try {
      await _playerKey.currentState?.stop();
      // Show the audio placeholder with spinner immediately — before play() is
      // called — so the user sees loading feedback from the very first frame.
      // Also disable PiP: pressing home in audio-only mode should background
      // the app normally, not enter picture-in-picture.
      PipService.setFullscreenVideoMode(false);
      setState(() {
        _audioOnlyMode = true;
        _isBuffering = true;
      });

      final success = await NativeAudioService.play(
        url: _currentChannel.url,
        title: _currentChannel.name,
        logo: _currentChannel.logo,
      );

      if (success) {
        setState(() => _isAudioModeActive = true);
      } else {
        setState(() {
          _audioOnlyMode = false;
          _isBuffering = false;
        });
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

    PipService.setFullscreenVideoMode(true);

    try {
      _playerKey.currentState?.play();
    } catch (_) {}

    setState(() {
      _audioOnlyMode = false;
    });
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
    });
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
    });
    context.read<AppStatsNotifier>().addToRecentlyWatched(_currentChannel);
    _switchAudioChannelIfNeeded();
  }

  void _toggleChannelList() {
    setState(() => _channelListExpanded = !_channelListExpanded);
  }

  void _selectChannel(int index) {
    setState(() {
      _channelListExpanded = false;
      _currentIndex = index;
      _currentChannel = _channels[index];
      _hasError = false;
      _errorMessage = '';
    });
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
                      itemCount: _channels.length,
                      itemBuilder: (context, index) {
                        final channel = _channels[index];
                        final isCurrent = channel.url == _currentChannel.url;
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
                                      if (channel.group != null)
                                        Text(
                                          channel.group!,
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
                if (hasMenuItems)
                  PopupMenuButton<String>(
                    icon: const Icon(Icons.more_vert, color: Colors.white),
                    onSelected: (value) {
                      if (value == 'audio') {
                        _toggleAudioOnlyMode();
                      }
                    },
                    itemBuilder: (context) => [
                      PopupMenuItem(
                        value: 'audio',
                        child: Row(
                          children: [
                            Icon(
                                _audioOnlyMode
                                    ? Icons.videocam
                                    : Icons.headphones,
                                size: 20),
                            const SizedBox(width: 12),
                            Text(_audioOnlyMode
                                ? AppLocalizations.of(context)!.switchToVideo
                                : AppLocalizations.of(context)!.audioOnlyMode),
                          ],
                        ),
                      ),
                    ],
                  ),
              ],
            ),
      body: Column(
        children: [
          Expanded(
            child: Stack(
              children: [
                _buildBody(),
                if (!_audioOnlyMode && !_hasError)
                  Positioned.fill(
                    child: GestureDetector(
                      behavior: HitTestBehavior.translucent,
                      onDoubleTap: _toggleFullscreen,
                      child: const SizedBox.expand(),
                    ),
                  ),
              ],
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
      channelName: _currentChannel.name,
      channelLogo: _currentChannel.logo,
      autoPlay: true,
      loadingWidget: kIsWeb ? null : _buildChannelLogoWidget(),
      onPlayingChanged: (playing) {
        if (mounted && !_isAudioModeActive && _isPlaying != playing) {
          setState(() {
            _isPlaying = playing;
          });
        }
      },
      onError: (error) {
        if (mounted) {
          setState(() {
            _hasError = true;
            _errorMessage = error ?? AppLocalizations.of(context)!.unknownError;
          });
        }
      },
      onToggleFullscreen: _toggleFullscreen,
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
                _initializePlayer();
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
