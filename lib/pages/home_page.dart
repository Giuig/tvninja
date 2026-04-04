import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:tvninja/config/config.dart';
import 'package:tvninja/l10n/app_localizations.dart';
import 'package:tvninja/pages/player_page.dart';
import 'package:tvninja/services/native_audio_service.dart';
import 'package:tvninja/widgets/channel_logo.dart';

class HomePage extends StatelessWidget {
  const HomePage({super.key});

  @override
  Widget build(BuildContext context) {
    final isLoading =
        context.select<AppStatsNotifier, bool>((n) => n.isLoading);
    final l10n = AppLocalizations.of(context)!;

    if (isLoading) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    final stats = context.watch<AppStatsNotifier>();
    final favorites = stats.favoriteChannels;

    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.favorites),
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceAround,
              children: [
                _StatItem(
                    icon: Icons.playlist_play,
                    value: stats.playlists.length,
                    label: l10n.playlists),
                _StatItem(
                    icon: Icons.tv,
                    value: stats.allChannels.length,
                    label: l10n.channels),
                _StatItem(
                    icon: Icons.favorite,
                    value: favorites.length,
                    label: l10n.favorites),
              ],
            ),
          ),
          Expanded(
            child: favorites.isEmpty
                ? Center(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(Icons.favorite_border,
                            size: 80,
                            color: Theme.of(context).colorScheme.outline),
                        const SizedBox(height: 16),
                        Text(l10n.noFavorites,
                            style: Theme.of(context).textTheme.headlineSmall),
                        const SizedBox(height: 8),
                        Text(l10n.addFavoritesHint,
                            style: TextStyle(
                                color: Theme.of(context).colorScheme.outline),
                            textAlign: TextAlign.center),
                      ],
                    ),
                  )
                : LayoutBuilder(
                    builder: (context, constraints) {
                      final crossAxisCount =
                          _getCrossAxisCount(constraints.maxWidth);
                      return GridView.builder(
                        padding: const EdgeInsets.all(4),
                        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                          crossAxisCount: crossAxisCount,
                          mainAxisSpacing: 4,
                          crossAxisSpacing: 4,
                        ),
                        itemCount: favorites.length,
                        itemBuilder: (context, index) {
                          return _FavoriteCard(channel: favorites[index]);
                        },
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }

  int _getCrossAxisCount(double width) {
    if (width >= 1200) return 12;
    if (width >= 900) return 10;
    if (width >= 600) return 8;
    if (width >= 400) return 5;
    return 3;
  }
}

class _StatItem extends StatelessWidget {
  final IconData icon;
  final int value;
  final String label;
  const _StatItem(
      {required this.icon, required this.value, required this.label});

  @override
  Widget build(BuildContext context) {
    return Column(children: [
      Icon(icon, size: 18),
      Text('$value',
          style: const TextStyle(fontSize: 14, fontWeight: FontWeight.bold)),
      Text(label,
          style: TextStyle(
              fontSize: 10, color: Theme.of(context).colorScheme.outline)),
    ]);
  }
}

class _FavoriteCard extends StatelessWidget {
  final Channel channel;
  const _FavoriteCard({required this.channel});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    // Get available height and calculate appropriate logo size
    final screenWidth = MediaQuery.of(context).size.width;
    final crossAxisCount = _getCrossAxisCount(screenWidth);
    final cellWidth =
        (screenWidth - 16 - (crossAxisCount - 1) * 8) / crossAxisCount;
    final logoSize = (cellWidth * 0.35).clamp(20.0, 36.0);

    return Card(
      clipBehavior: Clip.antiAlias,
      margin: EdgeInsets.zero,
      child: InkWell(
        onTap: () => _playChannel(context),
        onLongPress: () => _showRemoveDialog(context),
        child: Padding(
          padding: const EdgeInsets.all(2),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Expanded(
                child: ChannelLogo(
                  url: channel.logo,
                  fit: BoxFit.contain,
                  fallbackBuilder: (_) => _buildDefaultLogo(theme, logoSize),
                ),
              ),
              const SizedBox(height: 1),
              Text(channel.name,
                  style: theme.textTheme.bodySmall?.copyWith(
                    fontWeight: FontWeight.w500,
                    fontSize: (logoSize * 0.25).clamp(7.0, 9.0),
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.center),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildDefaultLogo(ThemeData theme, double logoSize) {
    return Center(
      child: Container(
        width: logoSize,
        height: logoSize,
        decoration: BoxDecoration(
          color: theme.colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Icon(Icons.tv,
            size: logoSize * 0.6, color: theme.colorScheme.onSurfaceVariant),
      ),
    );
  }

  int _getCrossAxisCount(double width) {
    if (width >= 1200) return 12;
    if (width >= 900) return 10;
    if (width >= 600) return 8;
    if (width >= 400) return 5;
    return 3;
  }

  Future<void> _playChannel(BuildContext context) async {
    final stats = context.read<AppStatsNotifier>();
    stats.addToRecentlyWatched(channel);
    final currentUrl = NativeAudioService.currentUrl;
    final isAudioPlaying = NativeAudioService.currentState.isPlaying ||
        NativeAudioService.isBuffering;
    final shouldStartInAudioOnly =
        currentUrl != null && currentUrl == channel.url && isAudioPlaying;
    if (currentUrl != null && currentUrl != channel.url) {
      await NativeAudioService.stop();
    }
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => PlayerPage(
          channel: channel,
          channels: stats.favoriteChannels,
          initialIndex: stats.favoriteChannels.indexOf(channel),
          initialAudioOnly: shouldStartInAudioOnly,
        ),
      ),
    );
  }

  void _showRemoveDialog(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(l10n.removeFromFavorites),
        content: Text(l10n.removeFromFavoritesDetail(channel.name)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(l10n.cancel),
          ),
          TextButton(
            onPressed: () {
              context.read<AppStatsNotifier>().toggleFavorite(channel);
              Navigator.pop(ctx);
            },
            child: Text(l10n.remove, style: const TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
  }
}
