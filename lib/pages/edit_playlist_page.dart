import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:tvninja/config/config.dart';
import 'package:tvninja/l10n/app_localizations.dart';
import 'package:tvninja/services/m3u_parser.dart';
import 'package:tvninja/services/xtream_parser.dart';

/// Edits a whole playlist: its name, and where it comes from.
///
/// Replaces the old Rename dialog, which could only change the name (and
/// labelled its confirm button "Add"). The form follows the playlist's kind,
/// the way Add does: an Xtream playlist shows portal, username and password —
/// split back out of the URL they are stored in, see `_addFromXtream` — and
/// anything else shows its M3U URL.
///
/// Saving a new name alone is instant. Changing the source reloads the
/// channels first, exactly like adding would, and only then replaces the
/// playlist — so a typo in a URL fails on the form and leaves the working
/// playlist untouched. The id stays the same either way, which keeps the
/// playlist in place in any open channel list.
class EditPlaylistPage extends StatefulWidget {
  final Playlist playlist;

  const EditPlaylistPage({super.key, required this.playlist});

  @override
  State<EditPlaylistPage> createState() => _EditPlaylistPageState();
}

class _EditPlaylistPageState extends State<EditPlaylistPage> {
  /// Non-null for an Xtream playlist; fixed for the page's lifetime, since the
  /// kind of a playlist is not something this form changes.
  late final XtreamCredentials? _xtream =
      XtreamParser.parseCredentials(widget.playlist.url);

  late final _nameCtrl = TextEditingController(text: widget.playlist.name);
  late final _urlCtrl =
      TextEditingController(text: _xtream?.url ?? widget.playlist.url);
  late final _userCtrl = TextEditingController(text: _xtream?.username ?? '');
  late final _passCtrl = TextEditingController(text: _xtream?.password ?? '');

  bool _saving = false;
  String? _nameError;
  String? _sourceError;

  @override
  void dispose() {
    _nameCtrl.dispose();
    _urlCtrl.dispose();
    _userCtrl.dispose();
    _passCtrl.dispose();
    super.dispose();
  }

  void _clearErrors() {
    if (_nameError == null && _sourceError == null) return;
    setState(() {
      _nameError = null;
      _sourceError = null;
    });
  }

  Future<void> _save() async {
    final l10n = AppLocalizations.of(context)!;
    final name = _nameCtrl.text.trim();
    final url = _urlCtrl.text.trim();
    final user = _userCtrl.text.trim();
    final pass = _passCtrl.text.trim();

    if (name.isEmpty) {
      setState(() => _nameError = l10n.fillAllFields);
      return;
    }
    if (url.isEmpty || (_xtream != null && (user.isEmpty || pass.isEmpty))) {
      setState(() => _sourceError = l10n.fillAllFields);
      return;
    }
    final uri = Uri.tryParse(url);
    if (uri == null || !uri.hasScheme || !uri.scheme.startsWith('http')) {
      setState(() => _sourceError = l10n.invalidUrl);
      return;
    }

    // Same composition as `_addFromXtream`, so an edited playlist is stored
    // exactly the way a freshly added one would be.
    final newUrl =
        _xtream != null ? '$url?username=$user&password=$pass' : url;
    final stats = context.read<AppStatsNotifier>();
    final playlist = widget.playlist;

    if (AppStatsNotifier.normalisePlaylistUrl(newUrl) ==
        AppStatsNotifier.normalisePlaylistUrl(playlist.url)) {
      await stats.renamePlaylist(playlist.id, name);
      if (mounted) Navigator.pop(context);
      return;
    }

    if (stats.hasPlaylistWithUrl(newUrl, exceptId: playlist.id)) {
      setState(() => _sourceError = l10n.playlistAlreadyAdded);
      return;
    }

    setState(() => _saving = true);
    try {
      final List<Channel> channels;
      if (_xtream != null) {
        final info = await XtreamParser.parse(url, user, pass);
        // Same check Add makes: it is what rejects wrong credentials.
        await XtreamParser.getServerInfo(
            XtreamCredentials(url: url, username: user, password: pass));
        channels = info.map((c) => c.toChannel(url, user, pass, url)).toList();
      } else {
        channels = await M3UParser.parse(url);
      }
      if (!mounted) return;
      await stats.updatePlaylist(playlist.copyWith(
        name: name,
        url: newUrl,
        channels:
            channels.map((c) => c.copyWith(playlistId: playlist.id)).toList(),
      ));
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(l10n.channelsLoaded(channels.length))),
      );
      Navigator.pop(context);
    } catch (e) {
      if (mounted) setState(() => _sourceError = e.toString());
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final xtream = _xtream != null;

    return Scaffold(
      appBar: AppBar(title: Text(l10n.editPlaylist)),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
              controller: _nameCtrl,
              decoration: InputDecoration(
                labelText: l10n.playlistName,
                prefixIcon: const Icon(Icons.label_outline),
                border: const OutlineInputBorder(),
                errorText: _nameError,
              ),
              onChanged: (_) => _clearErrors(),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _urlCtrl,
              decoration: InputDecoration(
                labelText: xtream ? l10n.portalUrl : l10n.m3uUrl,
                prefixIcon: Icon(xtream ? Icons.dns : Icons.link),
                border: const OutlineInputBorder(),
                errorText: _sourceError,
                errorMaxLines: 3,
              ),
              keyboardType: TextInputType.url,
              autocorrect: false,
              onChanged: (_) => _clearErrors(),
            ),
            if (xtream) ...[
              const SizedBox(height: 16),
              TextField(
                controller: _userCtrl,
                decoration: InputDecoration(
                  labelText: l10n.username,
                  prefixIcon: const Icon(Icons.person),
                  border: const OutlineInputBorder(),
                ),
                autocorrect: false,
                onChanged: (_) => _clearErrors(),
              ),
              const SizedBox(height: 16),
              TextField(
                controller: _passCtrl,
                decoration: InputDecoration(
                  labelText: l10n.password,
                  prefixIcon: const Icon(Icons.lock),
                  border: const OutlineInputBorder(),
                ),
                obscureText: true,
                onChanged: (_) => _clearErrors(),
              ),
            ],
            const SizedBox(height: 28),
            FilledButton.icon(
              onPressed: _saving ? null : _save,
              icon: _saving
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(
                          strokeWidth: 2, color: Colors.white),
                    )
                  : const Icon(Icons.check),
              label: Text(l10n.save),
            ),
          ],
        ),
      ),
    );
  }
}
