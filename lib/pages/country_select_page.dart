import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:tvninja/config/config.dart';
import 'package:tvninja/l10n/app_localizations.dart';
import 'package:tvninja/services/iptv_org_service.dart';
import 'package:tvninja/services/m3u_parser.dart';

class CountrySelectPage extends StatefulWidget {
  const CountrySelectPage({super.key});

  @override
  State<CountrySelectPage> createState() => _CountrySelectPageState();
}

class _CountrySelectPageState extends State<CountrySelectPage>
    with SingleTickerProviderStateMixin {
  late final TabController _tabController;
  final TextEditingController _searchController = TextEditingController();

  bool _loading = false;
  String? _error;
  bool _isSelecting = false;
  String? _selectingName;

  // Icons for categories — pure UI metadata, not part of the API data
  static const Map<String, IconData> _categoryIcons = {
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

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 3, vsync: this);
    _tabController.addListener(() {
      if (!_tabController.indexIsChanging) {
        _searchController.clear();
        setState(() {});
      }
    });
    _fetch();
  }

  @override
  void dispose() {
    _tabController.dispose();
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _fetch() async {
    if (IptvOrgService.isLoaded) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      await IptvOrgService.fetchAll();
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _selectSource(String name, String url, String code) async {
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

  static const _searchHints = [
    'Search countries…',
    'Search languages…',
    'Search categories…',
  ];

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = AppLocalizations.of(context)!;

    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.browseIptvOrg),
        bottom: TabBar(
          controller: _tabController,
          tabs: const [
            Tab(icon: Icon(Icons.flag), text: 'Countries'),
            Tab(icon: Icon(Icons.language), text: 'Languages'),
            Tab(icon: Icon(Icons.category), text: 'Categories'),
          ],
        ),
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 12, 12, 8),
            child: TextField(
              controller: _searchController,
              decoration: InputDecoration(
                hintText: _searchHints[_tabController.index],
                prefixIcon: const Icon(Icons.search),
                suffixIcon: _searchController.text.isNotEmpty
                    ? IconButton(
                        icon: const Icon(Icons.clear),
                        onPressed: () {
                          _searchController.clear();
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
                AppLocalizations.of(context)!
                    .loadingCountry(_selectingName ?? ''),
                style: theme.textTheme.bodySmall,
              ),
            ),
          ],
          Expanded(
            child: Padding(
              padding: EdgeInsets.only(
                bottom: MediaQuery.of(context).padding.bottom,
              ),
              child: _loading
                  ? const Center(child: CircularProgressIndicator())
                  : _error != null
                      ? _buildError(theme)
                      : TabBarView(
                          controller: _tabController,
                          children: [
                            _buildCountriesTab(),
                            _buildLanguagesTab(),
                            _buildCategoriesTab(),
                          ],
                        ),
            ),
          ),
        ],
      ),
    );
  }

  // ── Error ──────────────────────────────────────────────────────────────────

  Widget _buildError(ThemeData theme) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.cloud_off, size: 48, color: theme.colorScheme.outline),
          const SizedBox(height: 12),
          Text(
            'Could not reach IPTV.org',
            style: theme.textTheme.titleMedium,
          ),
          const SizedBox(height: 4),
          Text(
            _error ?? '',
            style: theme.textTheme.bodySmall
                ?.copyWith(color: theme.colorScheme.outline),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 16),
          FilledButton.icon(
            onPressed: _fetch,
            icon: const Icon(Icons.refresh),
            label: const Text('Retry'),
          ),
        ],
      ),
    );
  }

  // ── Countries ──────────────────────────────────────────────────────────────

  Widget _buildCountriesTab() {
    final q = _searchController.text.toLowerCase();
    final items = q.isEmpty
        ? IptvOrgService.countries
        : IptvOrgService.countries
            .where((c) => c.name.toLowerCase().contains(q))
            .toList();

    if (items.isEmpty) return _buildEmpty();

    return LayoutBuilder(
      builder: (context, constraints) => GridView.builder(
        padding: const EdgeInsets.symmetric(vertical: 4),
        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: _listCols(constraints.maxWidth),
          mainAxisExtent: 56,
        ),
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
                : () => _selectSource(c.name, c.m3uUrl, c.code.toLowerCase()),
          );
        },
      ),
    );
  }

  // ── Languages ──────────────────────────────────────────────────────────────

  Widget _buildLanguagesTab() {
    final q = _searchController.text.toLowerCase();
    final items = q.isEmpty
        ? IptvOrgService.languages
        : IptvOrgService.languages
            .where(
                (l) => l.name.toLowerCase().contains(q) || l.code.contains(q))
            .toList();

    if (items.isEmpty) return _buildEmpty();

    return LayoutBuilder(
      builder: (context, constraints) => GridView.builder(
        padding: const EdgeInsets.symmetric(vertical: 4),
        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: _listCols(constraints.maxWidth),
          mainAxisExtent: 56,
        ),
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
                : () => _selectSource(l.name, l.m3uUrl, l.code),
          );
        },
      ),
    );
  }

  // ── Categories ─────────────────────────────────────────────────────────────

  Widget _buildCategoriesTab() {
    final q = _searchController.text.toLowerCase();
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
                : () => _selectSource(cat.name, cat.m3uUrl, cat.id),
          );
        }).toList(),
      ),
    );
  }

  // ── Helpers ────────────────────────────────────────────────────────────────

  Widget _buildEmpty() {
    final theme = Theme.of(context);
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.search_off, size: 48, color: theme.colorScheme.outline),
          const SizedBox(height: 8),
          Text(
            'No results for "${_searchController.text}"',
            style: theme.textTheme.bodyMedium
                ?.copyWith(color: theme.colorScheme.outline),
          ),
        ],
      ),
    );
  }

  int _listCols(double width) {
    if (width >= 900) return 3;
    if (width >= 600) return 2;
    return 1;
  }
}

// ── _LangBadge ────────────────────────────────────────────────────────────────

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
