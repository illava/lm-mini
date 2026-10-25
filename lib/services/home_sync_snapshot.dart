import '../models/chat_conversation.dart';
import '../models/chat_folder.dart';
import '../models/chat_message.dart';
import '../models/system_prompt.dart';
import '../utils/chat_title.dart';

class HomeSyncTombstone {
  const HomeSyncTombstone({required this.id, required this.deletedAt});

  final String id;
  final DateTime deletedAt;

  Map<String, dynamic> toJson() => {
        'id': id,
        'deletedAt': deletedAt.toIso8601String(),
      };

  factory HomeSyncTombstone.fromJson(Map<String, dynamic> json) {
    return HomeSyncTombstone(
      id: json['id'] as String,
      deletedAt: DateTime.tryParse(json['deletedAt'] as String? ?? '') ??
          DateTime.fromMillisecondsSinceEpoch(0),
    );
  }
}

/// One picture / attachment carried in a sync body. [path] is relative to
/// the app documents directory (see [HomeSyncFiles.sanitize]).
class HomeSyncFile {
  const HomeSyncFile({required this.path, required this.data});

  final String path;

  /// File bytes, base64.
  final String data;

  Map<String, dynamic> toJson() => {'path': path, 'data': data};

  static HomeSyncFile? tryParse(Map<String, dynamic> json) {
    final path = json['path'];
    final data = json['data'];
    if (path is! String || data is! String || data.isEmpty) return null;
    return HomeSyncFile(path: path, data: data);
  }
}

class HomeSyncConversation {
  const HomeSyncConversation({
    required this.conversation,
    required this.messages,
  });

  final ChatConversation conversation;
  final List<ChatMessage> messages;

  Map<String, dynamic> toJson() => {
        'conversation': conversation.toJson(),
        'messages': messages.map((m) => m.toJson()).toList(),
      };

  factory HomeSyncConversation.fromJson(Map<String, dynamic> json) {
    final rawMessages = json['messages'];
    return HomeSyncConversation(
      conversation: ChatConversation.fromJson(
        Map<String, dynamic>.from(json['conversation'] as Map),
      ),
      messages: rawMessages is List
          ? rawMessages
              .whereType<Map>()
              .map((m) => ChatMessage.fromJson(Map<String, dynamic>.from(m)))
              .toList()
          : const [],
    );
  }
}

class HomeSyncPersonaInfo {
  const HomeSyncPersonaInfo({
    required this.id,
    required this.name,
    required this.updatedAt,
    this.memoryCount = 0,
    this.hasAvatar = false,
    this.color,
  });

  final String id;
  final String name;
  final DateTime updatedAt;
  final int memoryCount;
  final bool hasAvatar;
  final int? color;

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'updatedAt': updatedAt.toIso8601String(),
        'memoryCount': memoryCount,
        'hasAvatar': hasAvatar,
        if (color != null) 'color': color,
      };

  factory HomeSyncPersonaInfo.fromJson(Map<String, dynamic> json) {
    return HomeSyncPersonaInfo(
      id: json['id'] as String? ?? '',
      name: json['name'] as String? ?? '',
      updatedAt: DateTime.tryParse(json['updatedAt'] as String? ?? '') ??
          DateTime.fromMillisecondsSinceEpoch(0),
      memoryCount: (json['memoryCount'] as num?)?.toInt() ?? 0,
      hasAvatar: json['hasAvatar'] as bool? ?? false,
      color: json['color'] is int
          ? json['color'] as int
          : (json['color'] as num?)?.toInt(),
    );
  }
}

class HomeSyncPersona {
  const HomeSyncPersona({
    required this.prompt,
    this.avatarBase64,
    this.avatarExt,
    this.memories = const [],
  });

  final SystemPrompt prompt;
  final String? avatarBase64;
  final String? avatarExt;
  final List<Map<String, dynamic>> memories;

  Map<String, dynamic> toJson() => {
        'prompt': prompt.toJson(),
        if (avatarBase64 != null) 'avatarBase64': avatarBase64,
        if (avatarExt != null) 'avatarExt': avatarExt,
        'memories': memories,
      };

