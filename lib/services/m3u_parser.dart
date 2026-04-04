import 'dart:async';
import 'package:http/http.dart' as http;
import '../config/config.dart';

class M3UChannel {
  final String id;
  final String name;
  final String? logo;
  final String? group;
  final String url;
  final double duration;
  final String? licenseType;
  final String? licenseKey;
  final String playlistId;

  M3UChannel({
    required this.id,
    required this.name,
    this.logo,
    this.group,
    required this.url,
    this.duration = -1,
    this.licenseType,
    this.licenseKey,
    this.playlistId = '',
  });

  String get uniqueId {
    if (url.isNotEmpty) {
      return url.hashCode.abs().toString();
    }
    return '${playlistId}_$name'.hashCode.abs().toString();
  }

  Channel toChannel(String playlistId) {
    return Channel(
      name: name,
      url: url,
      logo: logo,
      group: group,
      playlistId: playlistId,
      type: ChannelType.live,
    );
  }
}

class M3UParser {
  static final RegExp _infoRegex = RegExp(r'(-?\d+)(.*),(.+)');
  static final RegExp _kodiPropRegex = RegExp(r'([^=]+)=(.+)');
  static final RegExp _metadataRegex = RegExp(r'([\w-_.]+)=\s*(?:"([^"]*)"|(\S+))');

  static const String _M3U_HEADER_MARK = '#EXTM3U';
  static const String _M3U_INFO_MARK = '#EXTINF:';
  static const String _KODI_MARK = '#KODIPROP:';

  static const String _M3U_TVG_LOGO_MARK = 'tvg-logo';
  static const String _M3U_TVG_ID_MARK = 'tvg-id';
  static const String _M3U_TVG_NAME_MARK = 'tvg-name';
  static const String _M3U_GROUP_TITLE_MARK = 'group-title';

  static const String _KODI_LICENSE_TYPE = 'inputstream.adaptive.license_type';
  static const String _KODI_LICENSE_KEY = 'inputstream.adaptive.license_key';

  static Stream<M3UChannel> parseStream(String url, String playlistId) async* {
    final response = await http.get(Uri.parse(url));
    
    if (response.statusCode != 200) {
      throw Exception('Failed to load playlist: ${response.statusCode}');
    }

    yield* _parseLines(response.body.split('\n'), playlistId);
  }

  static Stream<M3UChannel> parseFromString(String content, String playlistId) {
    return _parseLines(content.split('\n'), playlistId);
  }

  static Stream<M3UChannel> _parseLines(List<String> lines, String playlistId) {
    return Stream.fromIterable(_parseLinesSync(lines, playlistId));
  }

  static List<M3UChannel> _parseLinesSync(List<String> lines, String playlistId) {
    final channels = <M3UChannel>[];
    
    String? currentLine;
    Match? infoMatch;
    final kodiMatches = <Match>[];
    bool skipHeader = true;

    for (int i = 0; i < lines.length; i++) {
      currentLine = lines[i].trimRight();
      
      if (skipHeader && currentLine.startsWith(_M3U_HEADER_MARK)) {
        skipHeader = false;
        continue;
      }

      if (currentLine.isEmpty) continue;

      while (currentLine!.startsWith('#')) {
        if (currentLine.startsWith(_M3U_INFO_MARK)) {
          infoMatch = _infoRegex.firstMatch(
            currentLine.substring(_M3U_INFO_MARK.length).trim(),
          );
        }
        if (currentLine.startsWith(_KODI_MARK)) {
          final match = _kodiPropRegex.firstMatch(currentLine.substring(_KODI_MARK.length).trim());
          if (match != null) kodiMatches.add(match);
        }
        
        if (i + 1 >= lines.length) break;
        i++;
        currentLine = lines[i].trimRight();
      }

      if (infoMatch == null || currentLine!.isEmpty || currentLine.startsWith('#')) continue;

      final title = infoMatch.group(3)?.trim() ?? '';
      final duration = double.tryParse(infoMatch.group(1) ?? '-1') ?? -1;

      final metadata = <String, String>{};
      final text = infoMatch.group(2)?.trim() ?? '';
      final metadataMatches = _metadataRegex.allMatches(text);
      for (final match in metadataMatches) {
        final key = match.group(1)?.trim();
        final value = match.group(2)?.trim();
        if (key != null && value != null && value.isNotEmpty) {
          metadata[key] = value;
        }
      }

      final kodiMetadata = <String, String?>{};
      for (final match in kodiMatches) {
        final key = match.group(1)?.trim();
        final value = match.group(2)?.trim();
        if (key != null && value != null && value.isNotEmpty) {
          kodiMetadata[key] = value;
        }
      }

      final name = metadata[_M3U_TVG_NAME_MARK]?.isNotEmpty == true
          ? metadata[_M3U_TVG_NAME_MARK]!
          : title;

      channels.add(M3UChannel(
        id: metadata[_M3U_TVG_ID_MARK] ?? '',
        name: name,
        logo: metadata[_M3U_TVG_LOGO_MARK],
        group: metadata[_M3U_GROUP_TITLE_MARK],
        url: currentLine,
        duration: duration,
        licenseType: kodiMetadata[_KODI_LICENSE_TYPE],
        licenseKey: kodiMetadata[_KODI_LICENSE_KEY],
        playlistId: playlistId,
      ));

      infoMatch = null;
      kodiMatches.clear();
    }

    return channels;
  }

  static Future<List<Channel>> parse(String url, [String playlistId = '']) async {
    final channels = <Channel>[];
    
    await for (final m3uChannel in parseStream(url, playlistId)) {
      channels.add(m3uChannel.toChannel(playlistId));
    }
    
    return channels;
  }

  static List<Channel> parseSync(String content, [String playlistId = '']) {
    return _parseLinesSync(content.split('\n'), playlistId)
        .map((m3u) => m3u.toChannel(playlistId))
        .toList();
  }
}
