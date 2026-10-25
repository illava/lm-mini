import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:lm_mini_premium/lm_mini_premium.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/app_settings.dart';
import '../models/system_prompt.dart';
import 'builtin_persona_service.dart';
import '../utils/image_picker_helper.dart';
import '../utils/remote_host_backends.dart';
import 'database_service.dart';
import 'home_sync_snapshot.dart';
import 'icloud_sync_service.dart';
import 'remote_connection_info.dart';

part '../pro/remote_access/home_sync_client.dart';

/// Syncs chats and folders between the phone and LM Mini Home over the
/// relay (HTTPS; same pairing as Share with phone).
///
/// Each round the phone sends only chats that changed since the last good
/// sync plus a manifest of what it has (`known`); a current Mac answers with
/// only the chats that differ. Older Macs ignore `known` and answer with
/// everything, which the phone applies the same way.
class HomeSyncService {
  HomeSyncService._();
  static final HomeSyncService instance = HomeSyncService._();

  static const syncPath = '/lm-mini/sync';
  static const _tombstoneConvosKey = 'home_sync_deleted_convos';
  static const _tombstoneFoldersKey = 'home_sync_deleted_folders';
  static const _tombstonePersonasKey = 'home_sync_deleted_personas';
  static const _tombstoneMemoriesKey = 'home_sync_deleted_memories';

  /// Phone: paths the Mac asked for (sent next round).
  static const _owedFilesKey = 'home_sync_owed_files';

  /// Phone: paths this device is missing and asks the Mac for.
  static const _wantFilesKey = 'home_sync_want_files';

  /// Phone: files the Mac already has (`path → size`), so a chat resent for
  /// a text change doesn't upload its pictures again.
  static const _sentFilesKey = 'home_sync_sent_files';

  /// Phone: the Mac answered with `fileSync` (it keeps files we push).
  static const _hostFilesKey = 'home_sync_host_files';

  /// Manifest entries last confirmed in sync with the Mac (`id → entry`).
  static const _sentKey = 'home_sync_sent_manifest';

  /// Poll while the app is open; doubles after each failure (Mac asleep,
  /// offline) up to [_maxPollInterval], back to normal after a success.
  static const _pollInterval = Duration(seconds: 60);
  static const _maxPollInterval = Duration(minutes: 10);
  int _failures = 0;

  /// Mac host: one merge at a time (two phones, or a phone during a local
  /// delete, must not interleave read-merge-write).
  Future<void> _hostQueue = Future.value();

  final DatabaseService _db = DatabaseService();
  Timer? _debounce;
  Timer? _poll;
  bool _busy = false;
  AppSettings Function()? _settings;
  Future<void> Function()? _onApplied;
  Future<bool> Function(Set<String> ids)? _removePersonas;
  bool Function()? _shouldDefer;
  Future<bool> Function({
    required List<SystemPrompt> prompts,
    required List<String> syncIds,
    required bool enabled,
    DateTime? updatedAt,
  })? _applyPersonas;
  final ValueNotifier<String?> lastError = ValueNotifier<String?>(null);

  static const _maxAvatarBytes = 700000;

  void attach({
    required AppSettings Function() settings,
    Future<void> Function()? onApplied,
    bool Function()? shouldDefer,
    Future<bool> Function({
      required List<SystemPrompt> prompts,
      required List<String> syncIds,
      required bool enabled,
      DateTime? updatedAt,
    })? applyPersonas,
    Future<bool> Function(Set<String> ids)? removePersonas,
  }) {
    _settings = settings;
    _removePersonas = removePersonas;
    _onApplied = onApplied;
    _shouldDefer = shouldDefer;
    _applyPersonas = applyPersonas;
  }

  void schedule() {
    // Don't queue another round-trip while a sync (and its UI reload) is
    // in flight — ChatProvider.notifyListeners would otherwise loop every ~3s.
    if (_busy || _shouldDefer?.call() == true) return;
    _debounce?.cancel();
    _debounce = Timer(const Duration(seconds: 3), () {
      unawaited(syncNow());
    });
  }

  /// Drop a debounce armed before send so a 3s timer cannot fire mid-stream.
  void cancelPendingSchedule() {
    _debounce?.cancel();
    _debounce = null;
  }

  void startPolling() {
    _poll?.cancel();
    _failures = 0;
    _scheduleNextPoll(const Duration(seconds: 2));
  }

