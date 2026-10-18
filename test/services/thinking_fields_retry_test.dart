import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lm_mini/models/app_settings.dart';
import 'package:lm_mini/models/chat_message.dart';
import 'package:lm_mini/services/lm_studio_service.dart';
import 'package:lm_mini_premium/lm_mini_premium.dart';

/// An OpenAI-compatible server that rejects llama.cpp's thinking fields the
/// way Groq does, then streams normally once they're gone.
void main() {
  late HttpServer server;
  final bodies = <Map<String, dynamic>>[];

  setUp(() async {
    bodies.clear();
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((req) async {
      final body = jsonDecode(await utf8.decodeStream(req)) as Map<String, dynamic>;
      bodies.add(body);
      final res = req.response;
      if (body.containsKey('chat_template_kwargs')) {
        res.statusCode = 400;
        res.headers.contentType = ContentType.json;
        res.write(jsonEncode({
          'error': {
            'message': "property 'chat_template_kwargs' is unsupported",
            'type': 'invalid_request_error',
          }
        }));
        await res.close();
        return;
      }
      res.headers.contentType = ContentType('text', 'event-stream');
      res.write('data: ${jsonEncode({'choices': [{'delta': {'content': 'Hello from Groq'}}]})}\n\n');
      res.write('data: [DONE]\n\n');
      await res.close();
    });
  });

  tearDown(() => server.close(force: true));

  test('a rejected chat_template_kwargs is retried once without it', () async {
    final events = await LMStudioService()
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
          settings: AppSettings(
            selectedModel: 'qwen/qwen3-32b',
            reasoning: 'on',
          ),
          cloudProviderType: CloudApiType.openaiCompatible,
        )
        .toList();
    expect(bodies.length, 2);
    expect(bodies.first.containsKey('chat_template_kwargs'), isTrue);
    expect(bodies.last.containsKey('chat_template_kwargs'), isFalse);
    expect(events.any((e) => e.containsKey('error')), isFalse,
        reason: '$events');
    expect(jsonEncode(events), contains('Hello from Groq'));
  });
}
