import 'package:flutter_test/flutter_test.dart';
import 'package:lm_mini/models/chat_conversation.dart';
import 'package:lm_mini/utils/home_conversation_filter.dart';

ChatConversation _conv(String id,
    {bool group = false, String? folderId, String? title}) {
  final now = DateTime(2026, 1, 1);
  return ChatConversation(
    id: id,
    title: title ?? id,
    createdAt: now,
    updatedAt: now,
    messageIds: const [],
    settings: group ? {'isGroupChat': true} : <String, dynamic>{},
    folderId: folderId,
  );
}

void main() {
  group('ChatConversation.movedToFolder', () {
    test('files a group chat into a folder and keeps its group settings', () {
      final moved = _conv('g1', group: true).movedToFolder('f1');
      expect(moved.folderId, 'f1');
      expect(moved.isGroupChat, isTrue);
    });

    test('null takes a chat out of its folder', () {
      final moved = _conv('g1', group: true, folderId: 'f1').movedToFolder(null);
      expect(moved.folderId, isNull);
      // Plain copyWith keeps the folder (nullable fields fall back).
      expect(_conv('c1', folderId: 'f1').copyWith(folderId: null).folderId,
          'f1');
    });

    test('folder survives the JSON round trip', () {
      final moved = _conv('g1', group: true).movedToFolder('f1');
      final back = ChatConversation.fromJson(moved.toJson());
      expect(back.folderId, 'f1');
      expect(back.isGroupChat, isTrue);
    });
  });

  group('filterHomeConversations', () {
    final all = [
      _conv('c1'),
      _conv('c2', folderId: 'f1'),
      _conv('g1', group: true),
      _conv('g2', group: true, folderId: 'f1', title: 'Writers room'),
      _conv('g3', group: true, folderId: 'f2'),
    ];
    List<String> ids(List<ChatConversation> l) => l.map((c) => c.id).toList();

    test('tabs split chats and group chats outside folders', () {
      expect(ids(filterHomeConversations(all, groupsTab: false)), ['c1', 'c2']);
      expect(ids(filterHomeConversations(all, groupsTab: true)),
          ['g1', 'g2', 'g3']);
    });

    test('a folder lists its chats and group chats on either tab', () {
      for (final groupsTab in [false, true]) {
        expect(
          ids(filterHomeConversations(all,
              groupsTab: groupsTab, folderId: 'f1')),
          ['c2', 'g2'],
        );
      }
    });

    test('search applies inside a folder', () {
      expect(
        ids(filterHomeConversations(all,
            groupsTab: false, folderId: 'f1', query: 'WRITERS')),
        ['g2'],
      );
    });

    test('a group chat moved into a folder shows there', () {
      final moved = [
        for (final c in all) c.id == 'g1' ? c.movedToFolder('f2') : c,
      ];
      expect(
        ids(filterHomeConversations(moved, groupsTab: false, folderId: 'f2')),
        ['g1', 'g3'],
      );
      expect(folderConversationCount(moved, 'f2'), 2);
    });
  });

  test('folder counts include group chats', () {
    final all = [
      _conv('c1'),
      _conv('c2', folderId: 'f1'),
      _conv('g1', group: true),
      _conv('g2', group: true, folderId: 'f1'),
    ];
    expect(folderConversationCount(all, 'f1'), 2);
    expect(folderConversationCount(all, null), 2);
    expect(folderConversationCount(all, 'missing'), 0);
  });
}
