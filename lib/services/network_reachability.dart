import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

/// Whether the host of [url] can be resolved right now: a cheap "is there a
/// network" probe for the moment sound mode would otherwise give up.
///
/// What a `true` really proves: the system resolver answered. That is weaker
/// than "the stream is reachable" in three ways, all of which fall on the safe
/// side (the caller gives up as it always did, it never waits forever):
///
/// * the OS caches successful lookups for the record's TTL, so a network that
///   dropped a minute ago can still "resolve";
/// * a captive portal or a hijacking resolver answers every name;
/// * it says nothing about the stream itself, only that DNS works.
///
/// `false` is the strong answer: the lookup failed or timed out, so the
/// device has no usable network (or no DNS), and retrying the stream cannot
/// work yet.
///
/// Returns `true` ("can't tell, behave as before") on the web, for a URL with
/// no host, for an IP-literal host (there is nothing to resolve, so the answer
/// would not depend on the network), and for any error that is not a lookup
/// failure.
Future<bool> hostResolves(
  String url, {
  Duration timeout = const Duration(seconds: 3),
  Future<List<InternetAddress>> Function(String host)? lookup,
}) async {
  if (kIsWeb) return true;
  final host = Uri.tryParse(url)?.host ?? '';
  if (host.isEmpty || InternetAddress.tryParse(host) != null) return true;
  try {
    final addresses = await (lookup ?? InternetAddress.lookup)(host)
        .timeout(timeout);
    return addresses.isNotEmpty;
  } on SocketException {
    return false;
  } on TimeoutException {
    return false;
  } catch (_) {
    return true;
  }
}
