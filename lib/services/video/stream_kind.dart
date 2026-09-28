import 'stream_format_hint.dart';

/// What a channel's stream carries, as far as pre-open evidence can tell.
enum StreamKind { audioOnly, video, unknown }

/// How much to trust a [StreamKind] verdict.
///
/// Only a [strong] [StreamKind.audioOnly] verdict is allowed to lock a
/// channel into audio mode with no video toggle. Everything else — including
/// a [provisional] audio verdict — opens as video, so a wrong guess is never
/// worse than today's behaviour.
enum KindConfidence { strong, provisional }

/// Where a [StreamKindVerdict] came from, for logging and for choosing how
/// long a cached verdict should live.
enum KindSource {
  /// The M3U `radio="true"` attribute — instant, no network.
  radioAttribute,

  /// A response's `Content-Type` header.
  contentType,

  /// An `icy-*` response header, with no usable `Content-Type`.
  icyHeader,

  /// `dart:io`'s `HttpClient` failed to parse the response as HTTP at all —
  /// the fingerprint of a legacy Shoutcast v1 server's raw `ICY 200 OK`
  /// status line.
  icyException,

  /// An HLS master playlist's `EXT-X-STREAM-INF` attributes.
  hlsMasterCodecs,

  /// An HLS media playlist's segment URIs.
  hlsMediaPlaylist,

  /// No usable evidence was found.
  unknown,
}

/// A classification verdict for one channel's stream, with enough provenance
/// to decide whether it's trustworthy enough to lock audio mode and how long
/// it should stay cached.
class StreamKindVerdict {
  final StreamKind kind;
  final KindConfidence confidence;
  final KindSource source;

  const StreamKindVerdict(this.kind, this.confidence, this.source);

  /// The verdict for "no evidence either way" — every probe and classifier
  /// falls back to this rather than to `null`, so callers never need a
  /// separate absent-verdict branch.
  static const StreamKindVerdict unknown = StreamKindVerdict(
    StreamKind.unknown,
    KindConfidence.provisional,
    KindSource.unknown,
  );

  /// Whether this verdict is trustworthy enough to lock the player into
  /// audio mode with no way back to video. Only a strong audio verdict
  /// qualifies — a provisional one (an HLS master with plausible-looking but
  /// unconfirmed audio CODECS, e.g. a TV channel whose playlist omits its own
  /// video codec) opens as video instead, exactly like an unknown one.
  bool get locksAudio =>
      kind == StreamKind.audioOnly && confidence == KindConfidence.strong;

  @override
  String toString() => '${kind.name}/${confidence.name} via ${source.name}';

  @override
  bool operator ==(Object other) =>
      other is StreamKindVerdict &&
      other.kind == kind &&
      other.confidence == confidence &&
      other.source == source;

  @override
  int get hashCode => Object.hash(kind, confidence, source);
}

/// The bandwidth ceiling, in bits per second, below which an all-audio-CODECS
/// HLS master is plausible as a real radio station. Measured census radios
/// (Radio 24, Capital, Deejay, ...) sit at 65-320 kbps; a channel like LaC
/// News 24 that declares audio-only CODECS at 3.5 Mbps is a TV playlist that
/// simply omits its video codec, not a radio station, and must stay
/// provisional rather than lock audio mode.
const int kMaxPlausibleAudioBandwidth = 512000;

/// Classifies a non-HLS response from its headers alone: an `audio/*`
/// `Content-Type` (not one of the HLS aliases) or an `icy-*` header both mean
/// strong audio; a `video/*` `Content-Type` means video; anything else is
/// [StreamKindVerdict.unknown] and leaves the HLS-playlist classifier
/// (below) or the engine to decide.
StreamKindVerdict classifyResponseHeaders({
  required String? contentType,
  required Map<String, String> headers,
}) {
  if (contentType != null && isProgressiveAudioMime(contentType)) {
    return const StreamKindVerdict(
      StreamKind.audioOnly,
      KindConfidence.strong,
      KindSource.contentType,
    );
  }
  if (headers.keys.any((name) => name.toLowerCase().startsWith('icy-'))) {
    return const StreamKindVerdict(
      StreamKind.audioOnly,
      KindConfidence.strong,
      KindSource.icyHeader,
    );
  }
  if (contentType != null && isProgressiveVideoMime(contentType)) {
    return const StreamKindVerdict(
      StreamKind.video,
      KindConfidence.strong,
      KindSource.contentType,
    );
  }
  return StreamKindVerdict.unknown;
}