  factory HomeSyncPersona.fromJson(Map<String, dynamic> json) {
    final rawMem = json['memories'];
    return HomeSyncPersona(
      prompt: SystemPrompt.fromJson(
        Map<String, dynamic>.from(json['prompt'] as Map),
      ),
      avatarBase64: json['avatarBase64'] as String?,
      avatarExt: json['avatarExt'] as String?,
      memories: rawMem is List
          ? [
              for (final item in rawMem)
                if (item is Map) Map<String, dynamic>.from(item),
            ]
          : const [],
    );
  }
}

class HomeSyncSnapshot {
  const HomeSyncSnapshot({
    this.folders = const [],
    this.conversations = const [],
    this.deletedConversations = const [],
    this.deletedFolders = const [],
    this.personaCatalog = const [],
    this.personas = const [],
    this.syncPersonaIds = const [],
    this.personasEnabled = false,
    this.personasUpdatedAt,
    this.known,
    this.deletedPersonas = const [],
    this.deletedMemories = const [],
    this.files = const [],
    this.wantFiles = const [],
    this.unavailableFiles = const [],
    this.fileSync = false,
  });

  /// Persona memories deleted (or replaced by an edit) on either device,
  /// keyed by [HomeSyncMerge.memoryKey]. Older hosts ignore this field.
  final List<HomeSyncTombstone> deletedMemories;

  /// Pictures / attachments referenced by chats in this body that the other
  /// device may not have. Older hosts ignore this field.
  final List<HomeSyncFile> files;

  /// Relative paths this device is missing and asks the other to send.
  final List<String> wantFiles;

  /// Asked-for paths the sender doesn't have (or won't send: too big), so the
  /// asker stops asking.
  final List<String> unavailableFiles;

  /// The sender understands [files] / [wantFiles]. Lets each side skip
  /// sending bytes to an older device that would drop them.
  final bool fileSync;

  /// Personas deleted on either device (so the other doesn't bring them
  /// back). Older hosts ignore this field.
  final List<HomeSyncTombstone> deletedPersonas;

  /// Phone → Mac: what the phone already has (`id → manifest entry`, see
  /// [HomeSyncManifest]). A host that understands it answers with only the
  /// chats that differ; an older host ignores it and sends everything.
  final Map<String, String>? known;

  /// Same snapshot with a different chat list (host: send only changes).
  HomeSyncSnapshot withConversations(List<HomeSyncConversation> items) =>
      HomeSyncSnapshot(
        folders: folders,
        conversations: items,
        deletedConversations: deletedConversations,
        deletedFolders: deletedFolders,
        personaCatalog: personaCatalog,
        personas: personas,
        syncPersonaIds: syncPersonaIds,
        personasEnabled: personasEnabled,
        personasUpdatedAt: personasUpdatedAt,
        deletedPersonas: deletedPersonas,
        deletedMemories: deletedMemories,
        fileSync: fileSync,
      );

  /// Same snapshot carrying file transfer fields (replacing any present).
  HomeSyncSnapshot withFiles({
    List<HomeSyncFile> files = const [],
    List<String> wantFiles = const [],
    List<String> unavailableFiles = const [],
    bool fileSync = true,
  }) =>
      HomeSyncSnapshot(
        folders: folders,
        conversations: conversations,
        deletedConversations: deletedConversations,
        deletedFolders: deletedFolders,
        personaCatalog: personaCatalog,
        personas: personas,
        syncPersonaIds: syncPersonaIds,
        personasEnabled: personasEnabled,
        personasUpdatedAt: personasUpdatedAt,
        known: known,
        deletedPersonas: deletedPersonas,
        deletedMemories: deletedMemories,
        files: files,
        wantFiles: wantFiles,
        unavailableFiles: unavailableFiles,
        fileSync: fileSync,
      );

  final List<ChatFolder> folders;
  final List<HomeSyncConversation> conversations;
  final List<HomeSyncTombstone> deletedConversations;
  final List<HomeSyncTombstone> deletedFolders;
  final List<HomeSyncPersonaInfo> personaCatalog;
  final List<HomeSyncPersona> personas;
  final List<String> syncPersonaIds;
  final bool personasEnabled;
  final DateTime? personasUpdatedAt;

