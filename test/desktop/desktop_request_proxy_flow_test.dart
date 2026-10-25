import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lm_mini/desktop/desktop_platform.dart';
import 'package:lm_mini/desktop/host/desktop_relay_client.dart';
import 'package:lm_mini/desktop/host/desktop_request_proxy.dart';
import 'package:lm_mini/desktop/runtime/desktop_runtime_manager.dart';

/// Relay flow control (pause / resume), the upstream idle timeout and the
/// loading keep-alive, against a local HTTP server standing in for a backend.
void main() {
  late HttpServer backend;
  final proxy = DesktopRequestProxy.instance;

  setUp(() async {
    backend = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    backend.listen((req) async {
      final res = req.response;
      res.bufferOutput = false;
      final body = await utf8.decodeStream(req);
      final model = body.isEmpty
          ? ''
          : ((jsonDecode(body) as Map)['model'] as String? ?? '');
      try {
        if (req.uri.path == '/stall') {
          res.headers.contentType = ContentType('text', 'event-stream');
          res.write('data: first\n\n');
          await res.flush();
          await Future<void>.delayed(const Duration(seconds: 3));
          await res.close();
          return;
        }
        if (model.startsWith('slow')) {
          await Future<void>.delayed(const Duration(milliseconds: 350));
        }
        if (model.endsWith('fail')) {
          res.statusCode = 400;
          res.headers.contentType = ContentType.json;
          res.write(jsonEncode({
            'error': {
              'code': 400,
              'message': 'the request exceeds the available context size',
              'type': 'exceed_context_size_error',
            },
          }));
          await res.close();
          return;
        }
        res.headers.contentType = ContentType('text', 'event-stream');
        for (var i = 1; i <= 30; i++) {
          res.write('data: token$i\n\n');
          await res.flush();
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }
        res.write('data: [DONE]\n\n');
        await res.close();
      } catch (_) {
        // Proxy hung up.
      }
    });
  });

  tearDown(() async {
    DesktopRequestProxy.upstreamIdleTimeout = const Duration(minutes: 10);
    DesktopRequestProxy.keepAliveEvery = const Duration(seconds: 15);
    DesktopRequestProxy.keepAliveGrace = const Duration(seconds: 5);
    DesktopRequestProxy.keepAliveTargetKinds = {'lmMiniDesktop'};
    await backend.close(force: true);
  });

  DesktopRelayBackends backends() => DesktopRelayBackends(
        lmStudioPort: backend.port,
        advertiseBuiltin: false,
        advertiseLmStudio: true,
      );

  Map<String, dynamic> chat(String id, String model, {bool stream = true}) => {
        'id': id,
        'method': 'POST',
        'path': '/v1/chat/completions',
        'headers': {
          'X-LM-Mini-Backend': 'lmstudio',
          'content-type': 'application/json',
        },
        'body': jsonEncode({'model': model, 'stream': stream}),
      };

  String bodyOf(List<Map<String, dynamic>> frames) => frames
      .where((f) => f['type'] == 'response-chunk')
      .map((f) => f['data'] as String)
      .join();

  group('flow control', () {
    test('pause stops forwarding, resume finishes the stream', () async {
      // Paused time must not count as upstream silence.
      DesktopRequestProxy.upstreamIdleTimeout =
          const Duration(milliseconds: 150);
      final frames = <Map<String, dynamic>>[];
      final threeChunks = Completer<void>();
      final done = proxy.handleRelayStyleRequest(
        msg: chat('p1', 'fast'),
        backends: backends(),
        send: (f) {
          frames.add(f);
          if (frames.where((x) => x['type'] == 'response-chunk').length == 3 &&
              !threeChunks.isCompleted) {
            proxy.pause('p1');
            threeChunks.complete();
          }
        },
      );
      await threeChunks.future;
      final atPause = frames.length;
      await Future<void>.delayed(const Duration(milliseconds: 500));
      expect(frames.length, lessThanOrEqualTo(atPause + 1));
      proxy.resume('p1');
      await done.timeout(const Duration(seconds: 5));
      expect(bodyOf(frames), contains('token30'));
      expect(frames.last['type'], 'response-end');
      expect(frames.any((f) => f['type'] == 'response-error'), isFalse);
    });

    test('cancel while paused ends the request', () async {
      final frames = <Map<String, dynamic>>[];
      final started = Completer<void>();
      final done = proxy.handleRelayStyleRequest(
        msg: chat('p2', 'fast'),
        backends: backends(),
        send: (f) {
          frames.add(f);
          if (f['type'] == 'response-chunk' && !started.isCompleted) {
            proxy.pause('p2');
            started.complete();
          }
        },
      );
      await started.future;
      proxy.cancel('p2');
      await done.timeout(const Duration(seconds: 2));
      expect(frames.any((f) => f['type'] == 'response-error'), isFalse);
      expect(proxy.inflightCount(), 0);
    });

    test('pause / resume for unknown ids are ignored', () {
      proxy.pause('nope');
      proxy.resume('nope');
      expect(proxy.inflightCount(), 0);
    });
  });

  test('a backend that stops sending is cut by the idle timeout', () async {
    DesktopRequestProxy.upstreamIdleTimeout =
        const Duration(milliseconds: 200);
    final frames = <Map<String, dynamic>>[];
    final sw = Stopwatch()..start();
    await proxy.handleRelayStyleRequest(
      msg: {
        'id': 'i1',
        'method': 'GET',
        'path': '/stall',
        'headers': {'X-LM-Mini-Backend': 'lmstudio'},
      },
      backends: backends(),
      send: frames.add,
    );
    expect(sw.elapsedMilliseconds, lessThan(2000));
    expect(bodyOf(frames), contains('first'));
    expect(frames.last['type'], 'response-error');
  });

  group('loading keep-alive', () {
    setUp(() {
      DesktopRequestProxy.keepAliveTargetKinds = {'lmStudio'};
      DesktopRequestProxy.keepAliveGrace = const Duration(milliseconds: 50);
      DesktopRequestProxy.keepAliveEvery = const Duration(milliseconds: 100);
    });

    test('slow start: 200 event-stream, comments, then the real stream',
        () async {
      final frames = <Map<String, dynamic>>[];
      await proxy.handleRelayStyleRequest(
        msg: chat('k1', 'slow-ok'),
        backends: backends(),
        send: frames.add,
      );
      final starts = frames.where((f) => f['type'] == 'response-start');
      expect(starts, hasLength(1));
      expect(starts.single['status'], 200);
      expect((starts.single['headers'] as Map)['content-type'],
          'text/event-stream');
      final body = bodyOf(frames);
      expect(body, startsWith(LoadingKeepAlive.comment));
      expect(
          LoadingKeepAlive.comment.allMatches(body).length, greaterThan(1));
      expect(body, contains('token30'));
      expect(body.lastIndexOf(': loading'), lessThan(body.indexOf('token1')));
      expect(frames.last['type'], 'response-end');
    });

    test('slow failure becomes an SSE error event keeping its type',
        () async {
      final frames = <Map<String, dynamic>>[];
      await proxy.handleRelayStyleRequest(
        msg: chat('k2', 'slow-fail'),
        backends: backends(),
        send: frames.add,
      );
      final body = bodyOf(frames);
      final events = body
          .split('\n\n')
          .where((e) => e.startsWith('data: '))
          .map((e) => e.substring(6))
          .toList();
      expect(events.last, '[DONE]');
      final err = (jsonDecode(events.first) as Map)['error'] as Map;
      expect(err['message'], contains('exceeds the available context'));
      expect(err['type'], 'exceed_context_size_error');
      expect(frames.last['type'], 'response-end');
      expect(frames.any((f) => f['type'] == 'response-error'), isFalse);
    });

    test('a quick reply keeps the backend status and headers', () async {
      final frames = <Map<String, dynamic>>[];
      await proxy.handleRelayStyleRequest(
        msg: chat('k3', 'fail'),
        backends: backends(),
        send: frames.add,
      );
      expect(frames.first['type'], 'response-start');
      expect(frames.first['status'], 400);
      expect(bodyOf(frames), isNot(contains(': loading')));
    });

    test('non-streaming requests never get the keep-alive', () async {
      final frames = <Map<String, dynamic>>[];
      await proxy.handleRelayStyleRequest(
        msg: chat('k4', 'slow-fail', stream: false),
        backends: backends(),
        send: frames.add,
      );
      expect(frames.first['status'], 400);
      expect(bodyOf(frames), isNot(contains(': loading')));
    });
  });

  test('built-in runtime that fails to start ends the stream with an error',
      () async {
    if (!DesktopPlatform.supportsSidecarRuntime) return;
    DesktopRequestProxy.keepAliveEvery = const Duration(milliseconds: 100);
    final runtime = DesktopRuntimeManager.instance;
    final oldResolver = runtime.builtinModelResolver;
    runtime.builtinModelResolver = () async {
      await Future<void>.delayed(const Duration(milliseconds: 350));
      return null;
    };
    addTearDown(() => runtime.builtinModelResolver = oldResolver);
    final frames = <Map<String, dynamic>>[];
    await proxy.handleRelayStyleRequest(
      msg: {
        'id': 'b1',
        'method': 'POST',
        'path': '/v1/chat/completions',
        'headers': {'X-LM-Mini-Backend': 'lmMiniDesktop'},
        'body': jsonEncode({'model': 'x.gguf', 'stream': true}),
      },
      backends: const DesktopRelayBackends(advertiseBuiltin: true),
      send: frames.add,
    );
    expect(frames.first['type'], 'response-start');
    expect(frames.first['status'], 200);
    final body = bodyOf(frames);
    expect(LoadingKeepAlive.comment.allMatches(body).length,
        greaterThanOrEqualTo(2));
    expect(body, contains('"type":"runtime_error"'));
    expect(body, endsWith('data: [DONE]\n\n'));
    expect(frames.last['type'], 'response-end');
  });

  group('helpers', () {
    test('isStreamingChatRequest', () {
      bool f(String m, String p, Object? b) =>
          DesktopRequestProxy.isStreamingChatRequest(m, p, b, null);
      expect(f('POST', '/v1/chat/completions', '{"stream":true}'), isTrue);
      expect(f('POST', '/s/abc/v1/chat/completions', '{"stream":true}'),
          isTrue);
      expect(f('POST', '/v1/chat/completions', '{"stream":false}'), isFalse);
      expect(f('POST', '/v1/chat/completions', '{}'), isFalse);
      expect(f('POST', '/v1/chat/completions', 'not json'), isFalse);
      expect(f('GET', '/v1/chat/completions', '{"stream":true}'), isFalse);
      // Phone falls back from V1 to V0 on llama-server's 404: keep the status.
      expect(f('POST', '/api/v1/chat', '{"stream":true}'), isFalse);
      expect(f('POST', '/api/chat', '{"stream":true}'), isFalse);
      expect(
        DesktopRequestProxy.isStreamingChatRequest(
          'POST',
          '/v1/chat/completions',
          base64Encode(utf8.encode('{"stream":true}')),
          'base64',
        ),
        isTrue,
      );
    });

    test('sseErrorEvent is an OpenAI-style data line', () {
      final e = DesktopRequestProxy.sseErrorEvent('boom');
      expect(e, endsWith('\n\n'));
      expect(jsonDecode(e.substring(6)), {
        'error': {'message': 'boom', 'type': 'runtime_error'},
      });
    });

    test('sseErrorMessage reads the backend error', () {
      expect(
        DesktopRequestProxy.sseErrorMessage(
            500, '{"error":{"message":"oom"}}'),
        'oom',
      );
      expect(DesktopRequestProxy.sseErrorMessage(502, ''), contains('502'));
    });
  });
}
