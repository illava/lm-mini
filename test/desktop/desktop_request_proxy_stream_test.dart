import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lm_mini/desktop/host/desktop_relay_client.dart';
import 'package:lm_mini/desktop/host/desktop_request_proxy.dart';

/// Streams through [DesktopRequestProxy] against a real local HTTP server
/// standing in for LM Studio.
void main() {
  late HttpServer backend;
  var backendFinished = false;
  const text = 'Hi 😀 你好 Привет ✅ end';

  setUp(() async {
    backendFinished = false;
    backend = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    backend.listen((req) async {
      final res = req.response;
      res.headers.contentType = ContentType('text', 'event-stream');
      res.bufferOutput = false;
      if (req.uri.path == '/emoji') {
        // One byte per write: every multi-byte character is split.
        for (final b in utf8.encode(text)) {
          res.add([b]);
          await res.flush();
          await Future<void>.delayed(const Duration(milliseconds: 2));
        }
        await res.close();
        return;
      }
      // Slow "generation": 50 tokens, 50 ms apart.
      var gone = false;
      unawaited(res.done.then((_) {}, onError: (_) => gone = true));
      try {
        for (var i = 1; i <= 50; i++) {
          if (gone) return;
          res.write('data: token$i\n\n');
          await res.flush();
          await Future<void>.delayed(const Duration(milliseconds: 50));
        }
        backendFinished = true;
        await res.close();
      } catch (_) {
        // Proxy hung up.
      }
    });
  });

  tearDown(() => backend.close(force: true));

  DesktopRelayBackends backends() => DesktopRelayBackends(
        lmStudioPort: backend.port,
        advertiseBuiltin: false,
        advertiseLmStudio: true,
      );

  Map<String, dynamic> request(String id, String path) => {
        'id': id,
        'method': 'GET',
        'path': path,
        'headers': {'X-LM-Mini-Backend': 'lmstudio'},
      };

  test('emoji and non-Latin text survive chunks split mid-character', () async {
    final frames = <Map<String, dynamic>>[];
    await DesktopRequestProxy.instance.handleRelayStyleRequest(
      msg: request('e1', '/emoji'),
      backends: backends(),
      send: frames.add,
    );
    final body = frames
        .where((f) => f['type'] == 'response-chunk')
        .map((f) => f['data'] as String)
        .join();
    expect(body, text);
    expect(body.contains('�'), isFalse);
    expect(frames.last['type'], 'response-end');
  });

  test('cancel stops the upstream request and sends no error frame', () async {
    final frames = <Map<String, dynamic>>[];
    final firstChunks = Completer<void>();
    final done = DesktopRequestProxy.instance.handleRelayStyleRequest(
      msg: request('c1', '/v1/chat/completions'),
      backends: backends(),
      send: (f) {
        frames.add(f);
        if (frames.where((x) => x['type'] == 'response-chunk').length == 3 &&
            !firstChunks.isCompleted) {
          firstChunks.complete();
        }
      },
    );
    await firstChunks.future;
    expect(DesktopRequestProxy.instance.inflightCount(), 1);
    final sw = Stopwatch()..start();
    DesktopRequestProxy.instance.cancel('c1');
    await done.timeout(const Duration(seconds: 3));
    // The full stream takes 2.5 s; a cancelled one ends at once.
    expect(sw.elapsedMilliseconds, lessThan(500));
    final chunksAtCancel =
        frames.where((f) => f['type'] == 'response-chunk').length;
    await Future<void>.delayed(const Duration(milliseconds: 300));
    expect(frames.where((f) => f['type'] == 'response-chunk').length,
        chunksAtCancel);
    expect(frames.any((f) => f['type'] == 'response-end'), isFalse);
    expect(frames.any((f) => f['type'] == 'response-error'), isFalse);
    expect(DesktopRequestProxy.instance.inflightCount(), 0);
  });

  test('cancel on one channel leaves the same id on another channel alone',
      () async {
    final usbFrames = <Map<String, dynamic>>[];
    final started = Completer<void>();
    final done = DesktopRequestProxy.instance.handleRelayStyleRequest(
      msg: request('1', '/v1/chat/completions'),
      backends: backends(),
      channel: 'usb-7-1',
      send: (f) {
        usbFrames.add(f);
        if (f['type'] == 'response-chunk' && !started.isCompleted) {
          started.complete();
        }
      },
    );
    await started.future;
    DesktopRequestProxy.instance.cancel('1'); // relay channel: no-op
    DesktopRequestProxy.instance.cancelAll(channel: 'usb-other');
    expect(DesktopRequestProxy.instance.inflightCount(channel: 'usb-7-1'), 1);
    DesktopRequestProxy.instance.cancelAll(channel: 'usb-7-1');
    await done.timeout(const Duration(seconds: 3));
    expect(backendFinished, isFalse);
  });

  test('a request that is not cancelled streams to the end', () async {
    final frames = <Map<String, dynamic>>[];
    await DesktopRequestProxy.instance.handleRelayStyleRequest(
      msg: request('n1', '/v1/chat/completions'),
      backends: backends(),
      send: frames.add,
    );
    final body = frames
        .where((f) => f['type'] == 'response-chunk')
        .map((f) => f['data'])
        .join();
    expect(body, contains('token50'));
    expect(frames.last['type'], 'response-end');
    expect(backendFinished, isTrue);
  }, timeout: const Timeout(Duration(seconds: 10)));
}