/// One `EXT-X-STREAM-INF` variant's attributes, as far as classification
/// needs them.
class _Variant {
  final int? bandwidth;
  final String? codecs;
  final bool hasResolution;

  const _Variant({this.bandwidth, this.codecs, required this.hasResolution});
}

/// Classifies HLS playlist text — either a master (one or more
/// `EXT-X-STREAM-INF` variants) or a media playlist (a flat list of
/// segments) — per REQ-03:
///
/// - Master: a `RESOLUTION` attribute, a video codec, or an
///   `EXT-X-MEDIA:TYPE=VIDEO` rendition means video. An all-audio-CODECS
///   master with no `RESOLUTION` is strong audio at or under
///   [kMaxPlausibleAudioBandwidth], provisional above it. A master with no
///   `CODECS` attribute at all is unknown.
/// - Media playlist: segments that all look like packed audio (reusing
///   [guessStreamFormat]'s suffix table, so a `.mp3`/`.aac`/etc segment list
///   counts and a `.ts`/`.m4s` one doesn't) are strong audio; anything else
///   is unknown.
StreamKindVerdict classifyHlsPlaylist(String playlistText) {
  if (playlistText.contains('#EXT-X-STREAM-INF:')) {
    return _classifyMaster(playlistText);
  }
  return _classifyMediaPlaylist(playlistText);
}

StreamKindVerdict _classifyMaster(String playlistText) {
  final variants = _parseStreamInfVariants(playlistText);
  if (variants.isEmpty) return StreamKindVerdict.unknown;

  var anyResolution = false;
  var anyVideoCodec = false;
  var anyCodecsMissing = false;
  var allCodecsAudioOnly = true;
  int? maxBandwidth;

  for (final variant in variants) {
    if (variant.hasResolution) anyResolution = true;
    final codecsAttr = variant.codecs;
    if (codecsAttr == null || codecsAttr.isEmpty) {
      anyCodecsMissing = true;
      allCodecsAudioOnly = false;
    } else {
      for (final codec in codecsAttr.split(',')) {
        final trimmed = codec.trim();
        if (trimmed.isEmpty) continue;
        if (_isVideoCodec(trimmed)) anyVideoCodec = true;
        if (!_isAudioCodec(trimmed)) allCodecsAudioOnly = false;
      }
    }
    if (variant.bandwidth != null) {
      maxBandwidth = maxBandwidth == null
          ? variant.bandwidth
          : (variant.bandwidth! > maxBandwidth ? variant.bandwidth : maxBandwidth);
    }
  }

  final anyVideoMedia = RegExp(
    r'#EXT-X-MEDIA:.*TYPE=VIDEO',
    caseSensitive: false,
  ).hasMatch(playlistText);

  if (anyResolution || anyVideoCodec || anyVideoMedia) {
    return const StreamKindVerdict(
      StreamKind.video,
      KindConfidence.strong,
      KindSource.hlsMasterCodecs,
    );
  }
  if (anyCodecsMissing || !allCodecsAudioOnly) {
    return StreamKindVerdict.unknown;
  }

  // Every variant declares only audio codecs and no RESOLUTION. Bandwidth
  // decides whether that's plausible as a real radio station or a TV
  // playlist that simply left its video codec out (the LaC News 24 case).
  // A master with no BANDWIDTH on any variant can't be checked against the
  // guard at all, so it stays unknown rather than assumed plausible.
  if (maxBandwidth == null) return StreamKindVerdict.unknown;
  return StreamKindVerdict(
    StreamKind.audioOnly,
    maxBandwidth <= kMaxPlausibleAudioBandwidth
        ? KindConfidence.strong
        : KindConfidence.provisional,
    KindSource.hlsMasterCodecs,
  );
}