  Map<String, dynamic> toJson() => {
        'folders': folders.map((f) => f.toJson()).toList(),
        'conversations': conversations.map((c) => c.toJson()).toList(),
        'deletedConversations':
            deletedConversations.map((t) => t.toJson()).toList(),
        'deletedFolders': deletedFolders.map((t) => t.toJson()).toList(),
        'personaCatalog': personaCatalog.map((p) => p.toJson()).toList(),
        'personas': personas.map((p) => p.toJson()).toList(),
        'syncPersonaIds': syncPersonaIds,
        'personasEnabled': personasEnabled,
        if (personasUpdatedAt != null)
          'personasUpdatedAt': personasUpdatedAt!.toIso8601String(),
        if (known != null) 'known': known,
        if (deletedPersonas.isNotEmpty)
          'deletedPersonas': deletedPersonas.map((t) => t.toJson()).toList(),
        if (deletedMemories.isNotEmpty)
          'deletedMemories': deletedMemories.map((t) => t.toJson()).toList(),
        if (files.isNotEmpty) 'files': files.map((f) => f.toJson()).toList(),
        if (wantFiles.isNotEmpty) 'wantFiles': wantFiles,
        if (unavailableFiles.isNotEmpty) 'unavailableFiles': unavailableFiles,
        if (fileSync) 'fileSync': true,
      };

  factory HomeSyncSnapshot.fromJson(Map<String, dynamic> json) {
    List<T> parseList<T>(String key, T Function(Map<String, dynamic>) parse) {
      final raw = json[key];
      if (raw is! List) return const [];
      return [
        for (final item in raw)
          if (item is Map) parse(Map<String, dynamic>.from(item)),
      ];
    }

    List<String> parseStrings(String key) {
      final raw = json[key];
      if (raw is! List) return const [];
      return [
        for (final item in raw)
          if (item is String && item.isNotEmpty) item,
      ];
    }

    final rawFiles = json['files'];
    return HomeSyncSnapshot(
      folders: parseList('folders', ChatFolder.fromJson),
      conversations: parseList('conversations', HomeSyncConversation.fromJson),
      deletedConversations:
          parseList('deletedConversations', HomeSyncTombstone.fromJson),
      deletedFolders: parseList('deletedFolders', HomeSyncTombstone.fromJson),
      personaCatalog: parseList('personaCatalog', HomeSyncPersonaInfo.fromJson),
      personas: parseList('personas', HomeSyncPersona.fromJson),
      syncPersonaIds: (json['syncPersonaIds'] as List?)
              ?.map((e) => e.toString())
              .where((id) => id.isNotEmpty)
              .toList() ??
          const [],
      personasEnabled: json['personasEnabled'] as bool? ?? false,
      personasUpdatedAt: DateTime.tryParse(
        json['personasUpdatedAt'] as String? ?? '',
      ),
      deletedPersonas:
          parseList('deletedPersonas', HomeSyncTombstone.fromJson),
      deletedMemories:
          parseList('deletedMemories', HomeSyncTombstone.fromJson),
      files: rawFiles is List
          ? [
              for (final item in rawFiles)
                if (item is Map)
                  HomeSyncFile.tryParse(Map<String, dynamic>.from(item)),
            ].whereType<HomeSyncFile>().toList()
          : const [],
      wantFiles: parseStrings('wantFiles'),
      unavailableFiles: parseStrings('unavailableFiles'),
      fileSync: json['fileSync'] == true,
      known: json['known'] is Map
          ? {
              for (final e in (json['known'] as Map).entries)
                e.key.toString(): e.value.toString(),
            }
          : null,
    );
  }
}

/// One line per chat describing its state, computed the same way on the
/// phone and the Mac from their own database (chat row + the grouped
/// message fingerprint from `DatabaseService.messageFingerprints`). Equal
/// entries mean the chat is already in sync and needn't be sent.
abstract final class HomeSyncManifest {
  static String entry(ChatConversation c, String? messageFingerprint) =>
      '${c.updatedAt.millisecondsSinceEpoch}|${c.folderId ?? ''}|${c.title}'
      '#${messageFingerprint ?? '0'}';

