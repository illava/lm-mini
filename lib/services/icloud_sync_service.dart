import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:cloud_kit/cloud_kit.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/chat_conversation.dart';
import '../models/chat_message.dart';
import 'database_service.dart';

class ICloudSyncService {
  static final ICloudSyncService _instance = ICloudSyncService._internal();
  factory ICloudSyncService() => _instance;
  ICloudSyncService._internal();

  final CloudKit _cloudKit = CloudKit('iCloud.net.neuro9.lmmini');
  final DatabaseService _db = DatabaseService();

  // Separate locks so an in-progress syncUp does not silently cancel a
  // syncDown (and vice-versa). Previously a single `_isSyncing` flag meant
  // the periodic 60s syncDown was usually skipped whenever the 3-second
  // post-edit syncUp was still finishing — so new conversations created on
  // another device never appeared until the user quit and relaunched.
  bool _isSyncingUp = false;
  bool _isSyncingDown = false;
  Timer? _syncUpTimer;

  static const _deletedIdsKey = 'icloud_deleted_conversation_ids';

  /// Chats deleted on this device. syncDown never re-inserts them, so a
  /// deleted chat (or a discarded empty New Chat) can't come back from
  /// iCloud every minute.
  Future<Set<String>> _deletedIds() async {
    final prefs = await SharedPreferences.getInstance();
    return (prefs.getStringList(_deletedIdsKey) ?? const []).toSet();
  }

  /// Call when a chat is deleted locally: remembers it and removes it from
  /// iCloud (best effort; the tombstone covers a failed delete).
  Future<void> forgetConversation(String id) async {
    final prefs = await SharedPreferences.getInstance();
    final ids = (prefs.getStringList(_deletedIdsKey) ?? <String>[]).toList();
    if (!ids.contains(id)) {
      ids.add(id);
      // Keep the list bounded; old ids are long gone from iCloud.
      if (ids.length > 2000) ids.removeRange(0, ids.length - 2000);
      await prefs.setStringList(_deletedIdsKey, ids);
    }
    final uploaded = await _loadMap(_uploadedKey);
    final downloaded = await _loadMap(_downloadedKey);
    if (uploaded.remove(id) != null) await _saveMap(_uploadedKey, uploaded);
    if (downloaded.remove(id) != null) {
      await _saveMap(_downloadedKey, downloaded);
    }
    if (!await isEnabled) return;
    for (final key in ['convo_$id', 'msgs_$id']) {
      try {
        await _cloudKit.delete(key);
      } catch (_) {
        // Missing key or offline — the tombstone still blocks it.
      }
    }
  }

  static const _uploadedKey = 'icloud_uploaded_signatures';
  static const _downloadedKey = 'icloud_downloaded_msg_hashes';