StreamKindVerdict _classifyMediaPlaylist(String playlistText) {
  final uris = _segmentUris(playlistText);
  if (uris.isEmpty) return StreamKindVerdict.unknown;

  final allPackedAudio =
      uris.every((uri) => guessStreamFormat(uri) == StreamFormatHint.audio);
  if (allPackedAudio) {
    return const StreamKindVerdict(
      StreamKind.audioOnly,
      KindConfidence.strong,
      KindSource.hlsMediaPlaylist,
    );
  }
  return StreamKindVerdict.unknown;
}

List<String> _segmentUris(String playlistText) {
  return [
    for (final rawLine in playlistText.split(RegExp(r'\r?\n')))
      if (rawLine.trim().isNotEmpty && !rawLine.trim().startsWith('#'))
        rawLine.trim(),
  ];
}

List<_Variant> _parseStreamInfVariants(String playlistText) {
  const marker = '#EXT-X-STREAM-INF:';
  final variants = <_Variant>[];
  for (final rawLine in playlistText.split(RegExp(r'\r?\n'))) {
    final line = rawLine.trim();
    if (!line.startsWith(marker)) continue;
    final attrs = _parseAttributeList(line.substring(marker.length));
    final bandwidthStr = attrs['BANDWIDTH'];
    variants.add(_Variant(
      bandwidth: bandwidthStr != null ? int.tryParse(bandwidthStr) : null,
      codecs: attrs['CODECS'],
      hasResolution: attrs.containsKey('RESOLUTION'),
    ));
  }
  return variants;
}

/// Splits an `EXT-X-STREAM-INF` attribute list on commas that aren't inside a
/// quoted value — `CODECS="mp4a.40.2,avc1.640028"` must not be split at the
/// comma between the two codecs.
Map<String, String> _parseAttributeList(String attrsText) {
  final result = <String, String>{};
  final parts = <String>[];
  final buffer = StringBuffer();
  var inQuotes = false;
  for (var i = 0; i < attrsText.length; i++) {
    final char = attrsText[i];
    if (char == '"') inQuotes = !inQuotes;
    if (char == ',' && !inQuotes) {
      parts.add(buffer.toString());
      buffer.clear();
    } else {
      buffer.write(char);
    }
  }
  if (buffer.isNotEmpty) parts.add(buffer.toString());

  for (final part in parts) {
    final eq = part.indexOf('=');
    if (eq == -1) continue;
    final key = part.substring(0, eq).trim().toUpperCase();
    var value = part.substring(eq + 1).trim();
    if (value.length >= 2 && value.startsWith('"') && value.endsWith('"')) {
      value = value.substring(1, value.length - 1);
    }
    result[key] = value;
  }
  return result;
}

bool _isAudioCodec(String codec) {
  final c = codec.toLowerCase();
  return c.startsWith('mp4a') ||
      c.startsWith('ac-3') ||
      c.startsWith('ec-3') ||
      c.startsWith('opus') ||
      c.startsWith('mp3') ||
      c.startsWith('vorbis') ||
      c.startsWith('flac') ||
      c.startsWith('alac');
}

bool _isVideoCodec(String codec) {
  final c = codec.toLowerCase();
  return c.startsWith('avc1') ||
      c.startsWith('avc3') ||
      c.startsWith('hev1') ||
      c.startsWith('hvc1') ||
      c.startsWith('av01') ||
      c.startsWith('vp09') ||
      c.startsWith('vp8') ||
      c.startsWith('mp4v') ||
      c.startsWith('dvh1') ||
      c.startsWith('dvhe');
}
