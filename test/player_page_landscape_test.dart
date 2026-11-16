import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
// The page reads its stats through `provider`, which the app uses but does not
// list as a direct dependency (pre-existing; see the same info on `lib`).
// ignore: depend_on_referenced_packages
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tvninja/config/config.dart';
import 'package:tvninja/l10n/app_localizations.dart';
import 'package:tvninja/pages/player_page.dart';
import 'package:tvninja/widgets/channel_logo.dart';

/// The sound screen (and the video loading placeholder, which is the same
/// layout) in a short window: the play/pause control and the buffering spinner
/// sit at the bottom of a column that used to be taller than a landscape phone
/// leaves for it, so a few pixels of it showed and the rest was clipped away.
///
/// The page is mounted on the test host with every platform channel it touches
/// answered by a stub. "Visible" below means inside the strip between the
/// AppBar and the channel bar, which is where the body is drawn and clipped.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // A landscape phone: the S24 Ultra's landscape window is about this shape.
  const landscape = Size(800, 360);
  const portrait = Size(360, 640);

  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    messenger.setMockMethodCallHandler(
        const MethodChannel('io.github.giuig.tvninja/pip'),
        (call) async => null);
    for (final events in ['pip_events', 'noisy_events', 'audio_events']) {
      messenger.setMockMethodCallHandler(
          MethodChannel('io.github.giuig.tvninja/$events'),
          (call) async => null);
    }
    for (final name in ['toggle', 'isEnabled']) {
      messenger.setMockMessageHandler(
          'dev.flutter.pigeon.wakelock_plus_platform_interface.WakelockPlusApi.$name',
          (message) async => const StandardMessageCodec()
              .encodeMessage(<Object?>[name == 'isEnabled' ? false : null]));
    }
  });

  final channels = [
    Channel(name: 'First', url: 'http://127.0.0.1:1/first.m3u8'),
    Channel(name: 'Second', url: 'http://127.0.0.1:1/second.m3u8'),
  ];

  Future<void> mount(WidgetTester tester, Size size,
      {required bool sound}) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(ChangeNotifierProvider(
      create: (_) => AppStatsNotifier(),
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: PlayerPage(
          channel: channels.first,
          channels: channels,
          initialIndex: 0,
          initialAudioOnly: sound,
        ),
      ),
    ));
  }

  /// Opens the sound screen. Starting in sound mode brings up the audio
  /// engine, which cannot be built on the test host (no libmpv), so that one
  /// failure is expected and swallowed; the screen itself is unaffected.
  Future<void> openSoundScreen(WidgetTester tester, Size size) async {
    final unexpected = <Object>[];
    await runZonedGuarded(() => mount(tester, size, sound: true), (e, _) {
      if (!e.toString().contains('MediaKit.ensureInitialized')) {
        unexpected.add(e);
      }
    });
    await tester.pump();
    expect(unexpected, isEmpty);
    expect(find.byIcon(Icons.play_circle_filled), findsOneWidget);
  }

  /// The strip the body is drawn in: below the AppBar, above the channel bar.
  Rect bodyArea(WidgetTester tester) {
    final top = tester.getRect(find.byType(AppBar)).bottom;
    final bar = find.ancestor(
        of: find.byIcon(Icons.skip_next), matching: find.byType(SafeArea));
    final bottom = tester.getRect(bar.first).top;
    return Rect.fromLTRB(0, top, tester.view.physicalSize.width, bottom);
  }

  /// True when a tap at the centre of [target] lands on [target] itself and
  /// not on whatever is painted over it or clipped away in front of it.
  bool tapReaches(WidgetTester tester, Finder target) {
    final center = tester.getCenter(target);
    final hit = tester.hitTestOnBinding(center);
    final root = tester.renderObject(target);
    return hit.path.any((entry) {
      final t = entry.target;
      return t is RenderObject && _isWithin(t, root);
    });
  }

  // The AppBar shows the channel name too; the placeholder's title is the one
  // set in 20 px type.
  Finder title() => find.byWidgetPredicate(
      (w) => w is Text && w.data == 'First' && w.style?.fontSize == 20);

  Finder controlButton() => find.ancestor(
      of: find.byIcon(Icons.play_circle_filled),
      matching: find.byType(IconButton));

  /// How far the placeholder's scroll view can scroll. Zero means nothing
  /// scrolls: either the layout fits or there is no scroll view at all.
  double scrollExtent(WidgetTester tester) {
    final scrollables =
        find.ancestor(of: controlButton(), matching: find.byType(Scrollable));
    if (scrollables.evaluate().isEmpty) return 0;
    return tester
        .state<ScrollableState>(scrollables.first)
        .position
        .maxScrollExtent;
  }

  /// Taps the control for real and returns what the page's play/pause handler
  /// did. On the test host the audio engine does not exist, so the handler
  /// (`resume`, as the screen starts stopped) fails on its uninitialised
  /// player: that failure is the proof that the tap reached the handler, and
  /// nothing else may fail.
  Future<List<Object>> tapControl(WidgetTester tester) async {
    final errors = <Object>[];
    await runZonedGuarded(() async {
      await tester.tap(controlButton());
      await tester.pump();
    }, (e, _) => errors.add(e));
    return errors;
  }

  void expectInside(WidgetTester tester, Finder what, Rect body, String name) {
    final rect = tester.getRect(what.first);
    expect(rect.top, greaterThanOrEqualTo(body.top - 0.01),
        reason: '$name starts above the body');
    expect(rect.bottom, lessThanOrEqualTo(body.bottom + 0.01),
        reason: '$name ends below the body (clipped by the channel bar)');
  }

  void expectRect(Rect actual, Rect expected, String name) {
    expect(actual.left, closeTo(expected.left, 0.1), reason: '$name left');
    expect(actual.top, closeTo(expected.top, 0.1), reason: '$name top');
    expect(actual.right, closeTo(expected.right, 0.1), reason: '$name right');
    expect(actual.bottom, closeTo(expected.bottom, 0.1),
        reason: '$name bottom');
  }

  group('sound screen', () {
    testWidgets('keeps its original layout in a tall (portrait) window',
        (tester) async {
      await openSoundScreen(tester, portrait);

      // Measured on the layout before it learned about short windows. A tall
      // window must keep exactly this geometry.
      expectRect(tester.getRect(find.byType(ChannelLogo)),
          const Rect.fromLTRB(120, 144.5, 240, 264.5), 'logo');
      expectRect(tester.getRect(title()),
          const Rect.fromLTRB(129.4, 288.5, 230.6, 317.5), 'title');
      expectRect(tester.getRect(find.text('Native Background Audio')),
          const Rect.fromLTRB(16.1, 325.5, 343.9, 345.5), 'subtitle');
      expectRect(
          tester.getRect(find.text('Use notification controls to play/pause')),
          const Rect.fromLTRB(0, 349.5, 360, 383.5),
          'hint');
      expectRect(tester.getRect(find.byIcon(Icons.play_circle_filled)),
          const Rect.fromLTRB(148, 415.5, 212, 479.5), 'play icon');
    });

    testWidgets('shows the play control, whole and tappable, in landscape',
        (tester) async {
      await openSoundScreen(tester, landscape);

      final body = bodyArea(tester);
      expect(body.height, lessThan(300),
          reason: 'this must be the short window the bug is about');
      expectInside(tester, controlButton(), body, 'play/pause button');
      expect(tapReaches(tester, controlButton()), isTrue,
          reason: 'a tap on the button must reach it');

      // Material's minimum touch target.
      final rect = tester.getRect(controlButton());
      expect(rect.width, greaterThanOrEqualTo(48));
      expect(rect.height, greaterThanOrEqualTo(48));
    });

    testWidgets('fits the logo and every line of text in landscape',
        (tester) async {
      await openSoundScreen(tester, landscape);

      final body = bodyArea(tester);
      expectInside(tester, find.byType(ChannelLogo), body, 'logo');
      expectInside(tester, title(), body, 'title');
      expectInside(
          tester, find.text('Native Background Audio'), body, 'subtitle');
      expectInside(tester, find.text('Use notification controls to play/pause'),
          body, 'hint');
      expectInside(tester, controlButton(), body, 'play/pause button');
    });

    testWidgets('scrolls to the control in a window too short for the layout',
        (tester) async {
      // Shorter than the compact layout needs: nothing may stay out of reach.
      await openSoundScreen(tester, const Size(800, 320));

      await tester.ensureVisible(controlButton());
      await tester.pump();

      final body = bodyArea(tester);
      expectInside(tester, controlButton(), body, 'play/pause button');
      expect(tapReaches(tester, controlButton()), isTrue);
    });
  });

  group('sound screen with a large system font', () {
    // Display zoom and the largest font setting scale the text; the logo and
    // the control slot do not shrink, so the column outgrows a landscape body.
    // The compact layout does not adapt to the scale; the scroll view is what
    // keeps the control reachable.
    void useTextScale(WidgetTester tester, double scale) {
      tester.platformDispatcher.textScaleFactorTestValue = scale;
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    }

    testWidgets('scrolls to the control in landscape, and a tap reaches it',
        (tester) async {
      useTextScale(tester, 2.0);
      await openSoundScreen(tester, landscape);

      expect(scrollExtent(tester), greaterThan(0),
          reason: 'the content is taller than the body, so it must scroll; '
              'otherwise the control is clipped and unreachable');

      await tester.ensureVisible(controlButton());
      await tester.pump();

      expectInside(
          tester, controlButton(), bodyArea(tester), 'play/pause button');
      expect(tapReaches(tester, controlButton()), isTrue);

      final errors = await tapControl(tester);
      expect(errors, hasLength(1),
          reason: 'the tap must reach the play/pause handler');
      expect(errors.single.toString(), contains('_audioPlayer'));
    });

    testWidgets('a normal window at the normal font does not scroll',
        (tester) async {
      await openSoundScreen(tester, portrait);
      expect(scrollExtent(tester), 0);

      // Nor does the compact landscape layout: the scroll view is only a
      // fallback, not part of the everyday layout.
      await tester.pumpWidget(const SizedBox());
      await openSoundScreen(tester, landscape);
      expect(scrollExtent(tester), 0);
    });
  });

  group('video loading placeholder', () {
    testWidgets('keeps its spinner inside the body in landscape',
        (tester) async {
      await mount(tester, landscape, sound: false);

      final spinner = find.byType(CircularProgressIndicator);
      expect(spinner, findsOneWidget,
          reason: 'the loading placeholder is up on the first frame');
      expectInside(tester, spinner, bodyArea(tester), 'spinner');
      final loadingSlot = tester.getRect(spinner);

      // Unmount before the stubbed engine fails and replaces the placeholder.
      await tester.pumpWidget(const SizedBox());

      // The spinner and the play button share one slot in every state, so
      // switching between them never moves anything.
      await openSoundScreen(tester, landscape);
      expectRect(tester.getRect(controlButton()).deflate(8), loadingSlot,
          'control slot');
    });
  });
}

bool _isWithin(RenderObject node, RenderObject ancestor) {
  for (RenderObject? n = node; n != null; n = n.parent) {
    if (identical(n, ancestor)) return true;
  }
  return false;
}
