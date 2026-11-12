import 'dart:async';
import 'dart:io';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tvninja/services/audio_recovery.dart';
import 'package:tvninja/services/network_reachability.dart';
import 'package:tvninja/services/video/reconnect_controller.dart';

Duration _s(int seconds) => Duration(seconds: seconds);

/// An [AudioRecovery] whose reconnect attempts fail at once (mpv's "Failed to
/// open"), whose reachability lookup is a switch, and that records what it did.
class _Rig {
  _Rig(this.async, {this.withLookup = true}) {
    final clock = async.getClock(DateTime(2026, 11, 12, 12));
    recovery = AudioRecovery(
      reopen: _reopen,
      onGiveUp: () => giveUps.add(async.elapsed),
      canRecover: () => canRecover,
      onRecovered: () => recoveries.add(async.elapsed),
      isReachable: withLookup ? _lookup : null,
      onOffline: () => offlineStarts.add(async.elapsed),
      onNetworkBack: () => networkBacks.add(async.elapsed),
      now: clock.now,
    );
    // Audio that is flowing keeps its position moving (mpv reports it many
    // times a second); without it the stall detector would, rightly, fire.
    Timer.periodic(const Duration(seconds: 1), (_) {
      if (flowing) recovery.positionChanged(Duration(seconds: ++_position));
    });
  }

  final FakeAsync async;
  final bool withLookup;
  late final AudioRecovery recovery;

  /// What the lookup answers; ignored while [lookupGate] is set.
  bool online = false;

  /// When set, the lookup waits for it instead of answering at once.
  Completer<bool>? lookupGate;

  /// Throws from the lookup when set.
  bool lookupThrows = false;

  /// Reconnect attempts fail at once while true; when false the attempt
  /// "works": audio starts flowing.
  bool failAttempts = true;

  bool canRecover = true;

  /// Audio is coming out: the position moves every second.
  bool flowing = false;
  final reopens = <Duration>[];
  final lookups = <Duration>[];
  final giveUps = <Duration>[];
  final recoveries = <Duration>[];
  final offlineStarts = <Duration>[];
  final networkBacks = <Duration>[];
  int _position = 0;

  Future<void> _reopen() async {
    reopens.add(async.elapsed);
    if (failAttempts) {
      recovery.attemptFailed();
    } else {
      startFlowing();
    }
  }

  void startFlowing() {
    flowing = true;
    recovery.playingChanged(true);
    recovery.bufferingChanged(false);
    recovery.positionChanged(Duration(seconds: ++_position));
  }

  Future<bool> _lookup() {
    lookups.add(async.elapsed);
    if (lookupThrows) return Future.error(StateError('resolver exploded'));
    final gate = lookupGate;
    if (gate != null) return gate.future;
    return Future.value(online);
  }

  void elapse(int seconds) => async.elapse(Duration(seconds: seconds));

  /// The five failing attempts: the budget is spent at 60 s.
  void drop() {
    recovery.schedule();
    elapse(60);
  }
}

