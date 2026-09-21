import 'dart:async';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:tvninja/config/config.dart';
import 'package:tvninja/l10n/app_localizations.dart';
import 'package:tvninja/pages/player_page.dart';
import 'package:tvninja/services/native_audio_service.dart';
import 'package:tvninja/widgets/channel_logo.dart';

/// One playlist's channel list, pushed as a real route.
///
/// This used to be a field (`_selectedPlaylist`) on `PlaylistPage`, swapped
/// in and out of the same single route — which is why the system back button
/// used to exit the app instead of returning to the playlist list: there was
/// only ever one route to pop. Making it a page gives back button something
/// real to act on.
///
/// Takes the playlist **id**, not a [Playlist] snapshot, and re-reads the
/// live object from [AppStatsNotifier] on every build. That is what removes
/// the two hand-written re-syncs `PlaylistPage` used to need: a snapshot
/// passed at push time would go stale the moment the playlist is refreshed
/// (new channel list) or deleted, from this page or from the list page's own
/// menu.
class ChannelListPage extends StatefulWidget {
  final String playlistId;

  const ChannelListPage({super.key, required this.playlistId});

  @override
  State<ChannelListPage> createState() => _ChannelListPageState();
}

class _ChannelListPageState extends State<ChannelListPage> {
  final _searchController = TextEditingController();
  String _searchQuery = '';
  String? _selectedGroup;
  Timer? _debounceTimer;

  @override
  void dispose() {
    _searchController.dispose();
    _debounceTimer?.cancel();
    super.dispose();
  }

  void _onSearchChanged(String value) {
    _debounceTimer?.cancel();
    _debounceTimer = Timer(const Duration(milliseconds: 300), () {
      if (mounted) {
        setState(() => _searchQuery = value);
      }
    });
  }

  List<Channel> _getFilteredChannels(List<Channel> channels) {
    var filtered = channels;

    if (_selectedGroup != null && _selectedGroup!.isNotEmpty) {
      filtered = filtered
          .where((c) =>
              c.displayGroup?.toLowerCase() == _selectedGroup!.toLowerCase())
          .toList();
    }

    if (_searchQuery.isNotEmpty) {
      final query = _searchQuery.toLowerCase();
      filtered =
          filtered.where((c) => c.name.toLowerCase().contains(query)).toList();
    }

    return filtered;
  }

  Set<String> _getGroups(List<Channel> channels) {
    return channels
        .where((c) => c.displayGroup != null)
        .map((c) => c.displayGroup!)
        .toSet();
  }

