import '../models/chat_message.dart';
import '../models/group_chat_participant.dart';

/// Where a chat turn's reply comes from.
enum ChatReplyRoute { group, onDevice, network }

/// Pure helpers for group-chat turns: routing order, which messages a
/// participant sees, regenerate / session bookkeeping and loop caps.
abstract final class GroupChatTurns {
  /// Autonomous mode stops after this many AI replies to one user message.
  static const int maxAutonomousRepliesPerUserTurn = 12;

  /// Group chats route per participant, so they are checked before the
  /// global on-device model: with Apple Intelligence / GGUF / MLX selected
  /// globally, a group send must still reach its participants.
  static ChatReplyRoute replyRoute({
    required bool isGroupChat,
    required String? providerKind,
  }) {
    if (isGroupChat) return ChatReplyRoute.group;
    if (isOnDeviceKind(providerKind)) return ChatReplyRoute.onDevice;
    return ChatReplyRoute.network;
  }

  /// Backends that run on this device (no server).
  static bool isOnDeviceKind(String? kind) =>
      kind == 'onDeviceGguf' ||
      kind == 'onDeviceMlx' ||
      kind == 'appleIntelligence';

  /// Backends whose weights [OnDeviceLLMService] loads (one model at a time).
  static bool usesOnDeviceWeights(String? kind) =>
      kind == 'onDeviceGguf' || kind == 'onDeviceMlx';

  /// Two or more on-device participants share one native slot (MLX has a
  /// single loaded context, Apple Intelligence a single stream channel), so
  /// they must answer one after another even in parallel mode.
  static bool mustRunSequentially(Iterable<String?> kinds) =>
      kinds.where(isOnDeviceKind).length >= 2;

  static int lastUserIndex(List<ChatMessage> messages) {
    for (var i = messages.length - 1; i >= 0; i--) {
      if (messages[i].role == 'user') return i;
    }
    return -1;
  }

  /// History to pack for a participant without a server session: every
  /// turn before the latest user message. That message and the replies
  /// after it travel in the participant's input instead, so they are not
  /// sent twice.
  static List<ChatMessage> packedHistory(List<ChatMessage> messages) {
    final idx = lastUserIndex(messages);
    if (idx <= 0) return const [];
    return [
      for (final m in messages.sublist(0, idx))
        if (!m.id.startsWith('temp_')) m,
    ];
  }

  /// Replies listed in [participantId]'s input before the user's message.
  ///
  /// * Warm session ([packed] false): the server already has this
  ///   participant's own turns, so only other participants' replies since
  ///   its last reply.
  /// * Packed: the history stops at the latest user message, so every reply
  ///   after it, including this participant's own earlier ones.
  ///
  /// Streaming bubbles (`temp_…`) are never included.
  static List<ChatMessage> contextReplies(
    List<ChatMessage> messages,
    String participantId, {
    required bool packed,
  }) {
    var start = 0;
    if (packed) {
      start = lastUserIndex(messages) + 1;
    } else {
      for (var i = messages.length - 1; i >= 0; i--) {
        final m = messages[i];
        if (m.role == 'assistant' && m.participantId == participantId) {
          start = i + 1;
          break;
        }
      }
    }
    return [
      for (var i = start; i < messages.length; i++)
        if (messages[i].role == 'assistant' &&
            !messages[i].id.startsWith('temp_') &&
            messages[i].participantId != null &&
            (packed || messages[i].participantId != participantId))
          messages[i],
    ];
  }

  /// Participants to re-run when regenerating the reply at [targetIndex]:
  /// the ones that actually answered from there up to the next user
  /// message, in the order they answered (manual / random / @mention turns
  /// only had some of them).
  static List<String> regenerateParticipantIds(
    List<ChatMessage> messages,
    int targetIndex,
  ) {
    final ids = <String>[];
    for (var i = targetIndex; i < messages.length; i++) {
      final m = messages[i];
      if (m.role == 'user') break;
      final id = m.participantId;
      if (m.role == 'assistant' && id != null && !ids.contains(id)) {
        ids.add(id);
      }
    }
    return ids;
  }

  /// The LM Studio response id each participant should continue from after
  /// turns were deleted: its newest remaining reply's id, or null (cold).
  static Map<String, String?> sessionHeads(
    List<ChatMessage> messages,
    Iterable<String> participantIds,
  ) {
    final heads = <String, String?>{for (final id in participantIds) id: null};
    final pending = heads.keys.toSet();
    for (var i = messages.length - 1; i >= 0 && pending.isNotEmpty; i--) {
      final m = messages[i];
      final id = m.participantId;
      if (m.role != 'assistant' || id == null || !pending.contains(id)) {
        continue;
      }
      if (m.id.startsWith('temp_')) continue;
      heads[id] = m.responseId;
      pending.remove(id);
    }
    return heads;
  }

  /// AI replies since the latest user message.
  static int repliesSinceLastUser(List<ChatMessage> messages) {
    var n = 0;
    for (var i = messages.length - 1; i >= 0; i--) {
      final m = messages[i];
      if (m.role == 'user') break;
      if (m.role == 'assistant' &&
          m.participantId != null &&
          !m.id.startsWith('temp_')) {
        n++;
      }
    }
    return n;
  }

  static bool autonomousCapReached(
    List<ChatMessage> messages, {
    int cap = maxAutonomousRepliesPerUserTurn,
  }) =>
      repliesSinceLastUser(messages) >= cap;

  /// Whether an edit changes what the participant's server session was
  /// built with (model, backend, persona), so it must start cold.
  static bool sessionFieldsChanged(
    GroupChatParticipant before,
    GroupChatParticipant after,
  ) =>
      before.modelId != after.modelId ||
      before.providerKind != after.providerKind ||
      before.cloudProviderId != after.cloudProviderId ||
      before.personaId != after.personaId ||
      before.systemPrompt != after.systemPrompt;

  /// Drop a leading `[OwnName]:` the model copied from the transcript labels
  /// (also `**[OwnName]:**`). A leading `<think>…</think>` block is kept.
  static String stripOwnNamePrefix(String text, String name) {
    final trimmedName = name.trim();
    if (trimmedName.isEmpty || text.isEmpty) return text;
    var head = '';
    var body = text;
    if (body.trimLeft().startsWith('<think>')) {
      final end = body.indexOf('</think>');
      if (end < 0) return text;
      head = body.substring(0, end + '</think>'.length);
      body = body.substring(end + '</think>'.length);
    }
    final escaped = RegExp.escape(trimmedName);
    final prefix = RegExp(
      '^\\s*(?:\\*\\*)?\\[$escaped\\](?:\\*\\*)?\\s*:(?:\\*\\*)?[ \\t]*',
      caseSensitive: false,
    );
    final boldInside = RegExp(
      '^\\s*\\*\\*\\[$escaped\\]:\\*\\*[ \\t]*',
      caseSensitive: false,
    );
    final m = boldInside.firstMatch(body) ?? prefix.firstMatch(body);
    if (m == null) return text;
    final rest = body.substring(m.end);
    return head.isEmpty ? rest : '$head\n${rest.trimLeft()}';
  }
}
