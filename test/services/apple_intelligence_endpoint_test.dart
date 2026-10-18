import 'package:flutter_test/flutter_test.dart';
import 'package:lm_mini/models/chat_message.dart';
import 'package:lm_mini/services/apple_intelligence_endpoint.dart';

ChatMessage _m(String id, String role, String content) => ChatMessage(
      id: id,
      role: role,
      content: content,
      timestamp: DateTime(2026),
    );

void main() {
  group('AppleIntelligenceStatus.parse', () {
    test('available map', () {
      expect(AppleIntelligenceStatus.parse({'available': true}),
          AppleIntelligenceStatus.available);
    });
    test('known reasons', () {
      for (final r in [
        'deviceNotEligible',
        'appleIntelligenceNotEnabled',
        'modelNotReady',
        'unsupportedOS',
      ]) {
        expect(
          AppleIntelligenceStatus.parse({'available': false, 'reason': r}).name,
          r,
        );
      }
    });
    test('unknown or junk → unavailable', () {
      expect(AppleIntelligenceStatus.parse({'reason': 'notBundled'}),
          AppleIntelligenceStatus.unavailable);
      expect(AppleIntelligenceStatus.parse(null),
          AppleIntelligenceStatus.unavailable);
    });
  });

  group('AppleIntelligenceEndpoint.buildPrompt', () {
    test('no history → just the message', () {
      expect(
        AppleIntelligenceEndpoint.buildPrompt(
            history: const [], userMessage: 'Hi', budgetTokens: 1000),
        'Hi',
      );
    });

    test('drops trailing current user bubble, temp and system messages', () {
      final p = AppleIntelligenceEndpoint.buildPrompt(
        history: [
          _m('s', 'system', 'SYS'),
          _m('1', 'user', 'What is 2+2?'),
          _m('2', 'assistant', '4'),
          _m('temp_x', 'assistant', 'partial'),
          _m('3', 'user', 'And 3+3?'),
        ],
        userMessage: 'And 3+3?',
        budgetTokens: 1000,
      );
      expect(p, contains('User: What is 2+2?'));
      expect(p, contains('Assistant: 4'));
      expect(p, isNot(contains('SYS')));
      expect(p, isNot(contains('partial')));
      expect('And 3+3?'.allMatches(p).length, 1);
      expect(p.trim().endsWith('And 3+3?'), isTrue);
    });

    test('keeps the most recent turns within budget', () {
      final long = 'x' * 400; // ~100 tokens
      final p = AppleIntelligenceEndpoint.buildPrompt(
        history: [
          _m('1', 'user', 'old $long'),
          _m('2', 'assistant', 'mid $long'),
          _m('3', 'assistant', 'new $long'),
          _m('4', 'user', 'q'),
        ],
        userMessage: 'q',
        budgetTokens: 150,
      );
      expect(p, contains('new '));
      expect(p, isNot(contains('old ')));
    });
  });
}