  void _scheduleNextPoll(Duration delay) {
    _poll?.cancel();
    _poll = Timer(delay, () async {
      await syncNow();
      if (_poll == null) return; // stopped meanwhile
      _scheduleNextPoll(nextPollDelay(_failures));
    });
  }

  /// [_pollInterval], doubled per consecutive failure, capped.
  @visibleForTesting
  static Duration nextPollDelay(int failures) {
    if (failures <= 0) return _pollInterval;
    final factor = 1 << (failures.clamp(0, 6));
    final next = _pollInterval * factor;
    return next > _maxPollInterval ? _maxPollInterval : next;
  }

  void stopPolling() {
    _poll?.cancel();
    _poll = null;
  }

  /// True until the user answers the first-connect merge prompt.
  static bool shouldPrompt(AppSettings settings) {
    if (!RemoteHostBackends.isPairedHome(settings)) return false;
    if (settings.homeSyncEnabled) return false;
    if (settings.homeSyncPrompted) return false;
    return true;
  }

  /// Peek at Mac chats without merging — used by the opt-in dialog.
  Future<HomeSyncPreview> preview() => _proPreview();

  Future<HomeSyncSnapshot?> fetchRemoteSnapshot() =>
      _proFetchRemoteSnapshot();

  Future<void> rememberDeletedConversation(String id) async {
    await _addTombstone(_tombstoneConvosKey, id);
    schedule();
  }

  Future<void> rememberDeletedPersona(String id) async {
    await _addTombstone(_tombstonePersonasKey, id);
    schedule();
  }

  Future<void> rememberDeletedFolder(String id) async {
    await _addTombstone(_tombstoneFoldersKey, id);
    schedule();
  }

  /// Mac host: merge a phone snapshot into this Mac's DB and return the result.
  Future<({int status, Map<String, dynamic> body})> handleHostHttp({
    required String method,
    String? body,
  }) {
    final run = _hostQueue.then((_) => _handleHostHttp(method: method, body: body));
    _hostQueue = run.then((_) {}, onError: (_) {});
    return run;
  }

  Future<({int status, Map<String, dynamic> body})> _handleHostHttp({
    required String method,
    String? body,
  }) async {
    try {
      if (method == 'GET' || method == 'HEAD') {
        final local = await _loadLocalSnapshot();
        return (status: 200, body: local.toJson());
      }
      if (method != 'POST' && method != 'PUT') {
        return (status: 405, body: {'error': 'Method not allowed'});
      }
      final incoming = body == null || body.isEmpty
          ? const HomeSyncSnapshot()
          : HomeSyncSnapshot.fromJson(
              Map<String, dynamic>.from(await _decodeJson(body) as Map),
            );
      final local = await _loadLocalSnapshot(
        extraPackIds:
            incoming.personasEnabled ? incoming.syncPersonaIds.toSet() : null,
      );
      final merged = HomeSyncMerge.merge(local, incoming);
      // Files first, so the chats show their pictures once applied.
      final received = await _writeFiles(incoming.files);
      final changed = await _proApplySnapshot(merged);
      if (changed) {
        await _onApplied?.call();
      }
      final known = incoming.known;
      if (known == null) {
        // Older phone: no delta, no files.
        return (status: 200, body: merged.withFiles(fileSync: false).toJson());
      }
      // Answer with only the chats the phone doesn't already have as-is.
      final now = await _manifest();
      var reply = merged.withConversations([
        for (final item in merged.conversations)
          if (known[item.conversation.id] != now[item.conversation.id])
            item,
      ]);
      if (incoming.fileSync) {
        reply = await _hostFiles(reply, incoming, known, received);
      }
      return (status: 200, body: reply.toJson());
    } catch (e, st) {
      debugPrint('HomeSync host error: $e\n$st');
      return (status: 500, body: {'error': e.toString()});
    }
  }

  Future<bool> syncNow() => _proSyncNow();