  Future<Map<String, String>> _loadMap(String key) async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(key);
    if (raw == null || raw.isEmpty) return {};
    try {
      return Map<String, String>.from(jsonDecode(raw) as Map);
    } catch (_) {
      return {};
    }
  }

  Future<void> _saveMap(String key, Map<String, String> map) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(key, jsonEncode(map));
  }

  /// What a chat looks like for upload purposes: its own fields plus a
  /// fingerprint of its messages. Unchanged signature → nothing to upload.
  @visibleForTesting
  static String signature(ChatConversation c, String? messageFingerprint) =>
      '${c.updatedAt.millisecondsSinceEpoch}|${c.title}|${c.folderId}|'
      '${jsonEncode(c.settings)}#${messageFingerprint ?? '0'}';

  /// Message count from a [DatabaseService.messageFingerprints] value.
  static int _countFrom(String? fp) =>
      fp == null ? 0 : int.tryParse(fp.split('|').first) ?? 0;

  /// FNV-1a over the payload: cheap "did this record change" check so an
  /// unchanged remote chat isn't decoded and re-checked every sync.
  @visibleForTesting
  static String payloadHash(String s) {
    var h = 0x811c9dc5;
    for (final unit in s.codeUnits) {
      h ^= unit;
      h = (h * 0x01000193) & 0xFFFFFFFF;
    }
    return '${s.length}:$h';
  }

  Future<void> _markUploaded(Set<String> ids) async {
    final convos = await _db.getAllConversations();
    final fps = await _db.messageFingerprints();
    final uploaded = await _loadMap(_uploadedKey);
    for (final c in convos) {
      if (ids.contains(c.id)) uploaded[c.id] = signature(c, fps[c.id]);
    }
    await _saveMap(_uploadedKey, uploaded);
  }

  /// An untouched New Chat: never worth syncing.
  @visibleForTesting
  static bool isEmptyDraft(ChatConversation c, int messageCount) =>
      c.settings['isDraft'] == true && messageCount == 0;

  void scheduleSyncUp() {
    _syncUpTimer?.cancel();
    _syncUpTimer = Timer(const Duration(seconds: 3), () {
      syncUp();
    });
  }

  /// Drop a debounce armed before send so a 3s timer cannot fire mid-stream.
  void cancelPendingSyncUp() {
    _syncUpTimer?.cancel();
    _syncUpTimer = null;
  }

  Future<bool> get isEnabled async {
    if (!Platform.isIOS) return false;
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool('icloud_sync_enabled') ?? false;
  }

  Future<void> setEnabled(bool enabled) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('icloud_sync_enabled', enabled);
    if (enabled) {
      await syncUp();
      await syncDown();
    }
  }

  /// Safely saves to CloudKit by deleting the existing key first if it exists.
  Future<void> _safeSave(String key, String value) async {
    try {
      await _cloudKit.save(key, value);
    } catch (e) {
      if (e.toString().contains('already exists')) {
        await _cloudKit.delete(key);
        await _cloudKit.save(key, value);
      } else {
        rethrow;
      }
    }
  }

  /// Pushes local database state up to iCloud CloudKit.
  Future<void> syncUp() async {
    if (!await isEnabled) return;
    if (_isSyncingUp) return;
    _isSyncingUp = true;
    debugPrint('☁️ iCloud Sync: Starting syncUp() to CloudKit...');

    try {
      final status = await _cloudKit.getAccountStatus();
      if (status != CloudKitAccountStatus.available) {
        debugPrint('☁️ iCloud Sync: Account not available, aborting syncUp.');
        return;
      }

      final allConvos = await _db.getAllConversations();
      // One grouped query instead of loading every chat's messages.
      final fingerprints = await _db.messageFingerprints();
      final uploaded = await _loadMap(_uploadedKey);
      int convosSynced = 0;
      int messagesSynced = 0;

      for (var convo in allConvos) {
        final fp = fingerprints[convo.id];
        if (isEmptyDraft(convo, _countFrom(fp))) continue;
        final sig = signature(convo, fp);
        final previous = uploaded[convo.id];
        if (previous == sig) continue; // unchanged since last upload

        await _safeSave('convo_${convo.id}', jsonEncode(convo.toJson()));
        convosSynced++;

        final messagesChanged =
            previous == null || previous.split('#').last != (fp ?? '0');
        if (messagesChanged && _countFrom(fp) > 0) {
          final messages = await _db.getMessagesForConversation(convo.id);
          final messagesJson =
              jsonEncode(messages.map((m) => m.toJson()).toList());
          await _safeSave('msgs_${convo.id}', messagesJson);
          messagesSynced += messages.length;
        }
        uploaded[convo.id] = sig;
      }
      if (convosSynced > 0) await _saveMap(_uploadedKey, uploaded);
      debugPrint(
          '☁️ iCloud Sync: Successfully synced up (pushed $convosSynced conversations, $messagesSynced messages).');
    } catch (e) {
      debugPrint('☁️ iCloud Sync: syncUp error - $e');
    } finally {
      _isSyncingUp = false;
    }
  }

  /// Pulls remote CloudKit state down into local SQLite.
  /// (Performs UPSERT logic to merge remote data)
  Future<bool> syncDown() async {
    if (!await isEnabled) return false;
    if (_isSyncingDown) return false;
    _isSyncingDown = true;
    bool hasChanges = false;
    debugPrint('☁️ iCloud Sync: Starting syncDown() from CloudKit...');

    try {
      final status = await _cloudKit.getAccountStatus();
      if (status != CloudKitAccountStatus.available) {
        debugPrint(
            '☁️ iCloud Sync: Account not available ($status), aborting syncDown.');
        return false;
      }

      final allRecords = await _cloudKit.getAll();
      if (allRecords == null || allRecords.isEmpty) {
        debugPrint('☁️ iCloud Sync: No records found on iCloud container.');
        return false;
      }

      final existingConvos = await _db.getAllConversations();
      final localConvoIds = existingConvos.map((c) => c.id).toSet();
      final deletedIds = await _deletedIds();
      final downloaded = await _loadMap(_downloadedKey);
      // Chats changed here by this sync: their new local state already
      // matches iCloud, so don't upload them straight back.
      final touched = <String>{};
      // Remote chats that have messages; an empty remote draft is skipped.
      final remoteWithMessages = <String>{
        for (final k in allRecords.keys)
          if (k.startsWith('msgs_')) k.substring(5),
      };

      int convosAdded = 0;
      int convosUpdated = 0;
      int messagesAdded = 0;
      int messagesUpdated = 0;

      for (var entry in allRecords.entries) {
        final key = entry.key;
        final value = entry.value;

        if (key.startsWith('convo_')) {
          try {
            final map = jsonDecode(value);
            final convo = ChatConversation.fromJson(map);
            if (deletedIds.contains(convo.id)) continue;
            if (!localConvoIds.contains(convo.id)) {
              if (isEmptyDraft(convo,
                  remoteWithMessages.contains(convo.id) ? 1 : 0)) {
                continue;
              }
              await _db.insertConversation(convo);
              touched.add(convo.id);
              hasChanges = true;
              convosAdded++;
            } else {
              // Update if remote is newer
              final local = existingConvos.firstWhere((c) => c.id == convo.id);
              if (convo.updatedAt.isAfter(local.updatedAt)) {
                await _db.updateConversation(convo);
                touched.add(convo.id);
                hasChanges = true;
                convosUpdated++;
              }
            }
          } catch (e) {
            debugPrint(
                '☁️ iCloud Sync: Failed to parse remote convo ($key): $e');
          }
        }
      }

      // Now sync messages for these conversations
      for (var entry in allRecords.entries) {
        if (entry.key.startsWith('msgs_')) {
          try {
            final convoId = entry.key.replaceFirst('msgs_', '');
            if (deletedIds.contains(convoId)) continue;
            final hash = payloadHash(entry.value);
            if (downloaded[convoId] == hash) continue; // unchanged remotely
            final List<dynamic> list = jsonDecode(entry.value);

            final localMessages = await _db.getMessagesForConversation(convoId);
            final localMessageIds = localMessages.map((m) => m.id).toSet();

            for (var item in list) {
              final msg = ChatMessage.fromJson(item as Map<String, dynamic>);
              if (!localMessageIds.contains(msg.id)) {
                await _db.insertMessage(msg, convoId);
                touched.add(convoId);
                hasChanges = true;
                messagesAdded++;
              } else {
                // If message supports updating (like edits or status), we update it.
                final local = localMessages.firstWhere((m) => m.id == msg.id);
                final localImgPaths =
                    local.generatedImagePaths?.join(',') ?? '';
                final msgImgPaths = msg.generatedImagePaths?.join(',') ?? '';

                // Prefer local image paths if cloud is missing them
                // e.g. image generated locally after cloud sync up
                var mergedMsg = msg;
                if (msgImgPaths.isEmpty && localImgPaths.isNotEmpty) {
                  mergedMsg = msg.copyWith(
                    generatedImagePaths: local.generatedImagePaths,
                    generatedImagePath: local.generatedImagePath,
                  );
                }

                final mergedImgPaths =
                    mergedMsg.generatedImagePaths?.join(',') ?? '';
                if (local.content != mergedMsg.content ||
                    localImgPaths != mergedImgPaths) {
                  // Only update if there's actually new valid content or changes from cloud
                  // Wait, if it only differs by image, and mergedMsg adopted local image, it wouldn't update.
                  await _db.updateMessage(mergedMsg,
                      touchConversation: false);
                  touched.add(convoId);
                  hasChanges = true;
                  messagesUpdated++;
                }
              }
            }
            // Only after a clean merge, so a failed one is retried.
            downloaded[convoId] = hash;
          } catch (e) {
            debugPrint(
                '☁️ iCloud Sync: Failed to parse remote msgs (${entry.key}): $e');
          }
        }
      }

      await _saveMap(_downloadedKey, downloaded);
      if (touched.isNotEmpty) await _markUploaded(touched);

      if (hasChanges) {
        debugPrint(
            '☁️ iCloud Sync: Completed successfully. Added $convosAdded convos, updated $convosUpdated. Added $messagesAdded msgs, updated $messagesUpdated.');
      } else {
        debugPrint(
            '☁️ iCloud Sync: Completed successfully. No new changes detected.');
      }
      return hasChanges;
    } catch (e) {
      debugPrint('☁️ iCloud Sync: syncDown error: $e');
      return false;
    } finally {
      _isSyncingDown = false;
    }
  }
}