  /// Message count from a `messageFingerprints` value.
  static int messageCount(String? fingerprint) =>
      fingerprint == null ? 0 : int.tryParse(fingerprint.split('|').first) ?? 0;

  /// An untouched New Chat: never synced.
  static bool isEmptyDraft(ChatConversation c, int messageCount) =>
      c.settings['isDraft'] == true && messageCount == 0;
}

/// Pure helpers for carrying chat pictures / attachments in sync bodies.
abstract final class HomeSyncFiles {
  /// A single file larger than this is never sent.
  static const maxFileBytes = 8 * 1024 * 1024;

  /// Base64 bytes of files per sync body (the relay caps a body at 100 MB);
  /// whatever doesn't fit goes in a later round.
  static const maxBodyBytes = 40 * 1024 * 1024;

  /// Top-level folders (under the documents dir) chat files live in. Nothing
  /// else is ever written by sync.
  static const allowedRoots = {'images', 'generated_images', 'attachments'};

  /// Paths a sync list carries at most (want / owed lists).
  static const maxListed = 2000;

  /// [raw] as a safe path relative to the documents dir, or null: no
  /// absolute paths, schemes, `..`/`.` or empty segments, backslashes or
  /// control characters, and only inside [allowedRoots].
  static String? sanitize(String? raw) {
    if (raw == null) return null;
    final path = raw.trim();
    if (path.isEmpty || path.length > 400) return null;
    if (path.startsWith('/') || path.startsWith('~')) return null;
    if (path.contains('\\') || path.contains(':')) return null;
    if (RegExp(r'[\x00-\x1f\x7f]').hasMatch(path)) return null;
    final parts = path.split('/');
    if (parts.length < 2) return null;
    for (final part in parts) {
      if (part.isEmpty || part == '.' || part == '..') return null;
    }
    if (!allowedRoots.contains(parts.first)) return null;
    return path;
  }

  /// The wire path for a path stored in a message: relative paths as-is,
  /// absolute ones under [docsDir] (or any `/Documents/` folder, as
  /// `ImagePickerHelper.resolveImagePath` does) made relative. Remote
  /// `http(s)`, `data:` and inline base64 images are skipped (null): they
  /// already show on the other device.
  static String? wirePath(String? stored, {String? docsDir}) {
    if (stored == null) return null;
    var path = stored.trim();
    if (path.isEmpty || path.length > 1024) return null;
    final lower = path.toLowerCase();
    if (lower.startsWith('data:') || lower.contains('://')) return null;
    if (path.startsWith('/')) {
      final root = docsDir == null
          ? null
          : (docsDir.endsWith('/') ? docsDir : '$docsDir/');
      if (root != null && path.startsWith(root)) {
        path = path.substring(root.length);
      } else {
        const marker = '/Documents/';
        final idx = path.indexOf(marker);
        if (idx == -1) return null;
        path = path.substring(idx + marker.length);
      }
    }
    return sanitize(path);
  }

  /// Every local file the [messages] reference, as wire paths.
  static Set<String> referencedPaths(
    Iterable<ChatMessage> messages, {
    String? docsDir,
  }) {
    final out = <String>{};
    void add(String? stored) {
      final path = wirePath(stored, docsDir: docsDir);
      if (path != null) out.add(path);
    }

    for (final m in messages) {
      for (final url in m.imageUrls ?? const <String>[]) {
        add(url);
      }
      for (final path in m.allGeneratedImagePaths) {
        add(path);
      }
      for (final file in m.fileAttachments ?? const []) {
        add(file.filePath);
      }
    }
    return out;
  }

  /// Length of [bytes] once base64-encoded.
  static int encodedLength(int bytes) => ((bytes + 2) ~/ 3) * 4;

