import 'dart:convert';
import 'package:http/http.dart' as http;

class IptvCountry {
  final String code; // uppercase (e.g. "US")
  final String name;
  final String flag;

  const IptvCountry({required this.code, required this.name, required this.flag});

  String get m3uUrl =>
      'https://iptv-org.github.io/iptv/countries/${code.toLowerCase()}.m3u';
}

class IptvLanguage {
  final String code; // ISO 639-3 (e.g. "eng")
  final String name;

  const IptvLanguage({required this.code, required this.name});

  String get m3uUrl => 'https://iptv-org.github.io/iptv/languages/$code.m3u';
}

class IptvCategory {
  final String id; // e.g. "sports"
  final String name;

  const IptvCategory({required this.id, required this.name});

  String get m3uUrl => 'https://iptv-org.github.io/iptv/categories/$id.m3u';
}

class IptvOrgService {
  static const _base = 'https://iptv-org.github.io/api';

  static List<IptvCountry>? _countries;
  static List<IptvLanguage>? _languages;
  static List<IptvCategory>? _categories;

  static List<IptvCountry> get countries => _countries ?? [];
  static List<IptvLanguage> get languages => _languages ?? [];
  static List<IptvCategory> get categories => _categories ?? [];

  static bool get isLoaded =>
      _countries != null && _languages != null && _categories != null;

  /// Fetches all three endpoints in parallel. Safe to call multiple times —
  /// returns immediately if already cached.
  static Future<void> fetchAll() async {
    if (isLoaded) return;

    final responses = await Future.wait([
      http.get(Uri.parse('$_base/countries.json')),
      http.get(Uri.parse('$_base/languages.json')),
      http.get(Uri.parse('$_base/categories.json')),
    ]);

    for (final r in responses) {
      if (r.statusCode != 200) {
        throw Exception('IPTV.org API error ${r.statusCode}');
      }
    }

    final rawCountries =
        (jsonDecode(responses[0].body) as List).cast<Map<String, dynamic>>();
    final rawLanguages =
        (jsonDecode(responses[1].body) as List).cast<Map<String, dynamic>>();
    final rawCategories =
        (jsonDecode(responses[2].body) as List).cast<Map<String, dynamic>>();

    // Build set of language codes that appear in at least one country's
    // languages[] array. This filters 7,000+ ISO 639-3 codes down to the
    // ~250 languages that are actually spoken somewhere.
    final usedLangCodes = <String>{};
    for (final c in rawCountries) {
      final langs = (c['languages'] as List?)?.cast<String>() ?? [];
      usedLangCodes.addAll(langs);
    }

    _countries = rawCountries
        .map((c) => IptvCountry(
              code: c['code'] as String,
              name: c['name'] as String,
              flag: (c['flag'] as String?) ?? '',
            ))
        .toList()
      ..sort((a, b) => a.name.compareTo(b.name));

    _languages = rawLanguages
        .where((l) => usedLangCodes.contains(l['code']))
        .map((l) => IptvLanguage(
              code: l['code'] as String,
              name: l['name'] as String,
            ))
        .toList()
      ..sort((a, b) => a.name.compareTo(b.name));

    _categories = rawCategories
        .where((c) => c['id'] != 'xxx')
        .map((c) => IptvCategory(
              id: c['id'] as String,
              name: c['name'] as String,
            ))
        .toList()
      ..sort((a, b) => a.name.compareTo(b.name));
  }
}
