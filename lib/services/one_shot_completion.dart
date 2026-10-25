import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:lm_mini_premium/lm_mini_premium.dart';

import '../models/app_settings.dart';
import 'apple_intelligence_endpoint.dart';
import 'siri_inference_snapshot.dart';

/// One prompt → one reply for features outside the chat (persona generator,
/// News widget) on providers that aren't LM Studio or on-device:
/// Ollama, cloud APIs, oMLX, Jan, Unsloth (OpenAI-compatible, with the same
/// URL, model, auth and relay headers Siri uses) and Apple Intelligence.
abstract final class OneShotCompletion {
  static Future<String> apple({
    required AppSettings settings,
    required String systemPrompt,
    required String userPrompt,
  }) async {
    final buffer = StringBuffer();
    await for (final delta in AppleIntelligenceEndpoint().streamCompletion(
      prompt: '$systemPrompt\n\n$userPrompt',
      maxTokens: settings.maxTokens,
      temperature: settings.temperature,
    )) {
      buffer.write(delta);
    }
    return buffer.toString();
  }

  static Future<String> cloud({
    required AppSettings settings,
    required CloudApiProvider cloud,
    required String systemPrompt,
    required String userPrompt,
    Duration timeout = const Duration(minutes: 5),
  }) async {
    final snap = SiriInferenceSnapshot.from(settings: settings, cloud: cloud);
    final url = snap.chatUrl;
    final model = snap.model;
    if (url == null || url.isEmpty) {
      throw StateError('No server is set up for this provider.');
    }
    if (model == null || model.isEmpty) {
      throw StateError('No model selected.');
    }
    final response = await http
        .post(
          Uri.parse(url),
          headers: snap.headers,
          body: jsonEncode({
            'model': model,
            'messages': [
              {'role': 'system', 'content': systemPrompt},
              {'role': 'user', 'content': userPrompt},
            ],
            'temperature': settings.temperature,
            'max_tokens': settings.maxTokens,
            'stream': false,
          }),
        )
        .timeout(timeout);
    if (response.statusCode != 200) {
      throw StateError(
          'The model server returned HTTP ${response.statusCode}.');
    }
    final text = textFromCompletion(jsonDecode(response.body));
    if (text == null) throw StateError('Empty response from model.');
    return text;
  }

  /// Assistant text from an OpenAI-style response. Falls back to the
  /// reasoning field when a thinking model put its answer there.
  static String? textFromCompletion(dynamic decoded) {
    if (decoded is! Map) return null;
    final choices = decoded['choices'];
    if (choices is List && choices.isNotEmpty && choices.first is Map) {
      final msg = (choices.first as Map)['message'];
      if (msg is Map) {
        final content = msg['content'];
        if (content is String && content.trim().isNotEmpty) {
          return content.trim();
        }
        for (final key in const ['reasoning_content', 'reasoning']) {
          final r = msg[key];
          if (r is String && r.contains('{')) return r.trim();
        }
      }
    }
    final content = decoded['content'];
    if (content is String && content.trim().isNotEmpty) return content.trim();
    return null;
  }
}
