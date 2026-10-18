import 'dart:convert';

import '../models/chat_conversation.dart';
import '../models/chat_message.dart';
import '../models/group_chat_participant.dart';
import '../utils/expression_tags.dart';
import '../utils/response_parser.dart';

/// Shared text helpers for every chat export format (TXT, PDF, ZIP and the
/// Pro Markdown / Obsidian / JSON formats).

/// Characters no file system accepts (Windows is the strictest), plus C0
/// controls and DEL.
final RegExp _kForbiddenFileNameChars = RegExp(r'[\\/:*?"<>|\x00-\x1F\x7F]');

/// Safe base name (no extension) for an exported chat file.
///
/// Keeps every script (Cyrillic, CJK, emoji …), replaces only characters a
/// file system rejects, collapses whitespace, trims dots/spaces at the ends
/// and caps the result at [maxChars] characters and under [maxUtf8Bytes]
/// UTF-8 bytes (most file systems allow 255 bytes per name; the caller still
/// appends a timestamp and extension). Falls back to `chat`.
String exportSafeFileName(
  String title, {
  int maxChars = 80,
  int maxUtf8Bytes = 199,
}) {
  var name = title
      .replaceAll(RegExp(r'\s+'), ' ')
      .replaceAll(_kForbiddenFileNameChars, '_')
      .replaceAll(RegExp(r' {2,}'), ' ');
  name = _trimNameEnds(name);

  var runes = name.runes.toList();
  if (runes.length > maxChars) runes = runes.sublist(0, maxChars);
  while (runes.isNotEmpty &&
      utf8.encode(String.fromCharCodes(runes)).length > maxUtf8Bytes) {
    runes.removeLast();
  }
  name = _trimNameEnds(String.fromCharCodes(runes));
  return name.isEmpty ? 'chat' : name;
}

String _trimNameEnds(String s) =>
    s.replaceAll(RegExp(r'^[\s.]+'), '').replaceAll(RegExp(r'[\s.]+$'), '');

/// Returns [name] + [extension], or `name (2).ext`, `name (3).ext` … when
/// that entry is already in [taken] (compared case-insensitively, since the
/// macOS / Windows file systems an archive is unpacked on usually are).
/// Adds the chosen name to [taken].
String uniqueExportEntryName(
  String name,
  String extension,
  Set<String> taken,
) {
  var candidate = '$name$extension';
  var n = 2;
  while (taken.contains(candidate.toLowerCase())) {
    candidate = '$name ($n)$extension';
    n++;
  }
  taken.add(candidate.toLowerCase());
  return candidate;
}

/// Tool / MCP plumbing messages the chat hides; exports skip them too.
bool isExportableMessage(ChatMessage m) {
  if (m.role == 'tool' || m.role == 'mcp') return false;
  final c = m.content;
  if (m.role == 'assistant' &&
      (c.startsWith('MCP call:') || c.startsWith('🔧 MCP call:'))) {
    return false;
  }
  return !c.startsWith('Tool call:');
}

List<ChatMessage> exportableMessages(List<ChatMessage> messages) =>
    messages.where(isExportableMessage).toList();

/// Group chat participant id → display name, read from the conversation
/// settings (empty for normal chats).
Map<String, String> exportParticipantNames(ChatConversation conversation) {
  final raw = conversation.settings['participants'];
  if (raw is! List) return const {};
  final names = <String, String>{};
  for (final p in raw) {
    if (p is! Map) continue;
    try {
      final participant =
          GroupChatParticipant.fromJson(Map<String, dynamic>.from(p));
      if (participant.displayName.trim().isNotEmpty) {
        names[participant.id] = participant.displayName.trim();
      }
    } catch (_) {
      // Malformed participant entry: fall back to the generic label.
    }
  }
  return names;
}

/// Speaker label used in exports: `You`, the group participant's name, or
/// `Assistant` / `System`.
String exportSpeakerName(
  ChatMessage m, [
  Map<String, String> participantNames = const {},
]) {
  if (m.role == 'user') return 'You';
  if (m.role == 'system') return 'System';
  final pid = m.participantId;
  if (pid != null && participantNames[pid] != null) {
    return participantNames[pid]!;
  }
  return 'Assistant';
}

/// What a message shows in the chat: the visible answer, plus the reasoning
/// block the bubble collapses (assistant messages only).
class ExportMessageText {
  final String answer;
  final String? reasoning;

  const ExportMessageText(this.answer, this.reasoning);
}

/// Same visible text the chat bubble renders: thinking split off, hidden
/// model tags (`[IMG_PROMPT: …]`, `[MEMORY_SAVE: …]`, `[EXPRESSION: …]` …)
/// removed, and a copied `[Name]:` prefix dropped in group chats.
ExportMessageText exportMessageText(ChatMessage m, {String? speakerName}) {
  if (m.role == 'user') return ExportMessageText(m.content.trim(), null);
  final parsed = ResponseParser.parse(m.content);
  var answer = extractExpressionTag(parsed.answer).cleanContent;
  answer = ResponseParser.stripHiddenModelTags(answer);
  if (speakerName != null && speakerName.isNotEmpty) {
    answer = answer.replaceFirst(
      RegExp('^\\[${RegExp.escape(speakerName)}\\]:\\s*', caseSensitive: false),
      '',
    );
  }
  final reasoning = parsed.thinking?.trim();
  return ExportMessageText(
    answer.trim(),
    (reasoning == null || reasoning.isEmpty) ? null : reasoning,
  );
}
