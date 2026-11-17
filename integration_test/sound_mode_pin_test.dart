// Sound mode opens the PINNED stream, proved on a device against real HLS.
//
// The other emulator tests play a progressive MP4 stand-in, so until this one
// existed nothing in CI ever exercised an HLS master at all — the pin could
// have regressed to opening the master and every check would still have been
// green.
//
// Fixtures live in integration_test/fixtures/ and are served by
// scripts/ci/serve_fixtures.py on the runner, which the hook starts on
// PIN_PORT; 10.0.2.2 is the emulator's alias for the runner's loopback.
// `test/ci_hls_fixture_test.dart` guards those files against the real
// classifier locally, so a failure here means the app, not the fixture.
//
// Deliberately NO unpinned control leg. An unpinned open would let mpv pick a
// variant of its own, which would put pin_v_high.m3u8 in the server log and
// destroy the hook's strongest assertion: that the high and mid variants are
// never fetched at all. The unpinned path is covered by
// test/sound_mode_service_test.dart and by the measured device run.
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:tvninja/services/native_audio_service.dart';
import 'package:tvninja/services/video/stream_kind_probe.dart';

const _base = String.fromEnvironment('E2E_PIN_BASE',
    defaultValue: 'http://10.0.2.2:8097');

Future<void> _waitPlaying(String what) async {
  final deadline = DateTime.now().add(const Duration(seconds: 40));
  while (!(NativeAudioService.currentState.isPlaying &&
      !NativeAudioService.isBuffering)) {
    if (DateTime.now().isAfter(deadline)) {
      debugPrint('E2E_PIN_FAILED $what never reported playing');
      fail('$what never reported playing');
    }
    await Future<void>.delayed(const Duration(milliseconds: 250));
  }
}

void main() {
  debugPrint = debugPrintSynchronously;
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  test('sound mode opens the pinned stream, not the master',
      timeout: const Timeout(Duration(minutes: 5)), () async {
    MediaKit.ensureInitialized();
    await NativeAudioService.initialize();

    // ---- a muxed multi-variant master: the lowest variant must win ----------
    final muxed = '$_base/pin_master.m3u8';
    final muxedProbe = await StreamKindProbe.probe(muxed, null);
    debugPrint('E2E_PIN_PROBE muxed verdict=${muxedProbe.verdict} '
        'pin=${muxedProbe.soundModeUri}');
    // The cheapest variant is listed LAST in the fixture, so "first wins"
    // fails here rather than passing by luck.
    expect(muxedProbe.soundModeUri, 'pin_v_low.m3u8');

    expect(
      await NativeAudioService.play(
        url: muxed,
        title: 'pin muxed',
        soundModeUri: muxedProbe.soundModeUri,
      ),
      isTrue,
      reason: 'play() refused the pinned muxed stream',
    );
    debugPrint('E2E_PIN_OPENED muxed=${NativeAudioService.debugOpenedUrl}');
    expect(NativeAudioService.debugOpenedUrl, endsWith('pin_v_low.m3u8'));
    expect(NativeAudioService.debugMasterUrl, muxed,
        reason: 'the master must be kept as the fallback');
    await _waitPlaying('the pinned low variant');
    debugPrint('E2E_PIN_LOW_PLAYING');
    expect(await NativeAudioService.stop(), isTrue);

    // ---- a master with a separate audio rendition: the rendition must win ---
    final rend = '$_base/pin_rend_master.m3u8';
    final rendProbe = await StreamKindProbe.probe(rend, null);
    debugPrint('E2E_PIN_PROBE rendition verdict=${rendProbe.verdict} '
        'pin=${rendProbe.soundModeUri}');
    expect(rendProbe.soundModeUri, 'pin_audio.m3u8',
        reason: 'a rendition costs no quality and must beat the cheap variant '
            'this fixture also offers');

    expect(
      await NativeAudioService.play(
        url: rend,
        title: 'pin rendition',
        soundModeUri: rendProbe.soundModeUri,
      ),
      isTrue,
      reason: 'play() refused the pinned rendition',
    );
    debugPrint('E2E_PIN_OPENED rendition=${NativeAudioService.debugOpenedUrl}');
    expect(NativeAudioService.debugOpenedUrl, endsWith('pin_audio.m3u8'));
    await _waitPlaying('the pinned audio rendition');
    debugPrint('E2E_PIN_RENDITION_PLAYING');
    expect(await NativeAudioService.stop(), isTrue);

    // The hook reads the fixture server's log after this marker and checks
    // that pin_v_high.m3u8 and pin_v_mid.m3u8 were never requested — evidence
    // from outside the app that nothing but the pinned playlist was fetched.
    debugPrint('E2E_PIN_DONE');
  });
}