  /// Mac host: file fields of the reply to a phone that understands them.
  /// Serves what the phone asked for first, then pictures of chats new to
  /// the phone, within one body's budget; asks for files of the phone's
  /// chats that are still missing here.
  Future<HomeSyncSnapshot> _hostFiles(
    HomeSyncSnapshot reply,
    HomeSyncSnapshot incoming,
    Map<String, String> known,
    Set<String> received,
  ) async {
    final docs = await _docsDir();
    final wanted = incoming.wantFiles
        .take(HomeSyncFiles.maxListed)
        .map(HomeSyncFiles.sanitize)
        .whereType<String>()
        .toList();
    final push = <String>{
      for (final item in reply.conversations)
        if (!known.containsKey(item.conversation.id))
          ...HomeSyncFiles.referencedPaths(item.messages, docsDir: docs),
    }..removeAll(received);
    final packed = await _packFiles([...wanted, ...push]);
    final wantedSet = wanted.toSet();
    final missingHere = await _missingFiles(
      HomeSyncFiles.referencedPaths(
        incoming.conversations.expand((c) => c.messages),
        docsDir: docs,
      ),
    );
    return reply.withFiles(
      files: packed.files,
      wantFiles: missingHere.take(HomeSyncFiles.maxListed).toList(),
      unavailableFiles: [
        for (final path in packed.unavailable)
          if (wantedSet.contains(path)) path,
      ],
    );
  }

  static String? _docsPath;
  Future<String> _docsDir() async =>
      _docsPath ??= (await getApplicationDocumentsDirectory()).path;

  /// Local files for [paths] (priority order) within one body's budget.
  /// [unavailable]: not here, unreadable or over the size cap.
  Future<
      ({
        List<HomeSyncFile> files,
        List<String> deferred,
        List<String> unavailable,
        Map<String, int> sizes,
      })> _packFiles(List<String> paths) async {
    final docs = await _docsDir();
    final candidates = <({String path, int size})>[];
    final unavailable = <String>[];
    for (final path in paths) {
      final safe = HomeSyncFiles.sanitize(path);
      if (safe == null) continue;
      try {
        final file = File(p.join(docs, safe));
        if (await file.exists()) {
          candidates.add((path: safe, size: await file.length()));
          continue;
        }
      } catch (_) {}
      unavailable.add(safe);
    }
    final plan = HomeSyncFiles.plan(candidates);
    final sizes = {for (final c in candidates) c.path: c.size};
    final files = <HomeSyncFile>[];
    for (final path in plan.send) {
      try {
        final bytes = await File(p.join(docs, path)).readAsBytes();
        files.add(HomeSyncFile(path: path, data: base64Encode(bytes)));
      } catch (e) {
        debugPrint('HomeSync file skip $path: $e');
        unavailable.add(path);
      }
    }
    return (
      files: files,
      deferred: plan.deferred,
      unavailable: [...unavailable, ...plan.tooBig],
      sizes: sizes,
    );
  }

  /// Writes incoming files that are missing here, at the same relative path
  /// under the documents dir. Never overwrites an existing file. Returns the
  /// paths now present (written or already there).
  Future<Set<String>> _writeFiles(List<HomeSyncFile> files) async {
    if (files.isEmpty) return const {};
    final docs = await _docsDir();
    final present = <String>{};
    for (final f in files) {
      final safe = HomeSyncFiles.sanitize(f.path);
      if (safe == null) continue;
      final target = p.normalize(p.join(docs, safe));
      if (!p.isWithin(docs, target)) continue;
      try {
        final file = File(target);
        if (await file.exists()) {
          present.add(safe);
          continue;
        }
        if (HomeSyncFiles.encodedLength(HomeSyncFiles.maxFileBytes) <
            f.data.length) {
          continue;
        }
        final bytes = base64Decode(f.data);
        if (bytes.isEmpty) continue;
        await file.parent.create(recursive: true);
        final tmp = File('$target.sync-tmp');
        await tmp.writeAsBytes(bytes, flush: true);
        if (await file.exists()) {
          await tmp.delete(); // appeared meanwhile: keep the local one
        } else {
          await tmp.rename(target);
        }
        present.add(safe);
      } catch (e) {
        debugPrint('HomeSync write file $safe failed: $e');
      }
    }
    return present;
  }

  /// Which of [paths] don't exist here.
  Future<List<String>> _missingFiles(Iterable<String> paths) async {
    final docs = await _docsDir();
    final out = <String>[];
    for (final path in paths) {
      try {
        if (!await File(p.join(docs, path)).exists()) out.add(path);
      } catch (_) {}
    }
    return out;
  }

