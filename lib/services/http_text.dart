import 'dart:convert';

import 'package:http/http.dart' as http;

/// Decodes a response body as UTF-8 regardless of what the server claimed.
///
/// `http.Response.body` decodes using the charset from the response's
/// `Content-Type`, and **falls back to Latin-1 when no charset is given** — which
/// is the common case for the feeds this app reads. iptv-org serves playlists as
/// `audio/x-mpegurl` with no charset at all, so every byte above 0x7F came out
/// wrong: a channel genuinely named "Peer TV Südtirol" (valid UTF-8 in the
/// source, `S` + 0xC3 0xBC + `dtirol`) rendered as "Peer TV SÃ¼dtirol".
///
/// Xtream panels are third-party PHP servers whose headers we cannot predict, so
/// they carry the same risk. iptv-org's JSON API does send `charset=utf-8` today
/// and decodes correctly without this — but that is someone else's header, not a
/// guarantee, so it goes through here too.
///
/// [allowMalformed] is on deliberately. A feed that really is Latin-1 would
/// otherwise throw and fail the whole import; turning a few bytes into U+FFFD is
/// a far better outcome than a playlist that refuses to load. Do not "tighten"
/// this to strict decoding: these are third-party feeds of unknown encoding, and
/// strictness here turns a cosmetic glitch into a failed import.
String utf8Body(http.Response response) =>
    utf8.decode(response.bodyBytes, allowMalformed: true);
