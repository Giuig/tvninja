import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:tvninja/config/config.dart';
import 'package:tvninja/l10n/app_localizations.dart';
import 'package:tvninja/pages/add_playlist_page.dart';
import 'package:tvninja/pages/player_page.dart';
import 'package:tvninja/services/native_audio_service.dart';
import 'package:tvninja/services/m3u_parser.dart';
import 'package:tvninja/services/xtream_parser.dart';
import 'package:tvninja/widgets/channel_logo.dart';

class PlaylistPage extends StatefulWidget {
  const PlaylistPage({super.key});

  @override
  State<PlaylistPage> createState() => _PlaylistPageState();
}

class _PlaylistPageState extends State<PlaylistPage> {
  final _searchController = TextEditingController();
  Playlist? _selectedPlaylist;
  String _searchQuery = '';
  String? _selectedGroup;
  Timer? _debounceTimer;

  @override
  void dispose() {
    _searchController.dispose();
    _debounceTimer?.cancel();
    super.dispose();
  }

  void _selectPlaylist(Playlist playlist) {
    setState(() {
      _selectedPlaylist = playlist;
      _searchQuery = '';
      _selectedGroup = null;
      _searchController.clear();
    });
  }

  void _clearSelection() {
    setState(() {
      _selectedPlaylist = null;
      _searchQuery = '';
      _selectedGroup = null;
    });
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
          .where((c) => c.group?.toLowerCase() == _selectedGroup!.toLowerCase())
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
        .where((c) => c.group != null && c.group!.isNotEmpty)
        .map((c) => c.group!)
        .toSet();
  }

  void _showAddDialog() {
    Navigator.push(
        context, MaterialPageRoute(builder: (_) => const AddPlaylistPage()));
  }

