import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:tvninja/config/config.dart';
import 'package:tvninja/l10n/app_localizations.dart';
import 'package:tvninja/pages/add_playlist_page.dart';
import 'package:tvninja/pages/channel_list_page.dart';
import 'package:tvninja/pages/edit_playlist_page.dart';
import 'package:tvninja/services/m3u_parser.dart';
import 'package:tvninja/services/xtream_parser.dart';

class PlaylistPage extends StatefulWidget {
  const PlaylistPage({super.key});

  @override
  State<PlaylistPage> createState() => _PlaylistPageState();
}

class _PlaylistPageState extends State<PlaylistPage> {
  void _openPlaylist(Playlist playlist) {
    // Plain push, on this tab's own navigator: the channel list belongs to
    // the playlists tab's own back stack, so switching tabs and coming back
    // finds it exactly as it was left.
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => ChannelListPage(playlistId: playlist.id),
      ),
    );
  }

  void _showAddDialog() {
    // Root navigator, not this tab's: this is a modal-style full-page form
    // rather than something that belongs to the playlists tab's own back
    // stack, so — like the PlayerPage pushes — it should cover the whole
    // screen, bottom nav bar included, not render confined to the tab area.
    Navigator.of(context, rootNavigator: true).push(
        MaterialPageRoute(builder: (_) => const AddPlaylistPage()));
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
              title: Text(AppLocalizations.of(context)!.edit),
              onTap: () {
                Navigator.pop(context);
                _showEditPage(playlist);
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

  void _showEditPage(Playlist playlist) {
    // Root navigator, for the same reason as `_showAddDialog`: a full-page
    // form, not part of this tab's back stack.
    Navigator.of(context, rootNavigator: true).push(MaterialPageRoute(
        builder: (_) => EditPlaylistPage(playlist: playlist)));
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
        // ChannelListPage re-reads the playlist from AppStatsNotifier on
        // every build, so updating it here is enough — no snapshot on this
        // page to re-sync by hand any more.
        context.read<AppStatsNotifier>().updatePlaylist(updated);
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
              // If a ChannelListPage for this playlist is open (on this
              // tab's stack), its own build will find no matching playlist
              // on the next AppStatsNotifier update and pop itself.
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
        title: Text(AppLocalizations.of(context)!.playlists),
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: _showAddDialog,
        child: const Icon(Icons.add),
      ),
      body: _buildPlaylistList(playlists),
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
            onTap: () => _openPlaylist(playlist),
          ),
        );
      },
    );
  }
}
