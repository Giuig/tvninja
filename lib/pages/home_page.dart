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
                : GridView.builder(
                    // 16 matches the "Preferiti" heading's own indent. At 4 the
                    // cards sat ~4px off the screen edge while the heading above
                    // them was indented 16, so the grid did not line up with its
                    // own title.
                    padding: const EdgeInsets.all(16),
                    // Max extent, not a fixed count: the tile keeps a constant
                    // size at every width and the delegate derives how many
                    // fit. The old breakpoint ladder (12/10/8/5/3 columns) did
                    // the opposite of what it should — it made tiles *smaller*
                    // as the screen grew: ~125px cells at 393 logical but only
                    // ~101px at 1067. More room should buy comfortable tiles,
                    // not more, tinier ones.
                    //
                    // 112, down from 130. This is a favourites shortcut grid,
                    // and at 130 seven favourites did not fit a phone screen —
                    // the last row needed a scroll to read its label. 112 puts
                    // phone portrait on 4 columns (~87px tiles), so seven fit in
                    // two rows with nothing hidden. Tablet landscape goes from 8
                    // columns to 10, at ~100px — still flat across widths, which
                    // is the property the max-extent delegate exists to give;
                    // the old ladder inverted it (~101px at 1067 vs ~125px at
                    // 393).
                    gridDelegate:
                        const SliverGridDelegateWithMaxCrossAxisExtent(
                      // 104, retuned after the spacing went to 12. The two are
                      // not independent: the delegate computes
                      // `ceil(width / (maxExtent + spacing))`, so at 393 logical
                      // 112+8 gave four columns by a hair (ceil(361/120) = 4) and
                      // 112+12 silently dropped to three, which put the seventh
                      // favourite back under the nav bar. 104+12 holds four, and
                      // tablet landscape sits at nine ~104px tiles — so tile size
                      // stays flat across widths, which is the whole point of a
                      // max-extent delegate.
                      maxCrossAxisExtent: 104,
                      // 12, up from 4, and chosen to beat the 8px of padding
                      // *inside* each card (2 on the card + 6 around the logo).
                      // Below that inset a tile holds more whitespace than
                      // separates it from its neighbour, so a row reads as one
                      // block rather than separate tappable cards — proximity is
                      // what groups things, so the gap that divides has to win
                      // against the gap that belongs to a card. 8 was tried on
                      // the way here and is exactly the tie.
                      //
                      // It also lands inside the app's own rhythm rather than
                      // under it: playlist_page's channel cards carry
                      // `margin: symmetric(vertical: 4, horizontal: 8)`, so they
                      // sit 8px apart stacked but 16px apart side by side. A
                      // grid has neighbours on four sides, so the horizontal
                      // figure is the one that applies — an earlier revision of
                      // this comment cited the 8 and picked it, which is the
                      // list case, not this one.
                      mainAxisSpacing: 12,
                      crossAxisSpacing: 12,
                    ),
                    itemCount: favorites.length,
                    itemBuilder: (context, index) {
                      return _FavoriteCard(channel: favorites[index]);
                    },
                  ),
          ),
        ],
      ),
    );
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

    // Measure the cell we were actually given rather than re-deriving it from
    // the screen. The old code recomputed the column count from
    // MediaQuery screen width and guessed a cell width with hardcoded padding
    // maths that did not even match the grid's real values — two independent
    // derivations of the same number, from different inputs. They agreed only
    // because the grid happened to span the whole screen, and would diverge
    // the moment anything sits beside it (a NavigationRail, a split view),
    // leaving the card sized for a cell that does not exist.
    return LayoutBuilder(builder: (context, constraints) {
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
              // A square box every logo shares, rather than letting each one
              // size itself. BoxFit.contain fills whichever axis binds first,
              // so a wide logo (Rai 1/2/3) hit the width and bled to the card
              // edge while a round or diamond one (Rete 4, Italia 1) hit the
              // height and sat in whitespace — identical cards with very
              // different optical weight. Now shape changes what is inside the
              // box, not how much room the logo takes.
              Expanded(
                child: Center(
                  child: AspectRatio(
                    aspectRatio: 1,
                    child: Padding(
                      padding: const EdgeInsets.all(6),
                      child: ChannelLogo(
                        url: channel.logo,
                        fit: BoxFit.contain,
                        fallbackBuilder: (_) => _buildDefaultLogo(theme),
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 1),
              Text(channel.name,
                  // Was fontSize: (logoSize * 0.25).clamp(7.0, 9.0) — a 7-9px
                  // label, well under any legibility floor, and derived from
                  // the cell maths removed above. bodySmall (~12) is safe here
                  // because the logo sits in an Expanded and simply yields
                  // space as the label grows with the user's font scale.
                  style: theme.textTheme.bodySmall?.copyWith(
                    fontWeight: FontWeight.w500,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.center),
            ],
          ),
          ),
        ),
      );
    });
  }

  /// Fills whatever box it is given rather than taking a size.
  ///
  /// It used to be drawn at `(cellWidth * 0.35).clamp(20, 36)` while a real
  /// logo rendered at roughly the full cell — so a channel whose logo failed to
  /// load showed a ~36px icon beside neighbours three times its size, in the
  /// same grid. Sharing the caller's square box keeps both states the same size.
  Widget _buildDefaultLogo(ThemeData theme) {
    return LayoutBuilder(builder: (context, constraints) {
      final side = constraints.biggest.shortestSide;
      return Container(
        decoration: BoxDecoration(
          color: theme.colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Icon(Icons.tv,
            size: side * 0.6, color: theme.colorScheme.onSurfaceVariant),
      );
    });
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
    if (!context.mounted) return;
    // Root navigator, not the tab's own: a plain push here would land the
    // player inside the tab, under FirstPage's bottom nav bar, instead of
    // covering it — see the nested-tab-navigation plan.
    Navigator.of(context, rootNavigator: true).push(
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
