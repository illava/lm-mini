import 'dart:convert';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:lm_mini_premium/lm_mini_premium.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Where secret values actually live (Keychain / Keystore in the app, a map
/// in tests).
abstract class SecretBackend {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
  Future<void> delete(String key);
}

class _SecureStorageBackend implements SecretBackend {
  static const _storage = FlutterSecureStorage(
    // Readable after the first unlock so background work (news widget,
    // backups) still sees the keys while the phone is locked.
    iOptions: IOSOptions(accessibility: KeychainAccessibility.first_unlock),
    // Never wipe on error: a transient Keystore failure must not erase every
    // key. Errors fall back to prefs instead (see [SecretStore]). The file is
    // excluded from Android backup, so a restore never brings in a copy this
    // phone can't decrypt (res/xml/backup_rules.xml).
    aOptions: AndroidOptions(resetOnError: false),
  );

  @override
  Future<String?> read(String key) => _storage.read(key: key);

  @override
  Future<void> write(String key, String value) =>
      _storage.write(key: key, value: value);

  @override
  Future<void> delete(String key) => _storage.delete(key: key);
}

/// In-memory backend for tests.
class MemorySecretBackend implements SecretBackend {
  final Map<String, String> values = {};
  bool failReads = false;
  bool failWrites = false;

  @override
  Future<String?> read(String key) async {
    if (failReads) throw StateError('read failed');
    return values[key];
  }

  @override
  Future<void> write(String key, String value) async {
    if (failWrites) throw StateError('write failed');
    values[key] = value;
  }

  @override
  Future<void> delete(String key) async {
    if (failWrites) throw StateError('delete failed');
    values.remove(key);
  }
}

/// Keeps API keys, tokens and auth headers out of SharedPreferences (which
/// is plain text and part of Android cloud backup) on iOS and Android.
///
/// Each stored blob (app settings, saved servers, cloud providers, backup
/// passphrase) is split on save: secret fields go to the Keychain /
/// Keystore, the rest stays in prefs. Load merges them back.
///
/// A key must never be lost, so:
///  * Operations on one blob run one at a time (concurrent saves used to
///    interleave write / read-back).
///  * prefs is only stripped after the secure write succeeded and read back.
///  * When a secure write fails, that save keeps everything in prefs and
///    marks prefs as the newer, complete copy ("all").
///  * When a secure read fails (e.g. a background launch before the first
///    unlock), the blob is "degraded": what was loaded lacks its secrets, so
///    saves keep plaintext marked "present" — fields it has win, fields it
///    lacks still come from the secure copy. [retryDegraded] recovers.
///  * A revision written to both sides decides which copy is newer.
/// On other platforms (and in tests unless a backend is set) it does nothing
/// and prefs keeps everything, exactly as before.
class SecretStore {
  SecretStore._();
  static final SecretStore instance = SecretStore._();

  /// Every secure blob this store writes (for reinstall cleanup).
  static const blobs = [
    'app_settings',
    'server_profiles_v1',
    'cloud_api_providers',
    'backup_passphrase',
  ];

  SecretBackend? _backend =
      (!kIsWeb && (Platform.isIOS || Platform.isAndroid))
          ? _SecureStorageBackend()
          : null;

  /// Blobs whose secure copy could not be read this session.
  final Set<String> _degraded = {};

  /// Secrets (without revision) known to be in the secure copy, per blob.
  final Map<String, String> _known = {};

  final Map<String, Future<void>> _locks = {};
  Future<void>? _installCheck;

  bool get enabled => _backend != null;

  /// True while some blob was loaded without its secrets.
  bool get hasDegraded => _degraded.isNotEmpty;

  @visibleForTesting
  set debugBackend(SecretBackend? backend) {
    _backend = backend;
    _degraded.clear();
    _known.clear();
    _locks.clear();
    _installCheck = null;
  }

  static String _secureKey(String name) => 'lmmini.secrets.$name';
  static String _revKey(String name) => 'secrets_rev.$name';
  static String _modeKey(String name) => 'secrets_mode.$name';
  static const _installMarker = 'secrets_install_marker';

  /// Runs [op] after every earlier operation on [name] finished.
  Future<T> _serial<T>(String name, Future<T> Function() op) {
    final prev = _locks[name] ?? Future<void>.value();
    final next = prev.catchError((_) {}).then((_) => op());
    _locks[name] = next.then((_) {}, onError: (_) {});
    return next;
  }

  /// The Keychain survives an iOS uninstall; prefs doesn't. On a fresh
  /// install (no marker, no stored blobs) drop leftover secrets so an old
  /// token or pairing key doesn't come back.
  Future<void> _checkInstall(SharedPreferences prefs) =>
      _installCheck ??= _runInstallCheck(prefs);

  Future<void> _runInstallCheck(SharedPreferences prefs) async {
    final backend = _backend;
    if (backend == null || prefs.getBool(_installMarker) == true) return;
    final fresh = blobs.every((b) => !prefs.containsKey(b)) &&
        !prefs.containsKey('backup_encryption_passphrase');
    if (fresh) {
      for (final b in blobs) {
        try {
          await backend.delete(_secureKey(b));
        } catch (_) {}
      }
    }
    await prefs.setBool(_installMarker, true);
  }

  /// null = could not read (blob is now degraded); {} = nothing stored.
  Future<Map<String, dynamic>?> _readSecrets(String name) async {
    try {
      final raw = await _backend!.read(_secureKey(name));
      _degraded.remove(name);
      if (raw == null) {
        _known[name] = jsonEncode(const {});
        return {};
      }
      final decoded = jsonDecode(raw);
      final map = decoded is Map ? Map<String, dynamic>.from(decoded) : {};
      _known[name] = jsonEncode(Map.of(map)..remove('_rev'));
      return Map<String, dynamic>.from(map);
    } catch (e) {
      debugPrint('🔐 SecretStore: reading $name failed ($e); keeping its '
          'secrets in prefs until it can be read');
      _degraded.add(name);
      return null;
    }
  }

  /// Writes and reads back; true only when the secure copy is certain.
  Future<bool> _writeSecrets(
    String name,
    Map<String, dynamic> secrets,
    int rev,
  ) async {
    final encoded = jsonEncode({...secrets, '_rev': rev});
    try {
      await _backend!.write(_secureKey(name), encoded);
      final back = await _backend!.read(_secureKey(name));
      if (back != encoded) throw StateError('read-back mismatch');
      _known[name] = jsonEncode(secrets);
      return true;
    } catch (e) {
      debugPrint('🔐 SecretStore: writing $name failed ($e); kept in prefs');
      _known.remove(name);
      return false;
    }
  }

  /// Plaintext save. [mode] "all": prefs is the complete newer copy;
  /// "present": only the secret fields it holds are newer.
  Future<void> _savePlain(
    SharedPreferences prefs,
    String name,
    String encoded,
    String mode,
  ) async {
    await prefs.setInt(_revKey(name), DateTime.now().microsecondsSinceEpoch);
    await prefs.setString(_modeKey(name), mode);
    await prefs.setString(name, encoded);
  }

  /// Shared save: [secrets] to secure storage, [plain] / [stripped] to prefs.
  Future<void> _save(
    SharedPreferences prefs,
    String name,
    Map<String, dynamic> secrets,
    String plain,
    String stripped,
  ) async {
    if (_degraded.contains(name)) {
      await _savePlain(prefs, name, plain, 'present');
      return;
    }
    final unchanged = _known[name] == jsonEncode(secrets) &&
        prefs.getString(_modeKey(name)) == null;
    if (!unchanged) {
      final rev = DateTime.now().microsecondsSinceEpoch;
      if (!await _writeSecrets(name, secrets, rev)) {
        await _savePlain(prefs, name, plain, 'all');
        return;
      }
      await prefs.setInt(_revKey(name), rev);
      await prefs.remove(_modeKey(name));
    }
    await prefs.setString(name, stripped);
  }

  /// Which copy wins per field: null = secure copy; 'all' / 'present' =
  /// prefs (see [_savePlain]). Old prefs without a revision win only when
  /// there is no secure copy yet (upgrade).
  String? _plainMode(
    SharedPreferences prefs,
    String name,
    Map<String, dynamic> secrets,
  ) {
    final prefsRev = prefs.getInt(_revKey(name)) ?? 0;
    final secureRev = (secrets['_rev'] as num?)?.toInt() ?? -1;
    if (prefsRev <= secureRev) return null;
    return prefs.getString(_modeKey(name)) ?? 'present';
  }

  static void _mergeFields(
    Map<String, dynamic> target,
    Map secure,
    List<String> fields,
    String? mode,
  ) {
    for (final f in fields) {
      final inPrefs = target[f] != null;
      if (mode == 'all') continue; // prefs is complete
      if (mode == 'present' && inPrefs) continue;
      if (secure.containsKey(f)) {
        target[f] = secure[f];
      } else if (mode == null) {
        target.remove(f); // secure copy is authoritative: cleared
      }
    }
  }

  // ── Single JSON object (app settings, passphrase) ────────────────────

  /// Saves [json] under prefs [prefsKey]; [fields] go to secure storage.
  Future<void> saveObject(
    SharedPreferences prefs,
    String prefsKey,
    Map<String, dynamic> json,
    List<String> fields,
  ) {
    if (!enabled) return prefs.setString(prefsKey, jsonEncode(json));
    return _serial(prefsKey, () async {
      await _checkInstall(prefs);
      final secrets = <String, dynamic>{
        for (final f in fields)
          if (json[f] != null) f: json[f],
      };
      final stripped = Map<String, dynamic>.from(json)
        ..removeWhere((k, _) => fields.contains(k));
      await _save(prefs, prefsKey, secrets, jsonEncode(json),
          jsonEncode(stripped));
    });
  }

  /// Loads prefs [prefsKey] and puts the secret [fields] back in.
  Future<Map<String, dynamic>?> loadObject(
    SharedPreferences prefs,
    String prefsKey,
    List<String> fields,
  ) async {
    if (!enabled) {
      final raw = prefs.getString(prefsKey);
      return raw == null
          ? null
          : Map<String, dynamic>.from(jsonDecode(raw) as Map);
    }
    Map<String, dynamic>? out;
    var migrate = false;
    await _serial(prefsKey, () async {
      await _checkInstall(prefs);
      final raw = prefs.getString(prefsKey);
      final json = raw == null
          ? null
          : Map<String, dynamic>.from(jsonDecode(raw) as Map);
      final secrets = await _readSecrets(prefsKey);
      if (secrets == null) {
        out = json; // degraded: what prefs has
        return;
      }
      if (json == null && secrets.length <= (secrets.containsKey('_rev') ? 1 : 0)) {
        return;
      }
      final merged = json ?? <String, dynamic>{};
      final mode = _plainMode(prefs, prefsKey, secrets);
      migrate = fields.any((f) => merged[f] != null) ||
          prefs.getString(_modeKey(prefsKey)) != null;
      _mergeFields(merged, secrets, fields, mode);
      out = merged;
    });
    // Finish moving secrets out of prefs now (upgrade, or an earlier failed
    // write / degraded session) instead of waiting for the next edit.
    if (migrate && out != null) {
      await saveObject(prefs, prefsKey, out!, fields);
    }
    return out;
  }

  // ── List of JSON objects keyed by id (servers, providers) ────────────

  Future<void> saveList(
    SharedPreferences prefs,
    String prefsKey,
    List<Map<String, dynamic>> items,
    List<String> fields, {
    String idField = 'id',
  }) {
    if (!enabled) return prefs.setString(prefsKey, jsonEncode(items));
    return _serial(prefsKey, () async {
      await _checkInstall(prefs);
      final secrets = <String, dynamic>{};
      final stripped = <Map<String, dynamic>>[];
      for (final item in items) {
        final id = item[idField]?.toString();
        if (id == null) {
          stripped.add(item); // no id: can't be matched later, keep as-is
          continue;
        }
        final s = <String, dynamic>{
          for (final f in fields)
            if (item[f] != null) f: item[f],
        };
        if (s.isNotEmpty) secrets[id] = s;
        stripped.add(Map<String, dynamic>.from(item)
          ..removeWhere((k, _) => fields.contains(k)));
      }
      await _save(prefs, prefsKey, secrets, jsonEncode(items),
          jsonEncode(stripped));
    });
  }

  Future<List<Map<String, dynamic>>?> loadList(
    SharedPreferences prefs,
    String prefsKey,
    List<String> fields, {
    String idField = 'id',
  }) async {
    List<Map<String, dynamic>> decode(String raw) => [
          for (final e in jsonDecode(raw) as List)
            Map<String, dynamic>.from(e as Map),
        ];
    if (!enabled) {
      final raw = prefs.getString(prefsKey);
      return raw == null ? null : decode(raw);
    }
    List<Map<String, dynamic>>? out;
    var migrate = false;
    await _serial(prefsKey, () async {
      await _checkInstall(prefs);
      final raw = prefs.getString(prefsKey);
      final items = raw == null ? null : decode(raw);
      if (items == null) return;
      final secrets = await _readSecrets(prefsKey);
      if (secrets == null) {
        out = items;
        return;
      }
      final mode = _plainMode(prefs, prefsKey, secrets);
      migrate = prefs.getString(_modeKey(prefsKey)) != null;
      for (final item in items) {
        migrate |= fields.any((f) => item[f] != null);
        final s = secrets[item[idField]?.toString()];
        _mergeFields(item, s is Map ? s : const {}, fields, mode);
      }
      out = items;
    });
    if (migrate && out != null) {
      await saveList(prefs, prefsKey, out!, fields, idField: idField);
    }
    return out;
  }

  // ── Recovery ─────────────────────────────────────────────────────────

  /// Tries the secure copies that could not be read earlier (e.g. the app
  /// was launched in the background before the first unlock). True when
  /// something recovered — the caller should reload what it loaded.
  Future<bool> retryDegraded() async {
    if (_backend == null || _degraded.isEmpty) return false;
    var recovered = false;
    for (final name in List.of(_degraded)) {
      await _serial(name, () async {
        if (await _readSecrets(name) != null) recovered = true;
      });
    }
    return recovered;
  }

  Future<void> delete(SharedPreferences prefs, String prefsKey) {
    return _serial(prefsKey, () async {
      await prefs.remove(_revKey(prefsKey));
      await prefs.remove(_modeKey(prefsKey));
      _known.remove(prefsKey);
      final backend = _backend;
      if (backend == null) return;
      try {
        await backend.delete(_secureKey(prefsKey));
      } catch (e) {
        debugPrint('🔐 SecretStore: deleting $prefsKey failed ($e)');
      }
    });
  }

  /// Cloud / Ollama / oMLX / … provider list (premium package) through the
  /// same split. Call before the first `CloudApiService().load()`. No-op
  /// where secure storage isn't used, so desktop behaves exactly as before.
  void installCloudProviderPersistence() {
    if (_backend == null) return;
    const key = 'cloud_api_providers';
    const fields = ['apiKey', 'customHeaders'];
    CloudApiService.persistence = CloudProviderPersistence(
      read: () async => loadList(
        await SharedPreferences.getInstance(),
        key,
        fields,
      ),
      write: (items) async => saveList(
        await SharedPreferences.getInstance(),
        key,
        items,
        fields,
      ),
    );
  }
}