  Future<List<String>> _readPaths(String key) async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getStringList(key) ?? const [];
  }

  Future<void> _writePaths(String key, Iterable<String> paths) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(
      key,
      paths.take(HomeSyncFiles.maxListed).toList(),
    );
  }

  Future<Map<String, int>> _readSentFiles() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_sentFilesKey);
    if (raw == null || raw.isEmpty) return {};
    try {
      return {
        for (final e in (jsonDecode(raw) as Map).entries)
          e.key.toString(): (e.value as num).toInt(),
      };
    } catch (_) {
      return {};
    }
  }

  Future<void> _writeSentFiles(Map<String, int> sent) async {
    var entries = sent.entries.toList();
    if (entries.length > 5000) {
      entries = entries.sublist(entries.length - 5000);
    }
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _sentFilesKey,
      jsonEncode({for (final e in entries) e.key: e.value}),
    );
  }

  /// This device's manifest: `id → HomeSyncManifest.entry` for every chat
  /// except untouched drafts (one grouped query, no message loading).
  Future<Map<String, String>> _manifest() async {
    final convos = await _db.getAllConversations();
    final fps = await _db.messageFingerprints();
    return {
      for (final c in convos)
        if (!HomeSyncManifest.isEmptyDraft(
            c, HomeSyncManifest.messageCount(fps[c.id])))
          c.id: HomeSyncManifest.entry(c, fps[c.id]),
    };
  }

  /// Large sync bodies are decoded off the UI isolate.
  static Future<dynamic> _decodeJson(String body) =>
      body.length > 200000 ? compute(jsonDecode, body) : Future.value(jsonDecode(body));

  /// Bodies carrying files are encoded off the UI isolate.
  static Future<String> _encodeJson(HomeSyncSnapshot snapshot) {
    final json = snapshot.toJson();
    return snapshot.files.isEmpty && snapshot.conversations.length < 20
        ? Future.value(jsonEncode(json))
        : compute(jsonEncode, json);
  }

  /// [onlyConversationIds]: pack just these chats (the rest are unchanged);
  /// null packs every chat. Untouched drafts are never packed.
  Future<HomeSyncSnapshot> _loadLocalSnapshot({
    Set<String>? extraPackIds,
    Set<String>? onlyConversationIds,
    Map<String, String>? known,
  }) async {
    final convos = await _db.getAllConversations();
    final fps = await _db.messageFingerprints();
    final packed = <HomeSyncConversation>[];
    for (final convo in convos) {
      if (onlyConversationIds != null &&
          !onlyConversationIds.contains(convo.id)) {
        continue;
      }
      if (HomeSyncManifest.isEmptyDraft(
          convo, HomeSyncManifest.messageCount(fps[convo.id]))) {
        continue;
      }
      packed.add(HomeSyncConversation(
        conversation: convo,
        messages: await _db.getMessagesForConversation(convo.id),
      ));
    }
    final settings = _settings?.call();
    final enabled = settings?.homeSyncPersonasEnabled ?? false;
    final ids = <String>{
      ...?settings?.homeSyncPersonaIds,
      ...?extraPackIds,
    };
    final pack = enabled || (extraPackIds != null && extraPackIds.isNotEmpty);
    final catalog = <HomeSyncPersonaInfo>[];
    final packedPersonas = <HomeSyncPersona>[];
    for (final prompt
        in settings?.savedSystemPrompts ?? const <SystemPrompt>[]) {
      if (BuiltinPersonaService.isDefaultId(prompt.id)) continue;
      final memories = await _memoriesFor(prompt.id);
      catalog.add(HomeSyncPersonaInfo(
        id: prompt.id,
        name: prompt.name,
        updatedAt: prompt.updatedAt,
        memoryCount: memories.length,
        hasAvatar: prompt.avatarPath != null && prompt.avatarPath!.isNotEmpty,
        color: prompt.color,
      ));
      if (pack && ids.contains(prompt.id)) {
        packedPersonas.add(await _packPersona(prompt, memories));
      }
    }

    return HomeSyncSnapshot(
      folders: await _db.getAllFolders(),
      conversations: packed,
      deletedConversations: await _readTombstones(_tombstoneConvosKey),
      deletedFolders: await _readTombstones(_tombstoneFoldersKey),
      deletedPersonas: await _readTombstones(_tombstonePersonasKey),
      deletedMemories: HomeSyncMerge.mergeTombstones(
        await _readTombstones(_tombstoneMemoriesKey),
        await _localMemoryTombstones(),
      ),
      personaCatalog: catalog,
      personas: packedPersonas,
      syncPersonaIds:
          List<String>.from(settings?.homeSyncPersonaIds ?? const []),
      personasEnabled: enabled,
      personasUpdatedAt: settings?.homeSyncPersonasUpdatedAt,
      known: known,
    );
  }

  Future<Map<String, String>> _readSent() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_sentKey);
    if (raw == null || raw.isEmpty) return {};
    try {
      return Map<String, String>.from(jsonDecode(raw) as Map);
    } catch (_) {
      return {};
    }
  }

  Future<void> _writeSent(Map<String, String> sent) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_sentKey, jsonEncode(sent));
  }

  Future<HomeSyncPersona> _packPersona(
    SystemPrompt prompt,
    List<Map<String, dynamic>> memories,
  ) async {
    String? b64;
    String? ext;
    final path = prompt.avatarPath;
    if (path != null &&
        path.isNotEmpty &&
        !_isBundledAvatar(path)) {
      try {
        final abs = await ImagePickerHelper.resolveImagePath(path);
        if (abs != null) {
          final file = File(abs);
          final len = await file.length();
          if (len > 0 && len <= _maxAvatarBytes) {
            b64 = base64Encode(await file.readAsBytes());
            ext = p.extension(abs);
            if (ext.isEmpty) ext = '.jpg';
          }
        }
      } catch (e) {
        debugPrint('HomeSync persona avatar skip: $e');
      }
    }
    return HomeSyncPersona(
      prompt: prompt,
      avatarBase64: b64,
      avatarExt: ext,
      memories: memories,
    );
  }

  bool _isBundledAvatar(String path) {
    return path.startsWith('assets/') ||
        path.contains('persona_pack_') ||
        path.contains('persona_pack');
  }

  /// Wire form of a persona's memories. No `id`: ids are local row numbers
  /// (an older host matching on them would overwrite an unrelated memory).
  /// The previous version read `exportItems()` rows, whose `persona_id`
  /// column never matched `personaId`, so no memory was ever sent.
  Future<List<Map<String, dynamic>>> _memoriesFor(String personaId) async {
    final mem = MemoryService();
    await mem.load();
    return [
      for (final item in mem.items)
        if (item.personaId == personaId)
          {
            'content': item.content,
            'category': item.category,
            'scope': item.scope.name,
            'personaId': item.personaId,
            'createdAt': item.createdAt.toIso8601String(),
            'updatedAt': item.updatedAt.toIso8601String(),
          },
    ];
  }

  /// Memory deletions recorded by [MemoryService], as sync tombstones.
  Future<List<HomeSyncTombstone>> _localMemoryTombstones() async {
    try {
      return [
        for (final m in await MemoryService().deletedItems())
          HomeSyncTombstone(
            id: HomeSyncMerge.memoryKey(m),
            deletedAt: DateTime.tryParse(m['deletedAt']?.toString() ?? '') ??
                DateTime.fromMillisecondsSinceEpoch(0),
          ),
      ];
    } catch (_) {
      return const [];
    }
  }

  Future<void> _addTombstone(String key, String id) async {
    final existing = await _readTombstones(key);
    final next = [
      ...existing.where((t) => t.id != id),
      HomeSyncTombstone(id: id, deletedAt: DateTime.now()),
    ];
    if (next.length > 400) {
      next.sort((a, b) => b.deletedAt.compareTo(a.deletedAt));
      next.removeRange(400, next.length);
    }
    await _writeTombstones(key, next);
  }

  Future<List<HomeSyncTombstone>> _readTombstones(String key) async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(key);
    if (raw == null || raw.isEmpty) return const [];
    try {
      final list = jsonDecode(raw);
      if (list is! List) return const [];
      return [
        for (final item in list)
          if (item is Map)
            HomeSyncTombstone.fromJson(Map<String, dynamic>.from(item)),
      ];
    } catch (_) {
      return const [];
    }
  }

  Future<void> _writeTombstones(
    String key,
    List<HomeSyncTombstone> items,
  ) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      key,
      jsonEncode(items.map((t) => t.toJson()).toList()),
    );
  }
}
