import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:lm_mini/models/app_settings.dart';
import 'package:lm_mini/services/secret_store.dart';
import 'package:lm_mini/services/settings_service.dart';
import 'package:lm_mini_premium/lm_mini_premium.dart';
import 'package:shared_preferences/shared_preferences.dart';

class CountingBackend extends MemorySecretBackend {
  int writes = 0;
  @override
  Future<void> write(String key, String value) async {
    writes++;
    // Yield so concurrent operations would interleave if not serialized.
    await Future<void>.delayed(const Duration(milliseconds: 5));
    return super.write(key, value);
  }

  @override
  Future<String?> read(String key) async {
    await Future<void>.delayed(const Duration(milliseconds: 3));
    return super.read(key);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late MemorySecretBackend backend;
  final store = SecretStore.instance;
  final service = SettingsService();

  AppSettings withSecrets() => AppSettings(
        serverUrl: 'http://192.168.1.5:1234',
        apiToken: 'lms-token',
        cfAccessClientSecret: 'cf-secret',
        voiceElevenLabsApiKey: 'xi-key-123',
        remoteAuthToken: 'relay-token',
        temperature: 0.4,
      );

  Future<Map<String, dynamic>> rawPrefs() async {
    final prefs = await SharedPreferences.getInstance();
    return jsonDecode(prefs.getString('app_settings')!) as Map<String, dynamic>;
  }

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    backend = MemorySecretBackend();
    store.debugBackend = backend;
  });

  tearDown(() => store.debugBackend = null);

  test('secrets leave prefs and come back on load', () async {
    await service.saveSettings(withSecrets());
    final prefs = await rawPrefs();
    final plain = jsonEncode(prefs);
    for (final s in ['lms-token', 'cf-secret', 'xi-key-123', 'relay-token']) {
      expect(plain.contains(s), isFalse, reason: '$s still in prefs');
    }
    expect(prefs['serverUrl'], 'http://192.168.1.5:1234');

    final loaded = await service.loadSettings();
    expect(loaded.apiToken, 'lms-token');
    expect(loaded.cfAccessClientSecret, 'cf-secret');
    expect(loaded.voiceElevenLabsApiKey, 'xi-key-123');
    expect(loaded.remoteAuthToken, 'relay-token');
    expect(loaded.temperature, 0.4);
  });

  test('upgrade: plaintext from the old version moves into secure storage',
      () async {
    SharedPreferences.setMockInitialValues({
      'app_settings': jsonEncode(withSecrets().toJson()),
    });
    store.debugBackend = backend;
    final loaded = await service.loadSettings();
    expect(loaded.apiToken, 'lms-token');
    // Moved on load already, no edit needed.
    expect(jsonEncode(await rawPrefs()).contains('lms-token'), isFalse);
    expect((await service.loadSettings()).apiToken, 'lms-token');
  });

  test('clearing a key really clears it', () async {
    await service.saveSettings(withSecrets());
    final s = await service.loadSettings();
    await service.saveSettings(s.copyWith(apiToken: null));
    expect((await service.loadSettings()).apiToken, isNull);
  });

  test('a failed secure write keeps everything in prefs (nothing lost)',
      () async {
    backend.failWrites = true;
    await service.saveSettings(withSecrets());
    expect((await rawPrefs())['apiToken'], 'lms-token');
    expect((await service.loadSettings()).apiToken, 'lms-token');
  });

  test('a failed secure read falls back to prefs for the session', () async {
    // Old-version prefs with plaintext, secure storage unreadable.
    SharedPreferences.setMockInitialValues({
      'app_settings': jsonEncode(withSecrets().toJson()),
    });
    store.debugBackend = backend..failReads = true;
    final loaded = await service.loadSettings();
    expect(loaded.apiToken, 'lms-token');
    // Saving in that state keeps plaintext (no half-migration).
    await service.saveSettings(loaded.copyWith(temperature: 0.9));
    expect((await rawPrefs())['apiToken'], 'lms-token');
  });

  test('newer fallback plaintext beats an older secure copy', () async {
    await service.saveSettings(withSecrets()); // secure: lms-token
    // Next save can't reach secure storage: plaintext holds the new key.
    backend.failWrites = true;
    await service.saveSettings(withSecrets().copyWith(apiToken: 'new-token'));
    // Next launch, secure storage works again.
    store.debugBackend = backend..failWrites = false;
    expect((await service.loadSettings()).apiToken, 'new-token');
  });

  test('saved servers keep keys and headers in secure storage', () async {
    final prefs = await SharedPreferences.getInstance();
    await store.saveList(prefs, 'server_profiles_v1', [
      {
        'id': 'a',
        'name': 'Ollama',
        'apiKey': 'k-a',
        'customHeaders': {'CF-Access-Client-Secret': 'cf'},
      },
      {'id': 'b', 'name': 'Studio', 'apiKey': null},
    ], const ['apiKey', 'customHeaders']);
    final raw = prefs.getString('server_profiles_v1')!;
    expect(raw.contains('k-a'), isFalse);
    expect(raw.contains('"cf"'), isFalse);

    final back = await store.loadList(
        prefs, 'server_profiles_v1', const ['apiKey', 'customHeaders']);
    expect(back![0]['apiKey'], 'k-a');
    expect(back[0]['customHeaders'], {'CF-Access-Client-Secret': 'cf'});
    expect(back[1]['apiKey'], isNull);
  });

  test('without a backend (desktop) prefs keep everything as before',
      () async {
    store.debugBackend = null;
    await service.saveSettings(withSecrets());
    expect((await rawPrefs())['apiToken'], 'lms-token');
    expect((await service.loadSettings()).apiToken, 'lms-token');
  });

  test('cloud providers (premium package) keep keys out of prefs', () async {
    store.installCloudProviderPersistence();
    addTearDown(() => CloudApiService.persistence = null);
    final cloud = CloudApiService();
    await cloud.saveProvider(CloudApiProvider(
      id: 'or-1',
      name: 'OpenRouter',
      type: CloudApiType.openRouter,
      apiKey: 'sk-or-secret',
      isEnabled: true,
      customHeaders: const {'X-Title': 'LM Mini'},
      customHeadersEnabled: true,
    ));
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString('cloud_api_providers')!;
    expect(raw.contains('sk-or-secret'), isFalse);
    expect(raw.contains('OpenRouter'), isTrue);

    final back = await CloudApiService.persistence!.read();
    final p = back!.firstWhere((m) => m['id'] == 'or-1');
    expect(p['apiKey'], 'sk-or-secret');
    expect(p['customHeaders'], {'X-Title': 'LM Mini'});
    await cloud.removeProvider('or-1');
  });

  group('review scenarios', () {
    /// A new app launch: same Keychain / prefs, fresh in-memory state.
    void relaunch(MemorySecretBackend b) => store.debugBackend = b;

    test('concurrent saves keep the store on and the last value wins',
        () async {
      final b = CountingBackend();
      store.debugBackend = b;
      final base = withSecrets();
      await service.saveSettings(base.copyWith(apiToken: 'a'));
      await Future.wait([
        service.saveSettings(base.copyWith(apiToken: 'b')),
        service.saveSettings(base.copyWith(apiToken: 'c')),
      ]);
      await service.saveSettings(base.copyWith(apiToken: 'd'));
      expect(jsonEncode(await rawPrefs()).contains('"apiToken"'), isFalse);
      relaunch(b);
      expect((await service.loadSettings()).apiToken, 'd');
    });

    test('saving unchanged secrets does not rewrite the Keychain', () async {
      final b = CountingBackend();
      store.debugBackend = b;
      await service.saveSettings(withSecrets());
      final after1 = b.writes;
      for (var t = 0.1; t < 0.6; t += 0.1) {
        await service.saveSettings(withSecrets().copyWith(temperature: t));
      }
      expect(b.writes, after1);
    });

    test('locked-phone launch: keys survive and a re-entered key wins',
        () async {
      await service.saveSettings(withSecrets()); // all in Keychain
      // Background launch before first unlock: reads fail.
      relaunch(backend..failReads = true);
      final degraded = await service.loadSettings();
      expect(degraded.apiToken, isNull); // not readable yet
      // An unrelated save in that state must not lose the keys...
      await service.saveSettings(degraded.copyWith(temperature: 0.7));
      // ...and the user re-enters only the LM Studio token.
      await service.saveSettings(
          degraded.copyWith(temperature: 0.7, apiToken: 'typed-again'));
      backend.failReads = false;
      expect(await store.retryDegraded(), isTrue);
      final back = await service.loadSettings();
      expect(back.apiToken, 'typed-again');
      expect(back.remoteAuthToken, 'relay-token'); // from the Keychain
      expect(back.temperature, 0.7);
      relaunch(backend);
      expect((await service.loadSettings()).remoteAuthToken, 'relay-token');
    });

    test('a key cleared while the Keychain failed stays cleared', () async {
      await service.saveSettings(withSecrets());
      backend.failWrites = true;
      final s = await service.loadSettings();
      await service.saveSettings(s.copyWith(apiToken: null));
      relaunch(backend..failWrites = false);
      expect((await service.loadSettings()).apiToken, isNull);
      expect((await service.loadSettings()).remoteAuthToken, 'relay-token');
    });

    test('fresh install: secrets left in the Keychain are not restored',
        () async {
      await service.saveSettings(withSecrets());
      // Uninstall: prefs gone, iOS Keychain stays.
      SharedPreferences.setMockInitialValues({});
      relaunch(backend);
      final s = await service.loadSettings();
      expect(s.apiToken, isNull);
      expect(s.remoteAuthToken, isNull);
    });

    test('upgrade keeps keys (no install marker yet, prefs present)',
        () async {
      SharedPreferences.setMockInitialValues({
        'app_settings': jsonEncode(withSecrets().toJson()),
      });
      relaunch(backend);
      expect((await service.loadSettings()).apiToken, 'lms-token');
      relaunch(backend);
      expect((await service.loadSettings()).apiToken, 'lms-token');
    });
  });
}