  /// Picks which [candidates] (in priority order) go in this body: files
  /// over [maxFile] (or empty) are [tooBig] and never sent; the rest are
  /// sent while their encoded size fits [budget], otherwise [deferred].
  static ({List<String> send, List<String> deferred, List<String> tooBig})
      plan(
    List<({String path, int size})> candidates, {
    int maxFile = maxFileBytes,
    int budget = maxBodyBytes,
  }) {
    final send = <String>[];
    final deferred = <String>[];
    final tooBig = <String>[];
    final seen = <String>{};
    var used = 0;
    for (final c in candidates) {
      if (!seen.add(c.path)) continue;
      if (c.size <= 0 || c.size > maxFile) {
        tooBig.add(c.path);
        continue;
      }
      final cost = encodedLength(c.size);
      if (used + cost > budget) {
        deferred.add(c.path);
        continue;
      }
      used += cost;
      send.add(c.path);
    }
    return (send: send, deferred: deferred, tooBig: tooBig);
  }
}

class HomeSyncMerge {
  HomeSyncMerge._();

  /// Last-write-wins merge. Tombstones win when they are newer than the
  /// surviving record's [updatedAt].
  static HomeSyncSnapshot merge(
    HomeSyncSnapshot local,
    HomeSyncSnapshot remote,
  ) {
    final deletedConvos = mergeTombstones(
      local.deletedConversations,
      remote.deletedConversations,
    );
    final deletedFolders = mergeTombstones(
      local.deletedFolders,
      remote.deletedFolders,
    );
    final deletedConvoAt = {
      for (final t in deletedConvos) t.id: t.deletedAt,
    };
    final deletedFolderAt = {
      for (final t in deletedFolders) t.id: t.deletedAt,
    };

    final convos = <String, HomeSyncConversation>{};
    for (final item in [...local.conversations, ...remote.conversations]) {
      final id = item.conversation.id;
      final deletedAt = deletedConvoAt[id];
      if (deletedAt != null &&
          !item.conversation.updatedAt.isAfter(deletedAt)) {
        continue;
      }
      final existing = convos[id];
      if (existing == null) {
        convos[id] = item;
      } else if (item.conversation.updatedAt
          .isAfter(existing.conversation.updatedAt)) {
        convos[id] = HomeSyncConversation(
          conversation: ChatTitle.preferStableTitle(
            winner: item.conversation,
            loser: existing.conversation,
          ),
          messages: item.messages,
        );
      } else {
        convos[id] = HomeSyncConversation(
          conversation: ChatTitle.preferStableTitle(
            winner: existing.conversation,
            loser: item.conversation,
          ),
          messages: existing.messages,
        );
      }
    }

    final folders = <String, ChatFolder>{};
    for (final item in [...local.folders, ...remote.folders]) {
      final deletedAt = deletedFolderAt[item.id];
      if (deletedAt != null && !item.updatedAt.isAfter(deletedAt)) {
        continue;
      }
      final existing = folders[item.id];
      if (existing == null || item.updatedAt.isAfter(existing.updatedAt)) {
        folders[item.id] = item;
      }
    }

    final collapsed = collapseNamedFolders(
      folders.values.toList(),
      convos.values.toList(),
    );

    final incoming = remote;
    DateTime personaStamp(DateTime? value) =>
        value ?? DateTime.fromMillisecondsSinceEpoch(0);
    final incomingPersonaWins = !personaStamp(local.personasUpdatedAt)
        .isAfter(personaStamp(incoming.personasUpdatedAt));
    final personasEnabled = incomingPersonaWins
        ? incoming.personasEnabled
        : local.personasEnabled;
    final syncIds = {
      if (personasEnabled)
        ...(incomingPersonaWins
            ? incoming.syncPersonaIds
            : local.syncPersonaIds),
    };
    final personasUpdatedAt = incomingPersonaWins
        ? incoming.personasUpdatedAt
        : local.personasUpdatedAt;

    final deletedPersonas =
        mergeTombstones(local.deletedPersonas, incoming.deletedPersonas);
    final personaDeletedAt = {
      for (final t in deletedPersonas) t.id: t.deletedAt,
    };
    bool personaGone(String id, DateTime updatedAt) {
      final at = personaDeletedAt[id];
      return at != null && !updatedAt.isAfter(at);
    }

    final deletedMemories =
        mergeTombstones(local.deletedMemories, incoming.deletedMemories);

    return HomeSyncSnapshot(
      folders: collapsed.folders,
      conversations: collapsed.conversations,
      deletedConversations: deletedConvos,
      deletedFolders: mergeTombstones(
        deletedFolders,
        collapsed.folderTombstones,
      ),
      personaCatalog: [
        for (final info in mergePersonaCatalog(
          local.personaCatalog,
          incoming.personaCatalog,
        ))
          if (!personaGone(info.id, info.updatedAt)) info,
      ],
      personas: [
        for (final p in mergePersonas(
          local.personas,
          incoming.personas,
          syncIds: syncIds,
        ))
          if (!personaGone(p.prompt.id, p.prompt.updatedAt))
            withoutDeletedMemories(p, deletedMemories),
      ],
      syncPersonaIds: [
        for (final id in syncIds)
          if (!personaDeletedAt.containsKey(id)) id,
      ],
      personasEnabled: personasEnabled,
      personasUpdatedAt: personasUpdatedAt,
      deletedPersonas: deletedPersonas,
      deletedMemories: deletedMemories,
      // Only the other device's bytes are worth writing here.
      files: incoming.files,
      fileSync: incoming.fileSync,
    );
  }

