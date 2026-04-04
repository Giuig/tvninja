import 'dart:async';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:tvninja/config/config.dart';
import 'package:tvninja/l10n/app_localizations.dart';
import 'package:tvninja/pages/player_page.dart';
import 'package:tvninja/services/native_audio_service.dart';
import 'package:tvninja/widgets/channel_logo.dart';

class ChannelsPage extends StatefulWidget {
  final Playlist playlist;

  const ChannelsPage({super.key, required this.playlist});

  @override
  State<ChannelsPage> createState() => _ChannelsPageState();
}

class _ChannelsPageState extends State<ChannelsPage> {
  final TextEditingController _searchController = TextEditingController();
  String _searchQuery = '';
  String? _selectedGroup;
  Timer? _debounceTimer;

  static const String _allGroups = '__ALL__';

  @override
  void dispose() {
    _searchController.dispose();
    _debounceTimer?.cancel();
    super.dispose();
  }

  List<Channel> get _filteredChannels {
    var channels = widget.playlist.channels;

    if (_selectedGroup != null && _selectedGroup != _allGroups) {
      final normalizedGroup = _selectedGroup!.toLowerCase();
      channels = channels
          .where((c) => c.group?.toLowerCase() == normalizedGroup)
          .toList();
    }

    if (_searchQuery.isNotEmpty) {
      final query = _searchQuery.toLowerCase();
      channels =
          channels.where((c) => c.name.toLowerCase().contains(query)).toList();
    }

    return channels;
  }

  Set<String> get _groups {
    return widget.playlist.channels
        .where((c) => c.group != null && c.group!.isNotEmpty)
        .map((c) => c.group!)
        .toSet();
  }

  void _onSearchChanged(String value) {
    _debounceTimer?.cancel();
    _debounceTimer = Timer(const Duration(milliseconds: 300), () {
      if (mounted) {
        setState(() => _searchQuery = value);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final favoriteIds = context
        .select<AppStatsNotifier, Set<String>>((n) => n.favoriteChannelIds);
    final groups = _groups;
    final channels = _filteredChannels;
    final l10n = AppLocalizations.of(context)!;

    return Scaffold(
      appBar: AppBar(
        title: Text(widget.playlist.name),
        actions: [
          if (groups.isNotEmpty)
            PopupMenuButton<String>(
              icon: const Icon(Icons.filter_list),
              onSelected: (value) {
                setState(() {
                  _selectedGroup = value == _allGroups ? null : value;
                });
              },
              itemBuilder: (context) {
                final items = <PopupMenuEntry<String>>[
                  PopupMenuItem<String>(
                    value: _allGroups,
                    child: Row(children: [
                      Icon(_selectedGroup == null ? Icons.check : null,
                          size: 18),
                      const SizedBox(width: 8),
                      Text(l10n.all),
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
                      Expanded(child: Text(g, overflow: TextOverflow.ellipsis)),
                    ]),
                  ));
                }
                return items;
              },
            ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(8),
            child: TextField(
              controller: _searchController,
              decoration: InputDecoration(
                hintText: l10n.searchChannels,
                prefixIcon: const Icon(Icons.search),
                suffixIcon: _searchQuery.isNotEmpty
                    ? IconButton(
                        icon: const Icon(Icons.clear),
                        onPressed: () {
                          _searchController.clear();
                          setState(() => _searchQuery = '');
                        })
                    : null,
                border:
                    OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
              ),
              onChanged: _onSearchChanged,
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(
              children: [
                Text(l10n.nChannels(channels.length),
                    style: Theme.of(context).textTheme.bodySmall),
              ],
            ),
          ),
          const SizedBox(height: 8),
          Expanded(
            child: channels.isEmpty
                ? Center(child: Text(l10n.noChannelsFound))
                : ListView.builder(
                    itemCount: channels.length,
                    itemBuilder: (context, index) {
                      final channel = channels[index];
                      final isFavorite = favoriteIds.contains(channel.uniqueId);
                      return _ChannelTile(
                          channel: channel, isFavorite: isFavorite);
                    },
                  ),
          ),
        ],
      ),
    );
  }
}

class _ChannelTile extends StatelessWidget {
  final Channel channel;
  final bool isFavorite;

  const _ChannelTile({required this.channel, required this.isFavorite});

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: () async {
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
        final channels = stats.allChannels
            .where((c) => c.playlistId == channel.playlistId)
            .toList();
        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => PlayerPage(
              channel: channel,
              channels: channels,
              initialIndex: channels.indexOf(channel),
              initialAudioOnly: shouldStartInAudioOnly,
            ),
          ),
        );
      },
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        child: Row(
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: ChannelLogo(
                url: channel.logo,
                width: 40,
                height: 40,
                fallbackBuilder: (_) => _defaultLogo(context),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(channel.name,
                      maxLines: 1, overflow: TextOverflow.ellipsis),
                  if (channel.group != null)
                    Text(channel.group!,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.bodySmall),
                ],
              ),
            ),
            SizedBox(
              width: 40,
              height: 40,
              child: IconButton(
                padding: EdgeInsets.zero,
                iconSize: 20,
                icon: Icon(isFavorite ? Icons.favorite : Icons.favorite_border,
                    color: isFavorite ? Colors.red : null),
                onPressed: () =>
                    context.read<AppStatsNotifier>().toggleFavorite(channel),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _defaultLogo(BuildContext context) {
    return Container(
      width: 40,
      height: 40,
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(4),
      ),
      child: Icon(Icons.tv,
          size: 20, color: Theme.of(context).colorScheme.onSurfaceVariant),
    );
  }
}
