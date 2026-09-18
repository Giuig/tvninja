import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:tvninja/services/http_text.dart';

/// Pins the bug that made every accented channel name render wrong.
///
/// `http.Response.body` picks its codec from the response's `Content-Type` and
/// falls back to **Latin-1** when no charset is given. iptv-org serves playlists
/// as `audio/x-mpegurl` with no charset, so "Peer TV Südtirol" arrived as
/// "Peer TV SÃ¼dtirol". These tests assert the difference directly rather than
/// trusting that the helper "looks right".
void main() {
  // The real bytes, as they sit in the playlist: S + 0xC3 0xBC + dtirol.
  final sudtirolUtf8 = utf8.encode('Peer TV Südtirol (1080p)');

  test('response.body mis-decodes UTF-8 when the server sends no charset', () {
    final response = http.Response.bytes(
      sudtirolUtf8,
      200,
      headers: {'content-type': 'audio/x-mpegurl'}, // exactly what iptv-org sends
    );

    // This is the bug, asserted so nobody "fixes" the helper away later.
    expect(response.body, contains('SÃ¼dtirol'));
    expect(response.body, isNot(contains('Südtirol')));
  });

  test('utf8Body decodes it correctly despite the missing charset', () {
    final response = http.Response.bytes(
      sudtirolUtf8,
      200,
      headers: {'content-type': 'audio/x-mpegurl'},
    );

    expect(utf8Body(response), 'Peer TV Südtirol (1080p)');
  });

  test('utf8Body still works when the server does declare utf-8', () {
    final response = http.Response.bytes(
      utf8.encode('{"name":"Saint Barthélemy"}'),
      200,
      headers: {'content-type': 'application/json; charset=utf-8'},
    );

    expect(utf8Body(response), '{"name":"Saint Barthélemy"}');
  });

  test('a genuinely malformed body degrades instead of throwing', () {
    // 0xFF is not valid UTF-8. A strict decode throws here, which would fail an
    // entire playlist import over one bad byte — hence allowMalformed.
    final response = http.Response.bytes(
      [0x52, 0x61, 0x69, 0xFF, 0x20, 0x31],
      200,
      headers: {'content-type': 'audio/x-mpegurl'},
    );

    expect(() => utf8Body(response), returnsNormally);
    expect(utf8Body(response), startsWith('Rai'));
    expect(utf8Body(response), endsWith(' 1'));
  });
}
