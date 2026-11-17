import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

// The proxy loader lives inside a JS string in web_video_player_web.dart, which
// flutter test cannot run. test/web_proxy_loader.test.js runs that exact block in
// node; this wrapper makes the existing `flutter test` CI step run it too.
void main() {
  test('web proxy loader JS (node test)', () async {
    final probe = await Process.run('node', ['--version'], runInShell: true)
        .catchError((_) => ProcessResult(0, 127, '', ''));
    if (probe.exitCode != 0) {
      // A missing node must not turn CI green silently.
      if (Platform.environment['CI'] != null) {
        fail('node is required to run test/web_proxy_loader.test.js');
      }
      markTestSkipped('node not installed');
      return;
    }
    final r = await Process.run(
      'node',
      ['--test', 'test/web_proxy_loader.test.js'],
      runInShell: true,
    );
    expect(r.exitCode, 0, reason: '${r.stdout}\n${r.stderr}');
  });
}