  /// Stable identity of a memory across devices. Memory ids are local
  /// SQLite row ids (the same number means different facts on the phone and
  /// the Mac), so a memory is identified by scope + persona + content.
  static String memoryKey(Map<String, dynamic> m) {
    final scope = (m['scope']?.toString().trim().isNotEmpty ?? false)
        ? m['scope'].toString().trim()
        : 'global';
    final persona = scope == 'global'
        ? ''
        : (m['personaId'] ?? m['persona_id'])?.toString().trim() ?? '';
    final content = (m['content']?.toString() ?? '').trim().toLowerCase();
    return '$scope|$persona|$content';
  }

  static DateTime memoryStamp(Map<String, dynamic> m) =>
      DateTime.tryParse(m['updatedAt']?.toString() ?? '') ??
      DateTime.tryParse(m['createdAt']?.toString() ?? '') ??
      DateTime.fromMillisecondsSinceEpoch(0);

  /// True when [m] was deleted at or after its last update.
  static bool memoryDeleted(
    Map<String, dynamic> m,
    Map<String, DateTime> deletedAt,
  ) {
    final at = deletedAt[memoryKey(m)];
    return at != null && !memoryStamp(m).isAfter(at);
  }

  static HomeSyncPersona withoutDeletedMemories(
    HomeSyncPersona p,
    List<HomeSyncTombstone> tombstones,
  ) {
    if (tombstones.isEmpty || p.memories.isEmpty) return p;
    final at = {for (final t in tombstones) t.id: t.deletedAt};
    final kept = [
      for (final m in p.memories)
        if (!memoryDeleted(m, at)) m,
    ];
    if (kept.length == p.memories.length) return p;
    return HomeSyncPersona(
      prompt: p.prompt,
      avatarBase64: p.avatarBase64,
      avatarExt: p.avatarExt,
      memories: kept,
    );
  }

  static List<HomeSyncPersonaInfo> mergePersonaCatalog(
    List<HomeSyncPersonaInfo> local,
    List<HomeSyncPersonaInfo> remote,
  ) {
    final byId = <String, HomeSyncPersonaInfo>{};
    for (final item in [...local, ...remote]) {
      if (item.id.isEmpty) continue;
      final existing = byId[item.id];
      if (existing == null || item.updatedAt.isAfter(existing.updatedAt)) {
        byId[item.id] = HomeSyncPersonaInfo(
          id: item.id,
          name: item.name,
          updatedAt: item.updatedAt,
          memoryCount: item.memoryCount >= (existing?.memoryCount ?? 0)
              ? item.memoryCount
              : existing!.memoryCount,
          hasAvatar: item.hasAvatar || (existing?.hasAvatar ?? false),
          color: item.color ?? existing?.color,
        );
      } else {
        byId[item.id] = HomeSyncPersonaInfo(
          id: existing.id,
          name: existing.name,
          updatedAt: existing.updatedAt,
          memoryCount: existing.memoryCount >= item.memoryCount
              ? existing.memoryCount
              : item.memoryCount,
          hasAvatar: existing.hasAvatar || item.hasAvatar,
          color: existing.color ?? item.color,
        );
      }
    }
    final list = byId.values.toList()
      ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    return list;
  }

