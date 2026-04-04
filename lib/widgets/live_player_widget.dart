import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:tvninja/config/config.dart';
import 'package:tvninja/l10n/app_localizations.dart';
import 'package:tvninja/services/live_player_notifier.dart';
import 'package:tvninja/services/video/web_video_player.dart';

class LivePlayerWidget extends StatefulWidget {
  const LivePlayerWidget({super.key});

  @override
  State<LivePlayerWidget> createState() => _LivePlayerWidgetState();
}

class _LivePlayerWidgetState extends State<LivePlayerWidget> {
  final GlobalKey _webPlayerKey = GlobalKey();

  @override
  void initState() {
    super.initState();
    if (kIsWeb) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        final player = context.read<LivePlayerNotifier>();
        player.setPiPCallback(() {
          final state = _webPlayerKey.currentState;
          if (state != null) {
            (state as dynamic).requestPiP();
          }
        });
        player.addListener(_onPlayerChanged);
      });
    }
  }

  bool _lastModalOverlay = false;

  void _onPlayerChanged() {
    if (!kIsWeb) return;
    final player = context.read<LivePlayerNotifier>();
    if (player.hasModalOverlay != _lastModalOverlay) {
      _lastModalOverlay = player.hasModalOverlay;
      final state = _webPlayerKey.currentState;
      if (state != null) {
        (state as dynamic).setVisible(!_lastModalOverlay);
      }
    }
  }

  @override
  void dispose() {
    if (kIsWeb && mounted) {
      try {
        context.read<LivePlayerNotifier>().removeListener(_onPlayerChanged);
      } catch (_) {
        // Ignore if context is no longer valid
      }
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<LivePlayerNotifier>(
      builder: (context, player, child) {
        if (!player.hasActivePlayer || !player.showPlayer) {
          return const SizedBox.shrink();
        }

        // Expanded/fullscreen mode - works on all platforms now
        if (player.isExpanded) {
          return _buildExpandedPlayer(context, player);
        }

        return _buildCompactPlayer(context, player);
      },
    );
  }

  Widget _buildCompactPlayer(BuildContext context, LivePlayerNotifier player) {
    return ClipRect(
      child: Container(
        color: Colors.black,
        child: Stack(
          children: [
            // Loading when switching to audio-only
            if (player.isSwitchingToAudio)
              _buildSwitchingToAudioView(player)
            // Audio-only view
            else if (player.isAudioOnly)
              _buildAudioOnlyView(context, player)
            // Web player - iframe handles its own loading
            else if (kIsWeb)
              WebVideoPlayerWidget(
                key: _webPlayerKey,
                url: player.currentChannel?.url ?? '',
                channelName: player.currentChannel?.name ?? '',
                channelLogo: player.currentChannel?.logo,
                autoPlay: true,
                onPlayingChanged: (playing) {
                  player.isPlaying = playing;
                },
                onClose: () {
                  player.stop();
                },
              )
            else if (player.isInitialized && player.videoController != null)
              Video(
                controller: player.videoController!,
                controls: NoVideoControls,
              )
            else if (player.hasError)
              _buildError(player)
            // Only show Flutter loading on Android, web iframe handles its own
            else if (!kIsWeb)
              _buildLoading(player),

            // Channel info overlay with controls — only rebuilds on channel change
            if (!player.isAudioOnly && !player.isSwitchingToAudio)
              Selector<LivePlayerNotifier, Channel?>(
                selector: (_, p) => p.currentChannel,
                builder: (context, _, __) =>
                    _buildChannelInfo(context, context.read<LivePlayerNotifier>()),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildSwitchingToAudioView(LivePlayerNotifier player) {
    return Container(
      color: Colors.black,
      child: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const SizedBox(
              width: 32,
              height: 32,
              child: CircularProgressIndicator(
                color: Colors.white,
                strokeWidth: 3,
              ),
            ),
            const SizedBox(height: 16),
            Text(
              AppLocalizations.of(context)!.switchingToAudio,
              style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.8), fontSize: 14),
            ),
            const SizedBox(height: 4),
            Text(
              player.currentChannel?.name ?? '',
              style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.6), fontSize: 12),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildAudioOnlyView(BuildContext context, LivePlayerNotifier player) {
    return Container(
      color: Colors.black,
      child: Stack(
        children: [
          Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                if (player.currentChannel?.logo != null &&
                    player.currentChannel!.logo!.isNotEmpty)
                  ClipRRect(
                    borderRadius: BorderRadius.circular(12),
                    child: Image.network(
                      player.currentChannel!.logo!,
                      width: 80,
                      height: 80,
                      errorBuilder: (_, __, ___) => const Icon(Icons.music_note,
                          color: Colors.white54, size: 48),
                    ),
                  )
                else
                  const Icon(Icons.music_note, color: Colors.white54, size: 48),
                const SizedBox(height: 16),
                Text(
                  player.currentChannel?.name ?? '',
                  style: const TextStyle(color: Colors.white, fontSize: 14),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 8),
                Text(
                  AppLocalizations.of(context)!.audioOnly,
                  style: TextStyle(
                      color: Colors.white.withValues(alpha: 0.6), fontSize: 12),
                ),
                const SizedBox(height: 16),
                SizedBox(
                  width: 56,
                  height: 56,
                  child: (player.isBuffering || player.isSwitchingToAudio)
                      ? const Padding(
                          padding: EdgeInsets.all(8),
                          child: CircularProgressIndicator(
                            color: Colors.white54,
                            strokeWidth: 2.5,
                          ),
                        )
                      : IconButton(
                          icon: Icon(
                            player.isPlaying ? Icons.pause : Icons.play_arrow,
                            color: Colors.white,
                            size: 40,
                          ),
                          onPressed: () => player.togglePlayPause(),
                        ),
                ),
              ],
            ),
          ),
          // Top bar with controls for audio-only mode (Android only)
          if (!kIsWeb)
            SafeArea(
              child: Align(
                alignment: Alignment.topRight,
                child: Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      // Switch to video button
                      GestureDetector(
                        onTap: () => player.toggleAudioOnly(),
                        child: Container(
                          padding: const EdgeInsets.all(6),
                          margin: const EdgeInsets.only(right: 8),
                          decoration: BoxDecoration(
                            color: Colors.black.withValues(alpha: 0.5),
                            shape: BoxShape.circle,
                          ),
                          child: const Icon(Icons.videocam,
                              color: Colors.white, size: 16),
                        ),
                      ),
                      // Close button
                      GestureDetector(
                        onTap: () => player.stop(),
                        child: Container(
                          padding: const EdgeInsets.all(6),
                          decoration: BoxDecoration(
                            color: Colors.black.withValues(alpha: 0.5),
                            shape: BoxShape.circle,
                          ),
                          child: const Icon(Icons.close,
                              color: Colors.white, size: 16),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildExpandedPlayer(BuildContext context, LivePlayerNotifier player) {
    return Positioned.fill(
      child: Scaffold(
        backgroundColor: Colors.black,
        body: Stack(
          children: [
            if (player.isInitialized && player.videoController != null)
              Center(
                child: Video(
                  controller: player.videoController!,
                  controls: MaterialVideoControls,
                ),
              )
            else if (player.hasError)
              _buildError(player)
            else
              _buildLoading(player),

            // Top bar
            SafeArea(
              child: Align(
                alignment: Alignment.topLeft,
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Row(
                    children: [
                      IconButton(
                        icon: const Icon(Icons.arrow_back, color: Colors.white),
                        onPressed: () => player.minimize(),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          player.currentChannel?.name ?? '',
                          style: const TextStyle(
                              color: Colors.white, fontSize: 18),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      // Audio only toggle
                      IconButton(
                        icon: Icon(
                          player.isAudioOnly
                              ? Icons.videocam
                              : Icons.headphones,
                          color: Colors.white,
                        ),
                        onPressed: () => player.toggleAudioOnly(),
                      ),
                      // Close button
                      IconButton(
                        icon: const Icon(Icons.close, color: Colors.white),
                        onPressed: () => player.stop(),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildChannelInfo(BuildContext context, LivePlayerNotifier player) {
    // Web iframe has its own channel header and close button
    if (kIsWeb) return const SizedBox.shrink();

    return Positioned(
      top: 0,
      left: 0,
      right: 0,
      child: SafeArea(
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [
                Colors.black.withValues(alpha: 0.8),
                Colors.transparent,
              ],
            ),
          ),
          child: Row(
            children: [
              if (player.currentChannel?.logo != null &&
                  player.currentChannel!.logo!.isNotEmpty)
                ClipRRect(
                  borderRadius: BorderRadius.circular(4),
                  child: Image.network(
                    player.currentChannel!.logo!,
                    width: 28,
                    height: 28,
                    errorBuilder: (_, __, ___) =>
                        const Icon(Icons.tv, color: Colors.white, size: 20),
                  ),
                )
              else
                const Icon(Icons.tv, color: Colors.white, size: 20),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  player.currentChannel?.name ?? '',
                  style: const TextStyle(
                      color: Colors.white,
                      fontSize: 13,
                      fontWeight: FontWeight.w500),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              // Audio only toggle button (Android only)
              if (!kIsWeb)
                GestureDetector(
                  onTap: () => player.toggleAudioOnly(),
                  child: Container(
                    padding: const EdgeInsets.all(6),
                    margin: const EdgeInsets.only(right: 8),
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: 0.5),
                      shape: BoxShape.circle,
                    ),
                    child: Icon(
                      player.isAudioOnly ? Icons.videocam : Icons.headphones,
                      color: Colors.white,
                      size: 16,
                    ),
                  ),
                ),
              // Close button (Android only - web has it inside iframe)
              if (!kIsWeb)
                GestureDetector(
                  onTap: () => player.stop(),
                  child: Container(
                    padding: const EdgeInsets.all(6),
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: 0.5),
                      shape: BoxShape.circle,
                    ),
                    child:
                        const Icon(Icons.close, color: Colors.white, size: 16),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildLoading(LivePlayerNotifier player) {
    return Container(
      color: Colors.black,
      child: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            if (player.currentChannel?.logo != null &&
                player.currentChannel!.logo!.isNotEmpty)
              ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: Image.network(
                  player.currentChannel!.logo!,
                  width: 80,
                  height: 80,
                  errorBuilder: (_, __, ___) =>
                      const Icon(Icons.tv, color: Colors.white54, size: 48),
                ),
              )
            else
              const Icon(Icons.tv, color: Colors.white54, size: 48),
            const SizedBox(height: 16),
            const SizedBox(
              width: 32,
              height: 32,
              child: CircularProgressIndicator(
                color: Colors.white,
                strokeWidth: 3,
              ),
            ),
            const SizedBox(height: 12),
            Text(
              player.currentChannel?.name ??
                  AppLocalizations.of(context)!.loading,
              style: const TextStyle(color: Colors.white70, fontSize: 12),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildError(LivePlayerNotifier player) {
    return Container(
      color: Colors.black,
      child: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.error_outline, color: Colors.red, size: 40),
            const SizedBox(height: 8),
            Text(
              AppLocalizations.of(context)!.failedToLoad,
              style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.7), fontSize: 12),
            ),
            const SizedBox(height: 4),
            Text(
              player.errorMessage,
              style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.5), fontSize: 10),
              textAlign: TextAlign.center,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ),
      ),
    );
  }
}