void main() {
  group('offlineAction (the pure decision)', () {
    test('reachable when the budget runs out: the stream is the problem', () {
      expect(
        offlineAction(reachable: true, waiting: false, waited: Duration.zero),
        OfflineAction.giveUp,
      );
    });

    test('unreachable when the budget runs out: wait', () {
      expect(
        offlineAction(reachable: false, waiting: false, waited: Duration.zero),
        OfflineAction.wait,
      );
    });

    test('reachable during the wait: the network is back, retry', () {
      expect(
        offlineAction(reachable: true, waiting: true, waited: _s(300)),
        OfflineAction.retry,
      );
    });

    test('network back is honoured even past the bound', () {
      expect(
        offlineAction(
          reachable: true,
          waiting: true,
          waited: const Duration(hours: 2),
        ),
        OfflineAction.retry,
      );
    });

    test('still unreachable: wait until the bound, then give up', () {
      expect(
        offlineAction(reachable: false, waiting: true, waited: _s(1799)),
        OfflineAction.wait,
      );
      expect(
        offlineAction(reachable: false, waiting: true, waited: _s(1800)),
        OfflineAction.giveUp,
      );
      expect(
        offlineAction(
          reachable: false,
          waiting: false,
          waited: const Duration(minutes: 31),
        ),
        OfflineAction.giveUp,
      );
    });

    test('the bound is a parameter', () {
      expect(
        offlineAction(
          reachable: false,
          waiting: true,
          waited: _s(10),
          budget: _s(10),
        ),
        OfflineAction.giveUp,
      );
    });
  });

  group('offline wait in AudioRecovery', () {
    test('without a lookup, the budget ends in the usual give-up', () {
      fakeAsync((async) {
        final r = _Rig(async, withLookup: false);
        r.drop();
        expect(r.giveUps, [_s(60)]);
        expect(r.recovery.isRecovering, isFalse);
      });
    });

    test('network reachable when the budget runs out: gives up as before', () {
      fakeAsync((async) {
        final r = _Rig(async)..online = true;
        r.drop();
        expect(r.lookups, [_s(60)]);
        expect(r.giveUps, [_s(60)]);
        expect(r.offlineStarts, isEmpty);
        expect(r.recovery.isRecovering, isFalse);
      });
    });

    test('offline: no give-up, keeps recovering, polls every 30 s', () {
      fakeAsync((async) {
        final r = _Rig(async);
        r.drop();
        expect(r.giveUps, isEmpty);
        expect(r.recovery.isRecovering, isTrue);
        expect(r.recovery.isWaitingForNetwork, isTrue);
        expect(r.offlineStarts, [_s(60)]);
        r.elapse(120);
        expect(r.lookups, [_s(60), _s(90), _s(120), _s(150), _s(180)]);
        expect(r.giveUps, isEmpty);
        // Waiting means no reconnect attempts, not a tight loop of them.
        expect(r.reopens.length, 5);
      });
    });

    test('network back: reconnects at once, with a full budget, and recovers',
        () {
      fakeAsync((async) {
        final r = _Rig(async);
        r.drop();
        r.elapse(100); // t = 160, still offline
        r.online = true;
        r.failAttempts = false;
        r.elapse(30); // the poll at 180 finds the network
        expect(r.networkBacks, [_s(180)]);
        // Not 2 s after the poll: at the poll.
        expect(r.reopens.last, _s(180));
        expect(r.recoveries, [_s(180)]);
        expect(r.giveUps, isEmpty);
        expect(r.recovery.isRecovering, isFalse);
        expect(r.recovery.isWaitingForNetwork, isFalse);
        // Quiet afterwards: no stray poll, no stray attempt.
        final reopens = r.reopens.length;
        final lookups = r.lookups.length;
        r.elapse(300);
        expect(r.reopens.length, reopens);
        expect(r.lookups.length, lookups);
      });
    });

    test('a retry that fails with the network up gets five attempts, then '
        'the usual give-up', () {
      fakeAsync((async) {
        final r = _Rig(async);
        r.drop();
        r.online = true; // back, but the stream keeps failing
        r.elapse(30); // poll at 90 -> retry now
        r.elapse(300);
        // 5 initial + 5 after the network came back.
        expect(r.reopens.length, 10);
        expect(r.reopens[5], _s(90));
        // The sixth..tenth attempts: now, +4, +8, +16, +30 (the controller's
        // schedule after a first attempt that was counted as attempt 1).
        expect(r.giveUps.length, 1);
        expect(r.giveUps.single, greaterThan(_s(90)));
        expect(r.giveUps.single, lessThan(_s(200)));
        expect(r.recovery.isRecovering, isFalse);
      });
    });

    test('bounded: never reachable ends in the usual give-up after 30 min', () {
      fakeAsync((async) {
        final r = _Rig(async);
        r.drop();
        r.elapse(1799 - 60 + 60); // up to 1799 s after the first check
        expect(r.giveUps, isEmpty);
        r.elapse(120);
        // First check at 60 s, bound 1800 s later.
        expect(r.giveUps, [_s(60 + 1800)]);
        expect(r.recovery.isRecovering, isFalse);
        expect(r.recovery.isWaitingForNetwork, isFalse);
        // And it stays given up: no more polls.
        final lookups = r.lookups.length;
        r.elapse(600);
        expect(r.lookups.length, lookups);
      });
    });

    test('the bound is not restarted by a network that flaps', () {
      fakeAsync((async) {
        final r = _Rig(async);
        r.drop(); // first offline check at 60 s
        r.online = true;
        r.elapse(30); // 90: retry now, fails again
        r.online = false; // down again before the retry chain ends
        r.elapse(3000);
        expect(r.giveUps.length, 1);
        // A fresh 30 min from the second offline moment would be >= 1990 s.
        expect(r.giveUps.single, lessThan(_s(60 + 1800 + 31)));
        expect(r.giveUps.single, greaterThanOrEqualTo(_s(60 + 1800)));
      });
    });

    test('a stop (reset) during the wait cancels it', () {
      fakeAsync((async) {
        final r = _Rig(async);
        r.drop();
        r.elapse(40);
        r.recovery.reset();
        final lookups = r.lookups.length;
        final reopens = r.reopens.length;
        r.online = true;
        r.elapse(3600);
        expect(r.lookups.length, lookups);
        expect(r.reopens.length, reopens);
        expect(r.giveUps, isEmpty);
        expect(r.networkBacks, isEmpty);
        expect(r.recovery.isWaitingForNetwork, isFalse);
        expect(r.recovery.isRecovering, isFalse);
      });
    });

    test('a lookup still in flight when the session is reset does nothing',
        () {
      fakeAsync((async) {
        final r = _Rig(async)..lookupGate = Completer<bool>();
        r.drop(); // the first lookup is now waiting on the gate
        expect(r.lookups, [_s(60)]);
        r.recovery.reset(); // a stop, or a new play
        r.lookupGate!.complete(false);
        r.elapse(3600);
        expect(r.giveUps, isEmpty);
        expect(r.offlineStarts, isEmpty);
        expect(r.recovery.isWaitingForNetwork, isFalse);
        expect(r.lookups.length, 1);
      });
    });

    test('a new drop after a reset starts clean and may wait again', () {
      fakeAsync((async) {
        final r = _Rig(async);
        r.drop();
        r.recovery.reset();
        r.drop();
        expect(r.recovery.isWaitingForNetwork, isTrue);
        expect(r.offlineStarts.length, 2);
        expect(r.giveUps, isEmpty);
      });
    });

    test('audio flowing again on its own ends the wait', () {
      fakeAsync((async) {
        final r = _Rig(async);
        r.drop();
        r.elapse(45);
        r.startFlowing();
        expect(r.recoveries.length, 1);
        expect(r.recovery.isWaitingForNetwork, isFalse);
        expect(r.recovery.isRecovering, isFalse);
        final lookups = r.lookups.length;
        r.elapse(600);
        expect(r.lookups.length, lookups);
        expect(r.giveUps, isEmpty);
      });
    });

    test('no session wanted any more: the wait stops quietly', () {
      fakeAsync((async) {
        final r = _Rig(async);
        r.drop();
        r.canRecover = false;
        r.elapse(60);
        expect(r.giveUps, isEmpty);
        expect(r.recovery.isRecovering, isFalse);
        expect(r.recovery.isWaitingForNetwork, isFalse);
        final lookups = r.lookups.length;
        r.elapse(600);
        expect(r.lookups.length, lookups);
      });
    });

    test('schedule() during the wait is a no-op', () {
      fakeAsync((async) {
        final r = _Rig(async);
        r.drop();
        final reopens = r.reopens.length;
        final offlineStarts = r.offlineStarts.length;
        r.recovery.schedule();
        r.recovery.schedule();
        r.elapse(25);
        expect(r.reopens.length, reopens);
        expect(r.offlineStarts.length, offlineStarts);
        expect(r.recovery.isWaitingForNetwork, isTrue);
      });
    });

    test('a lookup that never answers counts as offline after its timeout',
        () {
      fakeAsync((async) {
        final r = _Rig(async)..lookupGate = Completer<bool>();
        r.drop();
        expect(r.offlineStarts, isEmpty);
        r.elapse(4); // reachabilityTimeout
        expect(r.offlineStarts, [_s(64)]);
        expect(r.giveUps, isEmpty);
        expect(r.recovery.isWaitingForNetwork, isTrue);
      });
    });

    test('a lookup that throws is "can\'t tell": gives up as before', () {
      fakeAsync((async) {
        final r = _Rig(async)..lookupThrows = true;
        r.drop();
        expect(r.giveUps, [_s(60)]);
        expect(r.offlineStarts, isEmpty);
      });
    });
  });

  group('ReconnectController.retryNow', () {
    test('fires at once, counts as an attempt, and the chain carries on', () {
      fakeAsync((async) {
        final fired = <Duration>[];
        final gaveUp = <Duration>[];
        late final ReconnectController c;
        c = ReconnectController(
          onRetry: () async => fired.add(async.elapsed),
          onGiveUp: () => gaveUp.add(async.elapsed),
        );
        c.retryNow();
        async.flushMicrotasks();
        expect(fired, [Duration.zero]);
        expect(c.attempt, 1);
        // The next one follows the normal backoff for attempt 1 (4 s).
        async.elapse(_s(4));
        expect(fired, [Duration.zero, _s(4)]);
      });
    });

    test('a reset right after cancels the trailing reschedule', () {
      fakeAsync((async) {
        final fired = <Duration>[];
        final c = ReconnectController(
          onRetry: () async => fired.add(async.elapsed),
          onGiveUp: () {},
        );
        c.retryNow();
        c.reset();
        async.elapse(_s(120));
        expect(fired, [Duration.zero]);
      });
    });
  });

  group('hostResolves', () {
    Future<List<InternetAddress>> ok(String host) async =>
        [InternetAddress('93.184.216.34')];

    test('a name that resolves is reachable', () async {
      expect(await hostResolves('http://radio.example/stream', lookup: ok),
          isTrue);
    });

    test('an empty answer is not reachable', () async {
      expect(
        await hostResolves(
          'http://radio.example/stream',
          lookup: (_) async => <InternetAddress>[],
        ),
        isFalse,
      );
    });

    test('a failed lookup is not reachable', () async {
      expect(
        await hostResolves(
          'https://radio.example/live.m3u8',
          lookup: (_) async =>
              throw const SocketException('Failed host lookup'),
        ),
        isFalse,
      );
    });

    test('a lookup that does not answer in time is not reachable', () async {
      expect(
        await hostResolves(
          'https://radio.example/live.m3u8',
          timeout: const Duration(milliseconds: 20),
          lookup: (_) => Completer<List<InternetAddress>>().future,
        ),
        isFalse,
      );
    });

    test('the host is what is looked up', () async {
      String? asked;
      await hostResolves(
        'https://user@radio.example:8443/path?x=1',
        lookup: (host) async {
          asked = host;
          return [InternetAddress('93.184.216.34')];
        },
      );
      expect(asked, 'radio.example');
    });

    test('an IP-literal host cannot tell, so it is "reachable" untouched',
        () async {
      var called = false;
      final result = await hostResolves(
        'http://10.0.2.2:8765/live.m3u8',
        lookup: (_) async {
          called = true;
          return <InternetAddress>[];
        },
      );
      expect(result, isTrue);
      expect(called, isFalse);
    });

    test('no host, or an unparsable URL, cannot tell', () async {
      expect(await hostResolves('', lookup: ok), isTrue);
      expect(await hostResolves('not a url', lookup: ok), isTrue);
    });

    test('an unexpected error cannot tell', () async {
      expect(
        await hostResolves(
          'http://radio.example/stream',
          lookup: (_) async => throw StateError('boom'),
        ),
        isTrue,
      );
    });
  });
}
