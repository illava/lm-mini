import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lm_mini/models/app_settings.dart';
import 'package:lm_mini/models/chat_message.dart';
import 'package:lm_mini/services/lm_studio_service.dart';

/// A Mac host whose model is still loading opens the stream with `: loading`
/// SSE comments, then either streams the reply or ends with an OpenAI-style
/// `data: {"error":…}` event. The phone must skip the comments and show the
/// error.
void main() {
  late HttpServer server;
  late List<String> script;

  setUp(() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((req) async {
      await req.drain<void>();
      final res = req.response;
      res.bufferOutput = false;
      res.headers.contentType = ContentType('text', 'event-stream');
      for (final part in script) {
        res.write(part);
        await res.flush();
        await Future<void>.delayed(const Duration(milliseconds: 30));
      }
      await res.close();
    });
  });

  tearDown(() => server.close(force: true));

  Future<List<Map<String, dynamic>>> run() => LMStudioService()
      .streamChatCompletion(
        baseUrl: 'http://127.0.0.1:${server.port}',
        messages: [
          ChatMessage(
            id: 'u',
            content: 'hi',
            role: 'user',
            timestamp: DateTime(2026),
          ),
        ],
        settings: AppSettings(selectedModel: 'm.gguf'),
      )
      .toList();

  String event(Object json) => 'data: ${jsonEncode(json)}\n\n';

  test('loading comments are skipped, then the reply streams', () async {
    script = [
      ': loading\n\n',
      ': loading\n\n',
      event({
        'choices': [
          {
            'delta': {'content': 'Hello'},
          },
        ],
      }),
      'data: [DONE]\n\n',
    ];
    final events = await run();
    expect(events.any((e) => e.containsKey('error')), isFalse,
        reason: '$events');
    expect(events.where((e) => e['content'] != null).map((e) => e['content']),
        ['Hello']);
  });

  test('an error event after the comments is surfaced', () async {
    script = [
      ': loading\n\n',
      event({
        'error': {
          'message': 'No downloaded GGUF model to share.',
          'type': 'runtime_error',
        },
      }),
      'data: [DONE]\n\n',
    ];
    final events = await run();
    expect(events, hasLength(1));
    expect(events.single['error'], 'No downloaded GGUF model to share.');
  });

  test('a context overflow inside the stream keeps its error type', () async {
    script = [
      ': loading\n\n',
      event({
        'error': {
          'code': 400,
          'message': 'the request exceeds the available context size',
          'type': 'exceed_context_size_error',
        },
      }),
      'data: [DONE]\n\n',
    ];
    final events = await run();
    expect(events.single['error_type'], LMStudioService.contextOverflowType);
  });
}
