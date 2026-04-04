import 'package:flutter/foundation.dart';
import 'package:media_kit/media_kit.dart';
import 'package:device_info_plus/device_info_plus.dart';

/// Cached emulator detection result — computed once per app session.
bool? _cachedIsEmulator;

/// Applies libmpv options tuned for live IPTV/HLS streams.
///
/// Key settings:
/// - Small forward cache (live streams can't prefill much)
/// - Zero back-buffer (prevents demuxer from replaying old audio packets
///   at TS segment boundaries — the root cause of "audio repeating chunks")
/// - cache-pause disabled (live cache is always "low"; pausing causes
///   micro-stutters when the audio pipeline resets on resume)
/// - Auto-reconnect on network drops
/// - Emulator-aware: disables hardware decode on emulators to prevent freeze
Future<void> applyLiveStreamMpvOptions(Player player) async {
  if (kIsWeb) return;
  try {
    final native = player.platform as dynamic;
    // Cache — slightly increased for faster initial connection
    native.setProperty('cache', 'yes');
    native.setProperty('cache-secs', '6');
    native.setProperty('demuxer-max-bytes', '8MiB');
    // CRITICAL: no back-buffer — prevents TS demuxer from replaying old
    // audio packets when it re-reads across segment boundaries
    native.setProperty('demuxer-max-back-bytes', '0');
    // CRITICAL: never pause on low cache (live streams can't prefill)
    native.setProperty('cache-pause', 'no');
    native.setProperty('cache-pause-initial', 'no');
    // Reduced network timeout for faster initial connection failure
    native.setProperty('network-timeout', '5');
    native.setProperty('reconnect-streamed', 'yes');
    native.setProperty('reconnect-delay-max', '2');
    // Low retry count so mpv surfaces errors to Dart quickly; app-level
    // _scheduleReconnect() handles the real backoff with UI state updates
    native.setProperty('reconnect-max-retries', '2');
    // Limit lavf probing — fallback for streams whose format can't be guessed
    // from the URL. applyFormatHint() sets demuxer-lavf-format before open()
    // to skip probing entirely for known formats (.m3u8 → hls, .ts → mpegts).
    native.setProperty('demuxer-lavf-probesize', '250000');
    native.setProperty('demuxer-lavf-analyzeduration', '250000');

    // Emulator-aware hardware decode: disable on emulators to prevent freeze.
    // Result is cached after the first call — DeviceInfoPlugin is an async
    // platform call and running it on every Player() creation adds 50-150 ms.
    _cachedIsEmulator ??= await _isEmulator();
    if (_cachedIsEmulator!) {
      native.setProperty('hwdec', 'no');
      native.setProperty('vd-lavc-threads', '4');
      native.setProperty('framedrop', 'vo');
    } else {
      native.setProperty('hwdec', 'auto-safe');
      // Fast decoder path — skips non-essential steps; imperceptible quality
      // difference on compressed live TV content.
      native.setProperty('vd-lavc-fast', 'yes');
    }
  } catch (_) {
    // Non-fatal: platform doesn't support setProperty
  }
}

/// Sets `demuxer-lavf-format` on [player] based on [url]'s path suffix so
/// libav can skip format probing entirely (saves 200-600 ms on each open).
///
/// Synchronous — no async/await so it doesn't yield to the event loop before
/// player.open() is called (an unnecessary 50-100 ms penalty on each switch).
void applyFormatHint(Player player, String url) {
  if (kIsWeb) return;
  try {
    final native = player.platform as dynamic;
    final fmt = _guessFormat(url);
    native.setProperty('demuxer-lavf-format', fmt ?? '');
  } catch (_) {}
}

/// Infers the libav demuxer name from [url]'s path, or null if ambiguous.
String? _guessFormat(String url) {
  final path = Uri.tryParse(url)?.path.toLowerCase() ?? url.toLowerCase();
  if (path.endsWith('.m3u8') || path.contains('.m3u8?')) return 'hls';
  if (path.endsWith('.ts') || path.contains('.ts?')) return 'mpegts';
  if (path.endsWith('.mp4') || path.contains('.mp4?')) return 'mp4';
  return null;
}

/// Detects if the app is running on an emulator.
/// Checks multiple signals since some emulators spoof isPhysicalDevice.
Future<bool> _isEmulator() async {
  try {
    final deviceInfo = DeviceInfoPlugin();
    final androidInfo = await deviceInfo.androidInfo;

    // Debug: log device info for troubleshooting
    debugPrint(
        '[MPV] Device: ${androidInfo.model}, product: ${androidInfo.product}');

    // Basic check (may be spoofed by some emulators)
    if (androidInfo.isPhysicalDevice == false) return true;

    // Check for emulator indicators in device properties
    final model = androidInfo.model.toLowerCase();
    final product = androidInfo.product.toLowerCase();
    final hardware = androidInfo.hardware.toLowerCase();
    final board = androidInfo.board.toLowerCase();
    final brand = androidInfo.brand.toLowerCase();
    final device = androidInfo.device.toLowerCase();
    final host = androidInfo.host.toLowerCase();
    final fingerprint = androidInfo.fingerprint.toLowerCase();

    // Check for suspicious product suffixes (xxx often indicates spoofed)
    if (product.endsWith('xxx') || product.endsWith('userdebug')) {
      return true;
    }

    // Common emulator indicators
    final emulatorIndicators = [
      'generic', // Generic device
      'emulator', // Explicit emulator
      'sdk', // SDK build
      'goldfish', // Android emulator
      'ranchu', // Android emulator
      'vbox', // VirtualBox
      'nox', // NoxPlayer
      'bluestacks', // BlueStacks
      'bst', // BlueStacks short
      'vbox86', // VirtualBox x86
      'ttvm_x86', // TTVM emulator
      'msi', // MSI App Player (BlueStacks-based, reports as msi)
      'ldplayer', // LDPlayer
    ];

    final allChecks =
        '$model $product $hardware $board $brand $device $host $fingerprint';

    for (final indicator in emulatorIndicators) {
      if (allChecks.contains(indicator)) {
        return true;
      }
    }

    return false;
  } catch (_) {
    return false; // If detection fails, assume real device
  }
}