  void _showPlaylistMenu(Playlist playlist) {
    showModalBottomSheet(
      context: context,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.edit),
              title: Text(AppLocalizations.of(context)!.rename),
              onTap: () {
                Navigator.pop(context);
                _showRenameDialog(playlist);
              },
            ),
            ListTile(
              leading: const Icon(Icons.link),
              title: Text(AppLocalizations.of(context)!.copyUrl),
              onTap: () {
                Clipboard.setData(ClipboardData(text: playlist.url));
                Navigator.pop(context);
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                      content: Text(AppLocalizations.of(context)!.urlCopied)),
                );
              },
            ),
            ListTile(
              leading: const Icon(Icons.refresh),
              title: Text(AppLocalizations.of(context)!.refresh),
              onTap: () {
                Navigator.pop(context);
                _refreshPlaylist(playlist);
              },
            ),
            ListTile(
              leading: const Icon(Icons.delete, color: Colors.red),
              title: Text(AppLocalizations.of(context)!.delete,
                  style: const TextStyle(color: Colors.red)),
              onTap: () {
                Navigator.pop(context);
                _confirmDelete(playlist);
              },
            ),
          ],
        ),
      ),
    );
  }

  void _showRenameDialog(Playlist playlist) {
    final controller = TextEditingController(text: playlist.name);
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(AppLocalizations.of(context)!.renamePlaylist),
        content: TextField(
            controller: controller,
            decoration: InputDecoration(
                labelText: AppLocalizations.of(context)!.nameLabel)),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: Text(AppLocalizations.of(context)!.cancel)),
          TextButton(
            onPressed: () {
              final name = controller.text.trim();
              if (name.isNotEmpty) {
                context
                    .read<AppStatsNotifier>()
                    .renamePlaylist(playlist.id, name);
                Navigator.pop(ctx);
              }
            },
            child: Text(AppLocalizations.of(context)!.add),
          ),
        ],
      ),
    );
  }

  Future<void> _refreshPlaylist(Playlist playlist) async {
    try {
      List<Channel> channels;

      final xtreamCreds = XtreamParser.parseCredentials(playlist.url);
      if (xtreamCreds != null) {
        final xtreamChannels = await XtreamParser.parse(
          xtreamCreds.url,
          xtreamCreds.username,
          xtreamCreds.password,
        );
        channels = xtreamChannels
            .map((c) => c.toChannel(xtreamCreds.url, xtreamCreds.username,
                xtreamCreds.password, playlist.url))
            .toList();
      } else {
        channels = await M3UParser.parse(playlist.url);
      }

      final playlistId = playlist.id;
      final updated = playlist.copyWith(
        channels:
            channels.map((c) => c.copyWith(playlistId: playlistId)).toList(),
      );
      if (mounted) {
        context.read<AppStatsNotifier>().updatePlaylist(updated);
        if (_selectedPlaylist?.id == playlist.id) {
          setState(() {
            _selectedPlaylist = updated;
          });
        }
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
              content: Text(AppLocalizations.of(context)!
                  .channelsLoaded(channels.length))),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
              content: Text(AppLocalizations.of(context)!.error(e.toString()))),
        );
      }
    }
  }

  void _confirmDelete(Playlist playlist) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(AppLocalizations.of(context)!.deletePlaylist),
        content: Text(AppLocalizations.of(context)!.confirmDeletePlaylist),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: Text(AppLocalizations.of(context)!.cancel)),
          TextButton(
            onPressed: () {
              context.read<AppStatsNotifier>().removePlaylist(playlist.id);
              Navigator.pop(ctx);
              if (_selectedPlaylist?.id == playlist.id) {
                _clearSelection();
              }
            },
            child: Text(AppLocalizations.of(context)!.delete,
                style: const TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final playlists = context.watch<AppStatsNotifier>().playlists.toList()
      ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));

    return Scaffold(
      appBar: AppBar(
        title: Text(_selectedPlaylist != null
            ? _selectedPlaylist!.name
            : AppLocalizations.of(context)!.playlists),
        leading: _selectedPlaylist != null
            ? IconButton(
                icon: const Icon(Icons.arrow_back),
                onPressed: _clearSelection,
              )
            : null,
      ),
      floatingActionButton: _selectedPlaylist == null
          ? FloatingActionButton(
              onPressed: _showAddDialog,
              child: const Icon(Icons.add),
            )
          : null,
      body: _selectedPlaylist != null
          ? _buildChannelsList(_selectedPlaylist!)
          : _buildPlaylistList(playlists),
    );
  }

  Widget _buildPlaylistList(List<Playlist> playlists) {
    if (playlists.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.playlist_add,
                size: 64, color: Theme.of(context).colorScheme.outline),
            const SizedBox(height: 16),
            Text(AppLocalizations.of(context)!.noPlaylists,
                style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            Text(AppLocalizations.of(context)!.addFirstPlaylist,
                style: TextStyle(color: Theme.of(context).colorScheme.outline)),
          ],
        ),
      );
    }

    return ListView.builder(
      padding: const EdgeInsets.all(16),
      itemCount: playlists.length,
      itemBuilder: (context, index) {
        final playlist = playlists[index];
        return Card(
          clipBehavior: Clip.antiAlias,
          margin: const EdgeInsets.only(bottom: 8),
          child: ListTile(
            leading: Container(
              width: 48,
              height: 48,
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.primaryContainer,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Icon(Icons.playlist_play,
                  color: Theme.of(context).colorScheme.onPrimaryContainer),
            ),
            title: Text(playlist.name),
            subtitle: Text(AppLocalizations.of(context)!
                .nChannels(playlist.channels.length)),
            trailing: IconButton(
                icon: const Icon(Icons.more_vert),
                onPressed: () => _showPlaylistMenu(playlist)),
            onTap: () => _selectPlaylist(playlist),
          ),
        );
      },
    );
  }

  Widget _buildChannelsList(Playlist playlist) {
    final allChannels = playlist.channels;
    final favoriteIds = context.watch<AppStatsNotifier>().favoriteChannelIds;
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
              : ListView.builder(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  itemCount: filteredChannels.length,
                  itemBuilder: (context, index) {
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
                          Navigator.push(
                            context,
                            MaterialPageRoute(
                              builder: (_) => PlayerPage(
                                channel: channel,
                                channels: filteredChannels,
                                initialIndex: filteredChannels.indexOf(channel),
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
                                    if (channel.group != null)
                                      Text(channel.group!,
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
                  },
                ),
        ),
      ],
    );
  }
}