  Playlist? _findPlaylist(AppStatsNotifier stats) {
    for (final p in stats.playlists) {
      if (p.id == widget.playlistId) return p;
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final stats = context.watch<AppStatsNotifier>();
    final playlist = _findPlaylist(stats);

    if (playlist == null) {
      // Deleted from another surface (this page's own menu doesn't have one,
      // but the playlist list's `_showPlaylistMenu` does) while this page was
      // still open. Nothing left to show for it — pop back to the list, the
      // same thing `_clearSelection()` used to do for this case.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && Navigator.of(context).canPop()) {
          Navigator.of(context).pop();
        }
      });
      return const Scaffold(body: SizedBox.shrink());
    }

    return Scaffold(
      appBar: AppBar(title: Text(playlist.name)),
      body: _buildChannelsList(playlist, stats.favoriteChannelIds),
    );
  }

  Widget _buildChannelsList(Playlist playlist, Set<String> favoriteIds) {
    final allChannels = playlist.channels;
    final groups = _getGroups(allChannels);
    final filteredChannels = _getFilteredChannels(allChannels);

    if (allChannels.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.live_tv,
                size: 64, color: Theme.of(context).colorScheme.outline),
            const SizedBox(height: 16),
            Text(AppLocalizations.of(context)!.noChannels),
          ],
        ),
      );
    }

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(8),
          child: Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _searchController,
                  decoration: InputDecoration(
                    hintText: AppLocalizations.of(context)!.searchChannels,
                    prefixIcon: const Icon(Icons.search),
                    suffixIcon: _searchQuery.isNotEmpty
                        ? IconButton(
                            icon: const Icon(Icons.clear),
                            onPressed: () {
                              _searchController.clear();
                              setState(() => _searchQuery = '');
                            })
                        : null,
                    border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(8)),
                    contentPadding: const EdgeInsets.symmetric(horizontal: 12),
                  ),
                  onChanged: _onSearchChanged,
                ),
              ),
              if (groups.isNotEmpty) ...[
                const SizedBox(width: 8),
                PopupMenuButton<String>(
                  icon: Badge(
                    isLabelVisible: _selectedGroup != null,
                    child: const Icon(Icons.filter_list),
                  ),
                  onSelected: (value) {
                    setState(() {
                      _selectedGroup = value.isEmpty ? null : value;
                    });
                  },
                  itemBuilder: (context) {
                    final items = <PopupMenuEntry<String>>[
                      PopupMenuItem<String>(
                        value: '',
                        child: Row(children: [
                          Icon(_selectedGroup == null ? Icons.check : null,
                              size: 18),
                          const SizedBox(width: 8),
                          Text(AppLocalizations.of(context)!.all),
                        ]),
                      ),
                    ];
                    for (final g in groups.toList()..sort()) {
                      items.add(PopupMenuItem<String>(
                        value: g,
                        child: Row(children: [
                          Icon(
                              _selectedGroup?.toLowerCase() == g.toLowerCase()
                                  ? Icons.check
                                  : null,
                              size: 18),
                          const SizedBox(width: 8),
                          Expanded(
                              child: Text(g, overflow: TextOverflow.ellipsis)),
                        ]),
                      ));
                    }
                    return items;
                  },
                ),
              ],
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Row(
            children: [
              Text(
                  AppLocalizations.of(context)!
                      .nChannels(filteredChannels.length),
                  style: Theme.of(context).textTheme.bodySmall),
            ],
          ),
        ),
        const SizedBox(height: 8),
        Expanded(
          child: filteredChannels.isEmpty
              ? Center(
                  child: Text(AppLocalizations.of(context)!.noChannelsFound))
              : LayoutBuilder(
                  builder: (context, constraints) {
                    Widget tileAt(BuildContext context, int index) {
                      final channel = filteredChannels[index];
                      final isFavorite = favoriteIds.contains(channel.uniqueId);
                      return Card(
                        clipBehavior: Clip.antiAlias,
                        margin: const EdgeInsets.symmetric(
                            vertical: 4, horizontal: 8),
                        child: InkWell(
                          onTap: () async {
                            context
                                .read<AppStatsNotifier>()
                                .addToRecentlyWatched(channel);
                            final currentUrl = NativeAudioService.currentUrl;
                            final isAudioPlaying =
                                NativeAudioService.currentState.isPlaying ||
                                    NativeAudioService.isBuffering;
                            final shouldStartInAudioOnly = currentUrl != null &&
                                currentUrl == channel.url &&
                                isAudioPlaying;
                            if (currentUrl != null && currentUrl != channel.url) {
                              await NativeAudioService.stop();
                            }
                            if (!context.mounted) return;
                            // Root navigator, not the tab's own: a plain push
                            // here would land the player inside the tab, under
                            // FirstPage's bottom nav bar, instead of covering
                            // it — see the nested-tab-navigation plan.
                            Navigator.of(context, rootNavigator: true).push(
                              MaterialPageRoute(
                                builder: (_) => PlayerPage(
                                  // The whole playlist, not `filteredChannels`.
                                  // Search and the group filter are a way to
                                  // *find* a channel; once you are watching, the
                                  // numbering should be the channel's real
                                  // position and zapping should not stop at the
                                  // edge of a filter you have already left
                                  // behind. It also keeps the quick list's row
                                  // numbers and the n/total chip agreeing with
                                  // each other and with the playlist.
                                  channel: channel,
                                  channels: playlist.channels,
                                  initialIndex: playlist.channels.indexOf(channel),
                                  initialAudioOnly: shouldStartInAudioOnly,
                                ),
                              ),
                            );
                          },
                          child: Padding(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 12, vertical: 8),
                            child: Row(
                              children: [
                                ClipRRect(
                                  borderRadius: BorderRadius.circular(4),
                                  child: ChannelLogo(
                                    url: channel.logo,
                                    width: 40,
                                    height: 40,
                                    fallbackBuilder: (_) => Container(
                                      width: 40,
                                      height: 40,
                                      decoration: BoxDecoration(
                                        color: Theme.of(context)
                                            .colorScheme
                                            .primaryContainer,
                                        borderRadius: BorderRadius.circular(4),
                                      ),
                                      child: Icon(Icons.live_tv,
                                          color: Theme.of(context)
                                              .colorScheme
                                              .onPrimaryContainer),
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 12),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Text(channel.name,
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis),
                                      if (channel.displayGroup != null)
                                        Text(channel.displayGroup!,
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                            style: Theme.of(context)
                                                .textTheme
                                                .bodySmall),
                                    ],
                                  ),
                                ),
                                SizedBox(
                                  width: 40,
                                  height: 40,
                                  child: IconButton(
                                    padding: EdgeInsets.zero,
                                    iconSize: 20,
                                    icon: Icon(
                                        isFavorite
                                            ? Icons.favorite
                                            : Icons.favorite_border,
                                        color: isFavorite ? Colors.red : null),
                                    onPressed: () => context
                                        .read<AppStatsNotifier>()
                                        .toggleFavorite(channel),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      );
                    }

                    // One column per ~300 logical px, derived from *width* and
                    // not orientation: a phone in landscape and a tablet in
                    // portrait can share a width and should lay out the same.
                    //
                    // Measured motivation: this emulator is 1600x900 at density
                    // 240, i.e. 1067 logical px wide. The single-column list
                    // showed ~5 of 116 channels there, spending most of every
                    // row on empty space. Portrait (~393 logical) already showed
                    // ~12 and was fine, which is why it keeps the ListView below.
                    final columns =
                        (constraints.maxWidth / 300).floor().clamp(1, 4);

                    if (columns == 1) {
                      // Compact widths keep the exact ListView they had, so
                      // portrait cannot regress: a GridView would impose a fixed
                      // row height on a layout that is already correct.
                      return ListView.builder(
                        padding: const EdgeInsets.symmetric(horizontal: 8),
                        itemCount: filteredChannels.length,
                        itemBuilder: tileAt,
                      );
                    }

                    // The grid hands each tile a *tight* height, which the
                    // ListView never did — so the extent must fit the tallest
                    // thing the tile can contain, not the usual case.
                    //
                    // Budget: Card margin 4+4, inner Padding 8+8, then the
                    // content, which is whichever is taller of the 40px logo or
                    // the two text lines. Note this is ONE uniform row height
                    // for the whole grid, not a per-tile measurement — a
                    // single-line channel simply gets the shared extent.
                    //
                    // 36.0 is bodyMedium (~20) + bodySmall (~16) at the stock
                    // Material 3 scale; this app sets no custom textTheme. It is
                    // NOT linked to Theme.of(context) — deriving it live is
                    // unreliable because TextStyle.height is often null in the
                    // Material defaults. So: if a custom textTheme is ever added,
                    // revisit this number.
                    // Those lines scale with the user's system font size and
                    // nothing in this app clamps textScaler — so a hardcoded 68
                    // overflowed at ~1.22x, i.e. Android's ordinary "Large" font
                    // setting, not an extreme accessibility case. Deriving it
                    // keeps every scale correct and costs nothing at default.
                    final textScale = MediaQuery.textScalerOf(context).scale(1);
                    final textHeight = 36.0 * textScale;
                    final contentHeight =
                        textHeight < 40.0 ? 40.0 : textHeight;
                    final rowExtent = contentHeight + 16 + 8 + 4;

                    return GridView.builder(
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      gridDelegate:
                          SliverGridDelegateWithFixedCrossAxisCount(
                        crossAxisCount: columns,
                        // Fixed extent, not childAspectRatio: the row height must
                        // stay put as the column count changes, and an aspect
                        // ratio would make it do exactly the opposite.
                        mainAxisExtent: rowExtent,
                      ),
                      itemCount: filteredChannels.length,
                      itemBuilder: tileAt,
                    );
                  },
                ),
        ),
      ],
    );
  }
}
