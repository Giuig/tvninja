import 'package:flutter/foundation.dart' show kDebugMode, kIsWeb, visibleForTesting;
import 'package:tvninja/config/config.dart';

/// Which channels the current platform can actually open.
///
/// ## Why this exists
///
/// A page served over `https` cannot load a plain-`http` stream at all: the
/// browser blocks it as mixed content *before any request is made*. Listing
/// such a channel is a promise the platform cannot keep — the user taps it,
/// waits, and gets a failure with no explanation.
///
/// Measured on the owner's JP playlist, 2026-11-18: of 219 entries, 101 were
/// plain http, on hosts that serve no TLS at all (98 of them one host, whose
/// port 443 refuses the connection and whose TLS on 8000 times out). None of
/// them can ever play on the hosted build, so the honest list is the one
/// without them — 13 entries that all work, rather than 219 of which 13 do.
///
/// This decides from the URL and the page scheme alone: no network call, no
/// probe, no cache, and correct for any playlist the user adds.
///
/// ## What it deliberately does NOT do
///
/// It cannot hide the https streams that answer without an
/// `Access-Control-Allow-Origin` header (12 in that same measurement). A CORS
/// failure is opaque to the page by design — that is why
/// `StreamDiagnostics.probe` returns `unknown` on web. Detecting those needs a
/// server-side probe, which belongs to the playlist builder, not here.
List<Channel> visibleChannels(
  List<Channel> channels, {
  required bool blockPlainHttp,
}) {
  if (!blockPlainHttp) return channels;
  return channels.where((c) => !isPlainHttp(c.url)).toList();
}

/// Whether [url] is plain `http://`, which an https page can never load.
///
/// Case-insensitive because playlists are third-party text: `HTTP://` appears
/// in the wild, and a scheme comparison that misses it would let exactly the
/// channels this module exists to hide back into the list.
bool isPlainHttp(String url) => url.trimLeft().toLowerCase().startsWith('http://');

/// The `https://` form of a plain-http [url].
///
/// Exists because the obvious `replaceFirst('http://', 'https://')` is
/// case-sensitive: given `HTTP://host/x` it matches nothing and returns the URL
/// unchanged, so the caller adds the *same* URL again as its "upgraded"
/// candidate and silently retries a scheme that cannot work. Pairs with
/// [isPlainHttp], which accepts the same inputs — any URL that function calls
/// plain http, this one can upgrade.
///
/// Leading whitespace is dropped, for the same reason [isPlainHttp] ignores it.
String upgradeToHttps(String url) {
  final trimmed = url.trimLeft();
  return 'https://${trimmed.substring('http://'.length)}';
}

/// Whether this platform blocks plain-http streams.
///
/// **Keyed on the page scheme, not on "is this the web build".** Mixed content
/// is a property of the *page*: served from `http://localhost` during
/// development, or from any http host, these streams load perfectly well. A
/// `kIsWeb`-only check would hide ~101 JP channels in the owner's own
/// `flutter run -d chrome` sessions and make the live bug unreproducible
/// locally — the measurement notes from 2026-09 already recorded that split
/// ("a local http server sees all 47; the GitHub Pages build sees ~27").
///
/// `Uri.base` is the document URL on web and a `file:` URI on native, so this
/// needs no conditional import. The caller supplies [isWeb] (`kIsWeb`) so the
/// function stays pure and both branches are testable.
bool blocksPlainHttp({required bool isWeb, required Uri pageUri}) =>
    isWeb && pageUri.isScheme('https');

/// This platform's own answer to [blocksPlainHttp], read from `kIsWeb` and the
/// document URL.
///
/// The three call sites (the channel list, the favourites strip, and the
/// favourite tap handler) use this instead of composing the pure function by
/// hand, so they cannot drift apart — before this existed, the same
/// `blocksPlainHttp(isWeb: kIsWeb, pageUri: Uri.base)` expression was written
/// out three times, and one of them being wrong is exactly the bug class that
/// made a *hidden* favourite still playable: see
/// `player_page_initial_index_test.dart`.
///
/// It also makes the blocking branch reachable from a widget test. In a test
/// `kIsWeb` is `false` and `Uri.base` is a `file:` URI, so without a seam no
/// rendered widget could ever execute the https path — the pure functions
/// would be covered and the wiring would not. Set
/// [debugBlockPlainHttpOverride] to render it; see
/// `https_page_widgets_test.dart`.
bool platformBlocksPlainHttp() {
  if (kDebugMode && debugBlockPlainHttpOverride != null) {
    return debugBlockPlainHttpOverride!;
  }
  return blocksPlainHttp(isWeb: kIsWeb, pageUri: Uri.base);
}

/// Forces [platformBlocksPlainHttp]'s answer. Test-only, and null in
/// production.
///
/// Guarded by `kDebugMode` at the point of use as well as by
/// [visibleForTesting], so a stray assignment that somehow reached a release
/// build would still be inert rather than hiding channels for real users.
/// Modelled on Flutter's own `debugDefaultTargetPlatformOverride`, which
/// exists for the same reason: a platform-keyed branch is otherwise
/// untestable off that platform.
///
/// Tests MUST reset it in `tearDown` — it is global state, and leaving it set
/// would silently change every later test in the same process.
@visibleForTesting
bool? debugBlockPlainHttpOverride;
