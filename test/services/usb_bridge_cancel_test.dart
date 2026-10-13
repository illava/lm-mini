import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lm_mini/services/usb_bridge_service.dart';

/// Phone side of USB mode: the chat talks HTTP to 127.0.0.1:2347 and the
/// bridge forwards frames to the Mac on the control socket. A fake Mac here
/// streams tokens until told to cancel.
void main() {
  final bridge = UsbBridgeService.instance;
  late Socket mac;
  final fromPhone = <Map<String, dynamic>>[];
  final streaming = <String, Timer>{};

  setUpAll(() async {
    await bridge.start();
    mac = await Socket.connect(kUsbBridgeHost, kUsbBridgeControlPort);
    var buf = '';
    mac.cast<List<int>>().transform(utf8.decoder).listen((text) {
      buf += text;
      while (buf.contains('\n')) {
        final i = buf.indexOf('\n');
        final line = buf.substring(0, i);
        buf = buf.substring(i + 1);
        if (line.isEmpty) continue;
        final msg = jsonDecode(line) as Map<String, dynamic>;
        fromPhone.add(msg);
        final id = msg['id']?.toString();
        if (msg['type'] == 'request') {
          void send(Map<String, dynamic> f) => mac.write('${jsonEncode(f)}\n');
          send({'type': 'response-start', 'id': id, 'status': 200, 'headers': {}});
          var n = 0;
          streaming[id!] = Timer.periodic(const Duration(milliseconds: 40), (t) {
            if (++n > 40) {
              t.cancel();
              send({'type': 'response-end', 'id': id});
              return;
            }
            send({'type': 'response-chunk', 'id': id, 'data': 'tok$n '});
          });
        } else if (msg['type'] == 'cancel') {
          streaming.remove(id)?.cancel();
        }
      }
    });
    // Wait until the bridge registered the peer.
    for (var i = 0; i < 50 && !bridge.isPeerConnected; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    expect(bridge.isPeerConnected, isTrue);
  });

  tearDownAll(() async {
    for (final t in streaming.values) {
      t.cancel();
    }
    mac.destroy();
    await bridge.stop();
  });

  Future<HttpClientResponse> open(HttpClient c, String path) async {
    final req = await c.getUrl(Uri.parse('${UsbBridgeService.baseUrl}$path'));
    return req.close();
  }

  test('Stop sends cancel to the Mac for a streaming chat request', () async {
    fromPhone.clear();
    final client = HttpClient();
    final res = await open(client, '/v1/chat/completions');
    final got = Completer<void>();
    var chunks = 0;
    final sub = res.listen((_) {
      if (++chunks == 2 && !got.isCompleted) got.complete();
    });
    await got.future;

    bridge.cancelGenerations();
    await Future<void>.delayed(const Duration(milliseconds: 200));

    final request = fromPhone.firstWhere((m) => m['type'] == 'request');
    final cancels = fromPhone.where((m) => m['type'] == 'cancel').toList();
    expect(cancels, hasLength(1));
    expect(cancels.single['id'], request['id']);
    await sub.cancel();
    client.close(force: true);
  });

  test('Stop leaves non-generation requests (model list) alone', () async {
    fromPhone.clear();
    final client = HttpClient();
    final res = await open(client, '/v1/models');
    final body = StringBuffer();
    final done = res.transform(utf8.decoder).forEach(body.write);
    await Future<void>.delayed(const Duration(milliseconds: 100));
    bridge.cancelGenerations();
    await done.timeout(const Duration(seconds: 5));
    expect(fromPhone.where((m) => m['type'] == 'cancel'), isEmpty);
    expect(body.toString(), contains('tok40'));
    client.close();
  });

  test('a finished request never sends a cancel', () async {
    fromPhone.clear();
    final client = HttpClient();
    final res = await open(client, '/v1/chat/completions');
    await res.drain<void>();
    bridge.cancelGenerations();
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(fromPhone.where((m) => m['type'] == 'cancel'), isEmpty);
    client.close();
  });

  test('tokens reach the chat as they stream, not all at the end', () async {
    final client = HttpClient();
    final sw = Stopwatch()..start();
    final res = await open(client, '/v1/chat/completions');
    final arrivals = <int>[];
    await for (final _ in res) {
      arrivals.add(sw.elapsedMilliseconds);
    }
    // 40 chunks, 40 ms apart: buffered output delivered them all at ~1.6 s.
    expect(arrivals.length, greaterThan(10));
    expect(arrivals.first, lessThan(arrivals.last - 1000));
    client.close();
  });
}
