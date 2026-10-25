import 'package:flutter_test/flutter_test.dart';
import 'package:lm_mini/models/chat_conversation.dart';
import 'package:lm_mini/providers/chat_provider.dart';
import 'package:lm_mini/services/icloud_sync_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('opening a chat that no longer exists does not leave a spinner',
      () async {
    final chat = ChatProvider();
    await chat.selectConversation('deleted-chat-id');
    expect(chat.isLoading, isFalse);
    expect(chat.currentConversation, isNull);
  });

  test('iCloud skips untouched New Chat drafts only', () {
    ChatConversation convo({required bool draft}) => ChatConversation(
          id: 'c1',
          title: 'New Chat',
          createdAt: DateTime(2026),
          updatedAt: DateTime(2026),
          messageIds: const [],
          settings: {if (draft) 'isDraft': true},
        );
    expect(ICloudSyncService.isEmptyDraft(convo(draft: true), 0), isTrue);
    expect(ICloudSyncService.isEmptyDraft(convo(draft: true), 2), isFalse);
    expect(ICloudSyncService.isEmptyDraft(convo(draft: false), 0), isFalse);
  });

  test('iCloud upload signature changes only when the chat changes', () {
    final c = ChatConversation(
      id: 'c1',
      title: 'Trip',
      createdAt: DateTime(2026),
      updatedAt: DateTime(2026, 1, 2),
      messageIds: const [],
      settings: const {},
    );
    final base = ICloudSyncService.signature(c, '3|100|42|0|0|0|0');
    expect(ICloudSyncService.signature(c, '3|100|42|0|0|0|0'), base);
    expect(ICloudSyncService.signature(c, '4|120|60|0|0|0|0'), isNot(base));
    expect(
      ICloudSyncService.signature(
          c.copyWith(title: 'Trip 2'), '3|100|42|0|0|0|0'),
      isNot(base),
    );
  });

  test('iCloud payload hash is stable and detects edits', () {
    const a = '[{"id":"m1","content":"hi"}]';
    expect(ICloudSyncService.payloadHash(a), ICloudSyncService.payloadHash(a));
    expect(ICloudSyncService.payloadHash(a),
        isNot(ICloudSyncService.payloadHash('[{"id":"m1","content":"ho"}]')));
  });
}
