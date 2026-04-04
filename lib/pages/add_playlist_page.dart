import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:tvninja/config/config.dart';
import 'package:tvninja/l10n/app_localizations.dart';
import 'package:tvninja/services/iptv_org_service.dart';
import 'package:tvninja/services/m3u_parser.dart';
import 'package:tvninja/services/xtream_parser.dart';

class AddPlaylistPage extends StatefulWidget {
  const AddPlaylistPage({super.key});

  @override
  State<AddPlaylistPage> createState() => _AddPlaylistPageState();
}

class _AddPlaylistPageState extends State<AddPlaylistPage>
    with TickerProviderStateMixin {
  late final TabController _tabController;
  final _browseSearchController = TextEditingController();

  // Browse state
  bool _browseLoading = false;
  String? _browseError;
  bool _isSelecting = false;
  String? _selectingName;
  int _browseSelectedIndex = 0;

  // M3U tab
  final _urlCtrl = TextEditingController();
  final _nameCtrl = TextEditingController();
  bool _addingM3U = false;
  String? _m3uError;

  // Xtream tab
  final _xtreamUrlCtrl = TextEditingController();
  final _xtreamNameCtrl = TextEditingController();
  final _userCtrl = TextEditingController();
  final _passCtrl = TextEditingController();
  bool _addingXtream = false;
  String? _xtreamError;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 3, vsync: this);
    _fetchBrowseData();
  }

  Future<void> _fetchBrowseData() async {
    if (IptvOrgService.isLoaded) return;
    setState(() {
      _browseLoading = true;
      _browseError = null;
    });
    try {
      await IptvOrgService.fetchAll();
    } catch (e) {
      if (mounted) setState(() => _browseError = e.toString());
    } finally {
      if (mounted) setState(() => _browseLoading = false);
    }
  }

  Future<void> _selectBrowseSource(String name, String url, String code) async {
    setState(() {
      _isSelecting = true;
      _selectingName = name;
    });
    try {
      final channels = await M3UParser.parse(url, code);
      final playlist = Playlist(
        id: DateTime.now().millisecondsSinceEpoch.toString(),
        name: '$name (IPTV.org)',
        url: url,
        channels: channels,
      );
      if (!mounted) return;
      context.read<AppStatsNotifier>().addPlaylist(playlist);
      if (!mounted) return;
      Navigator.of(context).popUntil((route) => route.isFirst);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            AppLocalizations.of(context)!
                .channelsLoadedForCountry(channels.length, name),
          ),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            AppLocalizations.of(context)!
                .failedToLoadCountry(name, e.toString()),
          ),
        ),
      );
    } finally {
      if (mounted) {
        setState(() {
          _isSelecting = false;
          _selectingName = null;
        });
      }
    }
  }

  void _navigateToBrowse() {
    // Browse tab now shows embedded content - no navigation needed
  }

  @override
  void dispose() {
    _tabController.dispose();
    _browseSearchController.dispose();
    _urlCtrl.dispose();
    _nameCtrl.dispose();
    _xtreamUrlCtrl.dispose();
    _xtreamNameCtrl.dispose();
    _userCtrl.dispose();
    _passCtrl.dispose();
    super.dispose();
  }

  String _extractNameFromUrl(String url) {
    try {
      final uri = Uri.parse(url);
      final segments = uri.pathSegments.where((s) => s.isNotEmpty).toList();
      if (segments.isNotEmpty) {
        String name = segments.last;
        for (final ext in ['.m3u8', '.m3u', '.ts', '.mp4', '.isml']) {
          if (name.toLowerCase().endsWith(ext)) {
            name = name.substring(0, name.length - ext.length);
            break;
          }
        }
        if (name.isNotEmpty) return name;
      }
      return uri.host.split('.').first;
    } catch (_) {
      return url;
    }
  }

  Future<void> _addFromM3U() async {
    final url = _urlCtrl.text.trim();
    final l10n = AppLocalizations.of(context)!;

    if (url.isEmpty) {
      setState(() => _m3uError = l10n.fillAllFields);
      return;
    }
    final uri = Uri.tryParse(url);
    if (uri == null || !uri.hasScheme || !uri.scheme.startsWith('http')) {
      setState(() => _m3uError = l10n.invalidUrl);
      return;
    }
    setState(() {
      _m3uError = null;
      _addingM3U = true;
    });

    try {
      final channels = await M3UParser.parse(url);
      final name = _nameCtrl.text.trim().isNotEmpty
          ? _nameCtrl.text.trim()
          : _extractNameFromUrl(url);
      final playlistId = DateTime.now().millisecondsSinceEpoch.toString();
      final playlist = Playlist(
        id: playlistId,
        name: name,
        url: url,
        channels:
            channels.map((c) => c.copyWith(playlistId: playlistId)).toList(),
      );
      if (mounted) {
        context.read<AppStatsNotifier>().addPlaylist(playlist);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(l10n.channelsLoaded(channels.length))),
        );
        Navigator.pop(context);
      }
    } catch (e) {
      if (mounted) setState(() => _m3uError = e.toString());
    } finally {
      if (mounted) setState(() => _addingM3U = false);
    }
  }

  Future<void> _addFromXtream() async {
    final url = _xtreamUrlCtrl.text.trim();
    final user = _userCtrl.text.trim();
    final pass = _passCtrl.text.trim();
    final l10n = AppLocalizations.of(context)!;

    if (url.isEmpty || user.isEmpty || pass.isEmpty) {
      setState(() => _xtreamError = l10n.fillAllFields);
      return;
    }
    final uri = Uri.tryParse(url);
    if (uri == null || !uri.hasScheme || !uri.scheme.startsWith('http')) {
      setState(() => _xtreamError = l10n.invalidUrl);
      return;
    }
    setState(() {
      _xtreamError = null;
      _addingXtream = true;
    });

    try {
      final xtreamChannels = await XtreamParser.parse(url, user, pass);
      await XtreamParser.getServerInfo(
          XtreamCredentials(url: url, username: user, password: pass));
      final channels =
          xtreamChannels.map((c) => c.toChannel(url, user, pass, url)).toList();
      final name = _xtreamNameCtrl.text.trim().isNotEmpty
          ? _xtreamNameCtrl.text.trim()
          : _extractNameFromUrl(url);
      final playlistId = DateTime.now().millisecondsSinceEpoch.toString();
      final playlist = Playlist(
        id: playlistId,
        name: name,
        url: '$url?username=$user&password=$pass',
        channels:
            channels.map((c) => c.copyWith(playlistId: playlistId)).toList(),
      );
      if (mounted) {
        context.read<AppStatsNotifier>().addPlaylist(playlist);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(l10n.channelsLoaded(channels.length))),
        );
        Navigator.pop(context);
      }
    } catch (e) {
      if (mounted) setState(() => _xtreamError = e.toString());
    } finally {
      if (mounted) setState(() => _addingXtream = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;

    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.addPlaylist),
        bottom: TabBar(
          controller: _tabController,
          onTap: (index) {
            if (index == 2) _navigateToBrowse();
          },
          tabs: [
            Tab(icon: const Icon(Icons.link), text: l10n.m3uUrl),
            Tab(icon: const Icon(Icons.dns), text: l10n.xtreamCodes),
            Tab(icon: const Icon(Icons.explore), text: l10n.browse),
          ],
        ),
      ),
      body: TabBarView(
        controller: _tabController,
        children: [
          // ── M3U / URL tab ────────────────────────────────────────────
          SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                TextField(
                  controller: _urlCtrl,
                  decoration: InputDecoration(
                    labelText: l10n.m3uUrl,
                    hintText: 'https://example.com/playlist.m3u8',
                    prefixIcon: const Icon(Icons.link),
                    border: const OutlineInputBorder(),
                    errorText: _m3uError,
                  ),
                  keyboardType: TextInputType.url,
                  autocorrect: false,
                  onChanged: (_) => setState(() => _m3uError = null),
                ),
                const SizedBox(height: 16),
                TextField(
                  controller: _nameCtrl,
                  decoration: InputDecoration(
                    labelText: '${l10n.playlistName} (optional)',
                    hintText: l10n.playlistNameHint,
                    prefixIcon: const Icon(Icons.label_outline),
                    border: const OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 20),
                FilledButton.icon(
                  onPressed: _addingM3U ? null : _addFromM3U,
                  icon: _addingM3U
                      ? const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(
                              strokeWidth: 2, color: Colors.white),
                        )
                      : const Icon(Icons.add),
                  label: Text(l10n.add),
                ),
              ],
            ),
          ),

          // ── Xtream Codes tab ─────────────────────────────────────────
          SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                TextField(
                  controller: _xtreamUrlCtrl,
                  decoration: InputDecoration(
                    labelText: l10n.portalUrl,
                    hintText: 'http://example.com:8080',
                    prefixIcon: const Icon(Icons.dns),
                    border: const OutlineInputBorder(),
                    errorText: _xtreamError,
                  ),
                  keyboardType: TextInputType.url,
                  autocorrect: false,
                  onChanged: (_) => setState(() => _xtreamError = null),
                ),
                const SizedBox(height: 16),
                TextField(
                  controller: _xtreamNameCtrl,
                  decoration: InputDecoration(
                    labelText: '${l10n.playlistName} (optional)',
                    hintText: l10n.playlistNameHint,
                    prefixIcon: const Icon(Icons.label_outline),
                    border: const OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 16),
                TextField(
                  controller: _userCtrl,
                  decoration: InputDecoration(
                    labelText: l10n.username,
                    prefixIcon: const Icon(Icons.person),
                    border: const OutlineInputBorder(),
                  ),
                  onChanged: (_) => setState(() => _xtreamError = null),
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
                  onChanged: (_) => setState(() => _xtreamError = null),
                ),
                const SizedBox(height: 28),
                FilledButton.icon(
                  onPressed: _addingXtream ? null : _addFromXtream,
                  icon: _addingXtream
                      ? const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(
                              strokeWidth: 2, color: Colors.white),
                        )
                      : const Icon(Icons.add),
                  label: Text(l10n.add),
                ),
              ],
            ),
          ),

          // ── Browse tab (IPTV.org content) ─────────────────────────────────
          _buildBrowseTab(),
        ],
      ),
    );
  }

  Widget _buildBrowseTab() {
    final theme = Theme.of(context);
    final l10n = AppLocalizations.of(context)!;

    if (_browseLoading) {
      return const Center(child: CircularProgressIndicator());
    }

    if (_browseError != null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.cloud_off, size: 48, color: theme.colorScheme.outline),
            const SizedBox(height: 12),
            Text('Could not reach IPTV.org',
                style: theme.textTheme.titleMedium),
            const SizedBox(height: 4),
            Text(_browseError!,
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.colorScheme.outline),
                textAlign: TextAlign.center),
            const SizedBox(height: 16),
            FilledButton.icon(
                onPressed: _fetchBrowseData,
                icon: const Icon(Icons.refresh),
                label: const Text('Retry')),
          ],
        ),
      );
    }

    return SafeArea(
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 12, 12, 8),
            child: SegmentedButton<int>(
              showSelectedIcon: false,
              segments: const [
                ButtonSegment(
                    value: 0, icon: Icon(Icons.flag), label: Text('Countries')),
                ButtonSegment(
                    value: 1,
                    icon: Icon(Icons.language),
                    label: Text('Languages')),
                ButtonSegment(
                    value: 2,
                    icon: Icon(Icons.category),
                    label: Text('Categories')),
              ],
              selected: {_browseSelectedIndex},
              onSelectionChanged: (selection) {
                _browseSearchController.clear();
                setState(() => _browseSelectedIndex = selection.first);
              },
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
            child: TextField(
              controller: _browseSearchController,
              decoration: InputDecoration(
                hintText: [
                  'Search countries…',
                  'Search languages…',
                  'Search categories…'
                ][_browseSelectedIndex],
                prefixIcon: const Icon(Icons.search),
                suffixIcon: _browseSearchController.text.isNotEmpty
                    ? IconButton(
                        icon: const Icon(Icons.clear),
                        onPressed: () {
                          _browseSearchController.clear();
                          setState(() {});
                        },
                      )
                    : null,
                border:
                    OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                isDense: true,
              ),
              onChanged: (_) => setState(() {}),
            ),
          ),
          if (_isSelecting) ...[
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: LinearProgressIndicator(
                backgroundColor: theme.colorScheme.surfaceContainerHighest,
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
              child: Text(
                l10n.loadingCountry(_selectingName ?? ''),
                style: theme.textTheme.bodySmall,
              ),
            ),
          ],
          Expanded(
            child: IndexedStack(
              index: _browseSelectedIndex,
              children: [
                _buildCountriesList(),
                _buildLanguagesList(),
                _buildCategoriesList(),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildCountriesList() {
    final q = _browseSearchController.text.toLowerCase();
    final items = q.isEmpty
        ? IptvOrgService.countries
        : IptvOrgService.countries
            .where((c) => c.name.toLowerCase().contains(q))
            .toList();

    if (items.isEmpty) return _buildEmpty();

    return ListView.builder(
      padding: const EdgeInsets.symmetric(vertical: 4),
      itemCount: items.length,
      itemBuilder: (context, index) {
        final c = items[index];
        return ListTile(
          leading: _selectingName == c.name
              ? const SizedBox(
                  width: 28,
                  height: 28,
                  child: CircularProgressIndicator(strokeWidth: 2))
              : Text(c.flag, style: const TextStyle(fontSize: 26)),
          title: Text(c.name, overflow: TextOverflow.ellipsis),
          onTap: _isSelecting
              ? null
              : () =>
                  _selectBrowseSource(c.name, c.m3uUrl, c.code.toLowerCase()),
        );
      },
    );
  }

  Widget _buildLanguagesList() {
    final q = _browseSearchController.text.toLowerCase();
    final items = q.isEmpty
        ? IptvOrgService.languages
        : IptvOrgService.languages
            .where(
                (l) => l.name.toLowerCase().contains(q) || l.code.contains(q))
            .toList();

    if (items.isEmpty) return _buildEmpty();

    return ListView.builder(
      padding: const EdgeInsets.symmetric(vertical: 4),
      itemCount: items.length,
      itemBuilder: (context, index) {
        final l = items[index];
        return ListTile(
          leading: _selectingName == l.name
              ? const SizedBox(
                  width: 28,
                  height: 28,
                  child: CircularProgressIndicator(strokeWidth: 2))
              : _LangBadge(code: l.code),
          title: Text(l.name, overflow: TextOverflow.ellipsis),
          onTap: _isSelecting
              ? null
              : () => _selectBrowseSource(l.name, l.m3uUrl, l.code),
        );
      },
    );
  }

  Widget _buildCategoriesList() {
    final q = _browseSearchController.text.toLowerCase();
    final items = q.isEmpty
        ? IptvOrgService.categories
        : IptvOrgService.categories
            .where((c) => c.name.toLowerCase().contains(q))
            .toList();

    if (items.isEmpty) return _buildEmpty();

    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Wrap(
        spacing: 8,
        runSpacing: 8,
        children: items.map((cat) {
          final loading = _selectingName == cat.id;
          return ActionChip(
            avatar: loading
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2))
                : Icon(_categoryIcons[cat.id] ?? Icons.tv),
            label: Text(cat.name),
            onPressed: _isSelecting
                ? null
                : () => _selectBrowseSource(cat.name, cat.m3uUrl, cat.id),
          );
        }).toList(),
      ),
    );
  }

  Widget _buildEmpty() {
    final theme = Theme.of(context);
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.search_off, size: 48, color: theme.colorScheme.outline),
          const SizedBox(height: 8),
          Text('No results for "${_browseSearchController.text}"',
              style: theme.textTheme.bodyMedium
                  ?.copyWith(color: theme.colorScheme.outline)),
        ],
      ),
    );
  }

  static const _categoryIcons = {
    'animation': Icons.animation,
    'auto': Icons.directions_car,
    'business': Icons.business_center,
    'classic': Icons.history_edu,
    'comedy': Icons.sentiment_very_satisfied,
    'cooking': Icons.restaurant,
    'culture': Icons.museum,
    'documentary': Icons.video_library,
    'education': Icons.school,
    'entertainment': Icons.theaters,
    'family': Icons.people,
    'fashion': Icons.style,
    'food': Icons.fastfood,
    'general': Icons.tv,
    'health': Icons.favorite,
    'history': Icons.history,
    'hobby': Icons.sports_esports,
    'interactive': Icons.touch_app,
    'kids': Icons.child_care,
    'legislative': Icons.account_balance,
    'lifestyle': Icons.spa,
    'local': Icons.location_city,
    'movies': Icons.movie,
    'music': Icons.music_note,
    'nature': Icons.nature,
    'news': Icons.article,
    'outdoor': Icons.park,
    'pets': Icons.pets,
    'police': Icons.local_police,
    'public': Icons.public,
    'relax': Icons.self_improvement,
    'religious': Icons.star,
    'science': Icons.science,
    'sci-fi': Icons.science,
    'series': Icons.view_list,
    'shop': Icons.shopping_bag,
    'sports': Icons.sports,
    'travel': Icons.flight,
    'weather': Icons.cloud,
  };
}

class _LangBadge extends StatelessWidget {
  final String code;
  const _LangBadge({required this.code});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      width: 40,
      height: 26,
      decoration: BoxDecoration(
        color: theme.colorScheme.primaryContainer,
        borderRadius: BorderRadius.circular(6),
      ),
      alignment: Alignment.center,
      child: Text(
        code.toUpperCase(),
        style: TextStyle(
          color: theme.colorScheme.onPrimaryContainer,
          fontSize: 11,
          fontWeight: FontWeight.bold,
          letterSpacing: 0.5,
        ),
      ),
    );
  }
}
