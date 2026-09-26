import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:tvninja/widgets/channel_logo.dart';

/// Pins which logos get the light tile.
///
/// The case that started it: TV8's logo is pure black on transparent and
/// disappeared on the app's dark surfaces. The other cases are the ones the
/// threshold must NOT catch, because a tile behind a logo that was already
/// readable is a visual change for nothing.
void main() {
  /// [count] pixels of one RGBA colour.
  Uint8List fill(int r, int g, int b, int a, int count) =>
      Uint8List.fromList([for (var i = 0; i < count; i++) ...[r, g, b, a]]);

  Uint8List join(List<Uint8List> parts) =>
      Uint8List.fromList([for (final p in parts) ...p]);

  test('pure black on transparent is dark (TV8)', () {
    expect(
        isDarkLogo(join([fill(0, 0, 0, 255, 300), fill(0, 0, 0, 0, 700)])),
        isTrue);
  });

  test('near-black navy is dark', () {
    expect(isDarkLogo(fill(0x0A, 0x1E, 0x3C, 255, 500)), isTrue);
  });

  test('white and saturated colours are not', () {
    expect(isDarkLogo(fill(255, 255, 255, 255, 500)), isFalse);
    expect(isDarkLogo(fill(255, 0, 0, 255, 500)), isFalse, reason: 'red');
    expect(isDarkLogo(fill(0, 0, 255, 255, 500)), isFalse, reason: 'blue');
  });

  test('a black badge with enough white lettering is left alone', () {
    // 80% black, 20% white: readable already.
    expect(
        isDarkLogo(
            join([fill(0, 0, 0, 255, 800), fill(255, 255, 255, 255, 200)])),
        isFalse);
  });

  test('only opaque pixels count', () {
    // Light pixels that are almost fully transparent do not make it visible.
    expect(
        isDarkLogo(
            join([fill(0, 0, 0, 255, 300), fill(255, 255, 255, 40, 700)])),
        isTrue);
  });

  test('fully transparent or empty is not dark', () {
    expect(isDarkLogo(fill(0, 0, 0, 0, 100)), isFalse);
    expect(isDarkLogo(Uint8List(0)), isFalse);
  });

  test('large images are sampled, not skipped', () {
    // 200k pixels: well past the ~4096-sample budget.
    expect(isDarkLogo(fill(0, 0, 0, 255, 200000)), isTrue);
  });
}