  static List<HomeSyncPersona> mergePersonas(
    List<HomeSyncPersona> local,
    List<HomeSyncPersona> remote, {
    required Set<String> syncIds,
  }) {
    if (syncIds.isEmpty) return const [];
    final byId = <String, HomeSyncPersona>{};
    for (final item in [...local, ...remote]) {
      final id = item.prompt.id;
      if (!syncIds.contains(id)) continue;
      final existing = byId[id];
      byId[id] = existing == null ? item : pickPersona(existing, item);
    }
    return byId.values.toList();
  }

  static HomeSyncPersona pickPersona(HomeSyncPersona a, HomeSyncPersona b) {
    final aWins = !b.prompt.updatedAt.isAfter(a.prompt.updatedAt);
    final winner = aWins ? a : b;
    final loser = aWins ? b : a;
    final winnerHasBytes = winner.avatarBase64?.isNotEmpty ?? false;
    final winnerHasPath = winner.prompt.avatarPath?.isNotEmpty ?? false;
    return HomeSyncPersona(
      prompt: winner.prompt,
      avatarBase64: winnerHasBytes
          ? winner.avatarBase64
          : winnerHasPath
              ? null
              : loser.avatarBase64,
      avatarExt: winnerHasBytes
          ? winner.avatarExt
          : winnerHasPath
              ? winner.avatarExt
              : (loser.avatarExt ?? winner.avatarExt),
      memories: mergePersonaMemories(a.memories, b.memories),
    );
  }

  static List<Map<String, dynamic>> mergePersonaMemories(
    List<Map<String, dynamic>> a,
    List<Map<String, dynamic>> b,
  ) {
    // Keyed on content, never on `id` (device-local row ids collide).
    final byKey = <String, Map<String, dynamic>>{};
    for (final item in [...a, ...b]) {
      final k = memoryKey(item);
      final existing = byKey[k];
      if (existing == null ||
          memoryStamp(item).isAfter(memoryStamp(existing))) {
        byKey[k] = item;
      }
    }
    return byKey.values.toList();
  }

