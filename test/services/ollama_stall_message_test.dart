import 'package:flutter_test/flutter_test.dart';
import 'package:lm_mini/services/ollama_service.dart';

void main() {
  test('stall message points at the connection, not model loading', () {
    final msg = OllamaService.streamStalledMessage(16384);
    expect(msg, contains('stopped coming from your computer'));
    expect(msg, isNot(contains('loading')));
    expect(msg, isNot(contains('context window')));
  });

  test('a very large context gets a size hint', () {
    final msg = OllamaService.streamStalledMessage(128000);
    expect(msg, contains('125K'));
    expect(msg, contains('16K–32K'));
  });
}
