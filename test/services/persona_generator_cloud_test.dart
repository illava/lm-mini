import 'package:flutter_test/flutter_test.dart';
import 'package:lm_mini/services/persona_generator_service.dart';

void main() {
  const parse = PersonaGeneratorService.personaTextFromCompletion;

  test('reads OpenAI-style content (Ollama /v1/chat/completions)', () {
    expect(
      parse({
        'choices': [
          {
            'message': {'role': 'assistant', 'content': ' {"name":"Ada"} '}
          }
        ]
      }),
      '{"name":"Ada"}',
    );
  });

  test('falls back to reasoning when a thinking model left content empty', () {
    expect(
      parse({
        'choices': [
          {
            'message': {'content': '', 'reasoning': 'ok {"name":"Ada"}'}
          }
        ]
      }),
      'ok {"name":"Ada"}',
    );
  });

  test('null when there is no text', () {
    expect(parse({'choices': []}), isNull);
    expect(parse('nope'), isNull);
  });
}
