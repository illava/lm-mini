// LM-MINI-PRO-STUB
import 'package:flutter/foundation.dart';

import '../../desktop/host/desktop_relay_backends.dart';

/// Direct Wi‑Fi share placeholder for the open-source build.
///
/// Phone pairing (and with it the direct Wi‑Fi path) is part of the official
/// app. USB sharing does not use this server and keeps working.
class DesktopLanServer extends ChangeNotifier {
  DesktopLanServer._();
  static final DesktopLanServer instance = DesktopLanServer._();

  static const channel = 'lan';

  bool get isRunning => false;
  int? get port => null;
  String? get fingerprint => null;
  List<String> get addresses => const [];
  String? get lastError => null;
  List<String> get lanUrls => const [];

  /// Null: the host screen shows no direct Wi‑Fi line.
  String? get statusLine => null;

  Future<void> start({
    required String Function() token,
    required DesktopRelayBackends Function() backends,
  }) async {}

  Future<void> stop() async {}

  Future<void> resetIdentity() async {}

  Future<void> refreshAddresses({bool notify = true}) async {}
}