  /// Folders with the same name (trimmed, case-insensitive) become one folder.
  /// Conversations pointing at dropped ids are remapped onto the survivor.
  static ({
    List<ChatFolder> folders,
    List<HomeSyncConversation> conversations,
    List<HomeSyncTombstone> folderTombstones,
    Map<String, String> remap,
  }) collapseNamedFolders(
    List<ChatFolder> folders,
    List<HomeSyncConversation> conversations, {
    DateTime? tombstoneAt,
  }) {
    DateTime? stamp;
    DateTime at() => stamp ??= tombstoneAt ?? DateTime.now();
    final groups = <String, List<ChatFolder>>{};
    final ungrouped = <ChatFolder>[];
    for (final folder in folders) {
      final key = folder.name.trim().toLowerCase();
      if (key.isEmpty) {
        ungrouped.add(folder);
        continue;
      }
      groups.putIfAbsent(key, () => []).add(folder);
    }

    final kept = <String, ChatFolder>{
      for (final folder in ungrouped) folder.id: folder,
    };
    final remap = <String, String>{};
    final tombstones = <HomeSyncTombstone>[];

    int memberCount(ChatFolder folder) {
      final ids = {...folder.conversationIds};
      for (final item in conversations) {
        if (item.conversation.folderId == folder.id) {
          ids.add(item.conversation.id);
        }
      }
      return ids.length;
    }

    for (final group in groups.values) {
      if (group.length == 1) {
        kept[group.first.id] = group.first;
        continue;
      }
      group.sort((a, b) {
        final byMembers = memberCount(b).compareTo(memberCount(a));
        if (byMembers != 0) return byMembers;
        final byUpdated = b.updatedAt.compareTo(a.updatedAt);
        if (byUpdated != 0) return byUpdated;
        return a.sortOrder.compareTo(b.sortOrder);
      });
      final winner = group.first;
      final ids = <String>{...winner.conversationIds};
      var latest = winner.updatedAt;
      for (final loser in group.skip(1)) {
        ids.addAll(loser.conversationIds);
        if (loser.updatedAt.isAfter(latest)) latest = loser.updatedAt;
        remap[loser.id] = winner.id;
        tombstones.add(HomeSyncTombstone(id: loser.id, deletedAt: at()));
      }
      kept[winner.id] = winner.copyWith(
        conversationIds: ids.toList(),
        updatedAt: latest,
      );
    }

    final remapped = <HomeSyncConversation>[];
    for (final item in conversations) {
      final oldId = item.conversation.folderId;
      final newId = oldId == null ? null : (remap[oldId] ?? oldId);
      if (newId == oldId) {
        remapped.add(item);
        continue;
      }
      remapped.add(
        HomeSyncConversation(
          conversation: item.conversation.copyWith(
            folderId: newId,
            updatedAt: at(),
          ),
          messages: item.messages,
        ),
      );
      if (newId != null) {
        final folder = kept[newId];
        if (folder != null &&
            !folder.conversationIds.contains(item.conversation.id)) {
          kept[newId] = folder.copyWith(
            conversationIds: [...folder.conversationIds, item.conversation.id],
            updatedAt: at(),
          );
        }
      }
    }

    final byConvoId = {
      for (final item in remapped) item.conversation.id: item,
    };
    // A chat's own folderId is the truth: moving a chat only changes that,
    // so folder member lists are rebuilt from it instead of pulling chats
    // back into a stale folder (and stamping them "now", which made moved
    // chats snap back and jump to the top). Chats not in this snapshot keep
    // their listed membership.
    for (final folder in kept.values.toList()) {
      final ids = <String>{
        for (final id in folder.conversationIds)
          if (!byConvoId.containsKey(id)) id,
        for (final item in byConvoId.values)
          if (item.conversation.folderId == folder.id) item.conversation.id,
      };
      kept[folder.id] = folder.copyWith(conversationIds: ids.toList());
    }

    return (
      folders: kept.values.toList(),
      conversations: byConvoId.values.toList(),
      folderTombstones: tombstones,
      remap: remap,
    );
  }

  static List<HomeSyncTombstone> mergeTombstones(
    List<HomeSyncTombstone> a,
    List<HomeSyncTombstone> b,
  ) {
    final map = <String, HomeSyncTombstone>{};
    for (final t in [...a, ...b]) {
      final existing = map[t.id];
      if (existing == null || t.deletedAt.isAfter(existing.deletedAt)) {
        map[t.id] = t;
      }
    }
    return map.values.toList();
  }
}

/// Counts used by the first-connect opt-in dialog.
class HomeSyncPreview {
  const HomeSyncPreview({
    required this.localChats,
    required this.localFolders,
    this.remoteChats,
    this.remoteFolders,
    this.remoteReachable = false,
  });

  final int localChats;
  final int localFolders;
  final int? remoteChats;
  final int? remoteFolders;
  final bool remoteReachable;

  bool get phoneHasData => localChats > 0 || localFolders > 0;
  bool get macHasData =>
      (remoteChats ?? 0) > 0 || (remoteFolders ?? 0) > 0;

  HomeSyncPromptKind get kind {
    if (!remoteReachable) return HomeSyncPromptKind.generic;
    if (phoneHasData && macHasData) return HomeSyncPromptKind.both;
    if (phoneHasData) return HomeSyncPromptKind.phoneOnly;
    if (macHasData) return HomeSyncPromptKind.macOnly;
    return HomeSyncPromptKind.generic;
  }
}

enum HomeSyncPromptKind { both, phoneOnly, macOnly, generic }

