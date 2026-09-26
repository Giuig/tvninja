import 'package:flutter_test/flutter_test.dart';
import 'package:tvninja/services/video/stream_diagnostics.dart';

/// Pins the wording both players show for a failed stream.
///
/// The video path and the native audio path both take their message from
/// `StreamDiagnostics.userMessage`, and `player_page.dart`'s `_errorIcon()`
/// string-matches it to pick an icon. So a wording change here is a behaviour
/// change there — these tests make it a deliberate one.
void main() {
  test('dead or gated streams get a specific message', () {
    expect(StreamDiagnostics.userMessage(StreamProbeResult.notFound),
        'Stream not found (404)');
    expect(StreamDiagnostics.userMessage(StreamProbeResult.forbidden),
        'Access denied (403)');
    expect(StreamDiagnostics.userMessage(StreamProbeResult.unauthorized),
        'Authentication required (401)');
    expect(StreamDiagnostics.userMessage(StreamProbeResult.networkError),
        'Network error — check your connection');
  });

  test('inconclusive probes leave the caller its own fallback', () {
    for (final r in [
      StreamProbeResult.ok,
      StreamProbeResult.serverError,
      StreamProbeResult.unknown,
    ]) {
      expect(StreamDiagnostics.userMessage(r), isNull, reason: '$r');
    }
  });

  test('only answers that retrying cannot change count as permanent', () {
    final permanent =
        StreamProbeResult.values.where(StreamDiagnostics.isPermanent).toSet();
    expect(permanent, {
      StreamProbeResult.notFound,
      StreamProbeResult.forbidden,
      StreamProbeResult.unauthorized,
    });
  });
}
