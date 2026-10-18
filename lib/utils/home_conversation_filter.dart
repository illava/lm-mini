import '../models/chat_conversation.dart';

/// Home list filtering shared by the Chats / Groups tabs and folders.
///
/// Outside a folder the tab decides: Groups shows group chats, Chats shows
/// 1:1 chats. Inside a folder ([folderId] set) the Chats/Groups toggle is
/// hidden, so the folder shows everything filed in it, group chats included.
List<ChatConversation> filterHomeConversations(
  Iterable<ChatConversation> conversations, {
  required bool groupsTab,
  String? folderId,
  String query = '',
}) {
  final q = query.toLowerCase();
  return conversations.where((c) {
    if (folderId != null) {
      if (c.folderId != folderId) return false;
    } else if (c.isGroupChat != groupsTab) {
      return false;
    }
    if (q.isNotEmpty && !c.title.toLowerCase().contains(q)) return false;
    return true;
  }).toList();
}

/// Chats (1:1 and group) filed in [folderId]; `null` counts unfiled ones.
int folderConversationCount(
  Iterable<ChatConversation> conversations,
  String? folderId,
) =>
    conversations.where((c) => c.folderId == folderId).length;
