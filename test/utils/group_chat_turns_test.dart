import 'package:flutter_test/flutter_test.dart';
import 'package:lm_mini/models/chat_message.dart';
import 'package:lm_mini/models/group_chat_participant.dart';
import 'package:lm_mini/utils/group_chat_turns.dart';

ChatMessage _user(String id, String text) => ChatMessage(
      id: id,
      content: text,
      role: 'user',
      timestamp: DateTime(2026),
    );

ChatMessage _ai(String id, String participantId, String text,
        {String? responseId}) =>
    ChatMessage(
      id: id,
      content: text,
      role: 'assistant',
      timestamp: DateTime(2026),
      participantId: participantId,
      responseId: responseId,
    );

void main() {
  group('replyRoute', () {
    test('group chat wins over a global on-device model', () {
      for (final kind in [
        'appleIntelligence',
        'onDeviceGguf',
        'onDeviceMlx',
        'lmStudio',
        null,
      ]) {
        expect(
          GroupChatTurns.replyRoute(isGroupChat: true, providerKind: kind),
          ChatReplyRoute.group,
          reason: '$kind',
        );
      }
    });

    test('1:1 chats still use on-device / network', () {
      expect(
        GroupChatTurns.replyRoute(
            isGroupChat: false, providerKind: 'appleIntelligence'),
        ChatReplyRoute.onDevice,
      );
      expect(
        GroupChatTurns.replyRoute(
            isGroupChat: false, providerKind: 'onDeviceMlx'),
        ChatReplyRoute.onDevice,
      );
      expect(
        GroupChatTurns.replyRoute(isGroupChat: false, providerKind: 'cloud'),
        ChatReplyRoute.network,
      );
    });
  });

  test('two on-device participants must run sequentially', () {
    expect(GroupChatTurns.mustRunSequentially(['onDeviceGguf', 'lmStudio']),
        isFalse);
    expect(GroupChatTurns.mustRunSequentially(['onDeviceMlx', 'onDeviceMlx']),
        isTrue);
    expect(
        GroupChatTurns.mustRunSequentially(
            ['appleIntelligence', 'onDeviceGguf', 'cloud']),
        isTrue);
    expect(GroupChatTurns.usesOnDeviceWeights('appleIntelligence'), isFalse);
    expect(GroupChatTurns.usesOnDeviceWeights('onDeviceGguf'), isTrue);
  });

  group('packed history', () {
    final messages = [
      _user('u1', 'hi'),
      _ai('a1', 'p1', 'hello'),
      _user('u2', 'question'),
      _ai('a2', 'p1', 'answer one'),
      _ai('temp_p2_1', 'p2', ''),
    ];

    test('stops before the latest user message', () {
      expect(GroupChatTurns.packedHistory(messages).map((m) => m.id),
          ['u1', 'a1']);
    });

    test('no user message → empty history', () {
      expect(GroupChatTurns.packedHistory([_ai('a', 'p1', 'x')]), isEmpty);
    });

    test('packed replies: everything after the latest user, no temps', () {
      expect(
        GroupChatTurns.contextReplies(messages, 'p2', packed: true)
            .map((m) => m.id),
        ['a2'],
      );
      // Own replies after the user message are kept for a packed turn
      // (autonomous / manual re-ask).
      expect(
        GroupChatTurns.contextReplies(messages, 'p1', packed: true)
            .map((m) => m.id),
        ['a2'],
      );
    });

    test('warm session: other replies since own last reply', () {
      final warm = [
        _user('u1', 'hi'),
        _ai('a1', 'p1', 'hello'),
        _ai('b1', 'p2', 'hey'),
        _user('u2', 'q'),
        _ai('b2', 'p2', 'reply'),
      ];
      expect(
        GroupChatTurns.contextReplies(warm, 'p1', packed: false)
            .map((m) => m.id),
        ['b1', 'b2'],
      );
      expect(
        GroupChatTurns.contextReplies(warm, 'p2', packed: false)
            .map((m) => m.id),
        isEmpty,
      );
    });
  });

  group('regenerate', () {
    final messages = [
      _user('u1', 'q1'),
      _ai('a1', 'p1', 'x'),
      _ai('a2', 'p3', 'y'),
      _user('u2', 'q2'),
      _ai('a3', 'p2', 'z'),
    ];

    test('re-runs only the participants that answered after the target', () {
      expect(
          GroupChatTurns.regenerateParticipantIds(messages, 1), ['p1', 'p3']);
      expect(GroupChatTurns.regenerateParticipantIds(messages, 2), ['p3']);
      expect(GroupChatTurns.regenerateParticipantIds(messages, 4), ['p2']);
    });

    test('session heads follow the newest remaining reply', () {
      final kept = [
        _user('u1', 'q1'),
        _ai('a1', 'p1', 'x', responseId: 'r1'),
        _ai('a2', 'p2', 'y', responseId: 'r2'),
        _user('u2', 'q2'),
        _ai('a3', 'p1', 'z', responseId: 'r3'),
      ];
      expect(
        GroupChatTurns.sessionHeads(kept, ['p1', 'p2', 'p3']),
        {'p1': 'r3', 'p2': 'r2', 'p3': null},
      );
    });
  });

  test('autonomous cap counts replies since the latest user message', () {
    final messages = <ChatMessage>[
      _ai('a0', 'p1', 'old'),
      _user('u1', 'go'),
      for (var i = 0; i < 11; i++) _ai('a$i', 'p${i % 2}', 'r$i'),
    ];
    expect(GroupChatTurns.repliesSinceLastUser(messages), 11);
    expect(GroupChatTurns.autonomousCapReached(messages), isFalse);
    messages.add(_ai('a11', 'p1', 'r11'));
    expect(GroupChatTurns.autonomousCapReached(messages), isTrue);
    messages.add(_user('u2', 'more'));
    expect(GroupChatTurns.autonomousCapReached(messages), isFalse);
  });

  group('stripOwnNamePrefix', () {
    test('drops a copied [Name]: label', () {
      expect(GroupChatTurns.stripOwnNamePrefix('[Bob]: Hi there', 'Bob'),
          'Hi there');
      expect(GroupChatTurns.stripOwnNamePrefix('  [bob] : Hi', 'Bob'), 'Hi');
      expect(GroupChatTurns.stripOwnNamePrefix('**[Bob]:** Hi', 'Bob'), 'Hi');
      expect(GroupChatTurns.stripOwnNamePrefix('**[Bob]**: Hi', 'Bob'), 'Hi');
    });

    test('keeps other names and mid-text labels', () {
      expect(GroupChatTurns.stripOwnNamePrefix('[Ann]: I disagree', 'Bob'),
          '[Ann]: I disagree');
      expect(GroupChatTurns.stripOwnNamePrefix('Hi [Bob]: yes', 'Bob'),
          'Hi [Bob]: yes');
      expect(GroupChatTurns.stripOwnNamePrefix('[Bob] I think', 'Bob'),
          '[Bob] I think');
    });

    test('works after a think block and with regex characters', () {
      expect(
        GroupChatTurns.stripOwnNamePrefix(
            '<think>plan</think>\n[Dr. X (2)]: Answer', 'Dr. X (2)'),
        '<think>plan</think>\nAnswer',
      );
    });
  });

  test('editing model / persona resets the participant session', () {
    final p = GroupChatParticipant(
      id: 'p1',
      modelId: 'qwen',
      displayName: 'Q',
      providerKind: 'lmStudio',
      lastResponseId: 'r1',
    );
    expect(GroupChatTurns.sessionFieldsChanged(p, p.copyWith()), isFalse);
    expect(GroupChatTurns.sessionFieldsChanged(p, p.copyWith(displayName: 'Z')),
        isFalse);
    expect(GroupChatTurns.sessionFieldsChanged(p, p.copyWith(modelId: 'llama')),
        isTrue);
    expect(
        GroupChatTurns.sessionFieldsChanged(
            p, p.copyWith(systemPrompt: 'be brief')),
        isTrue);
    expect(
        GroupChatTurns.sessionFieldsChanged(
            p, p.copyWith(providerKind: 'onDeviceGguf')),
        isTrue);
  });
}
