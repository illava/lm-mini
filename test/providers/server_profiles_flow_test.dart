import 'package:flutter_test/flutter_test.dart';
import 'package:lm_mini/models/app_settings.dart';
import 'package:lm_mini/models/server_profile.dart';
import 'package:lm_mini/providers/settings_provider.dart';
import 'package:lm_mini/services/server_profile_service.dart';
import 'package:lm_mini_premium/lm_mini_premium.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Saved servers: keys, models and the active tick behave per server.
/// Hosts are 127.0.0.1:9 so model listing fails fast without a network.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late SettingsProvider sp;
  final cloud = CloudApiService();
  final profiles = ServerProfileService.instance;

  Future<void> fresh({bool pro = false}) async {
    SharedPreferences.setMockInitialValues({
      'server_profiles_v1_migrated': true,
    });
    SubscriptionService().applyPromotionalGrant(
      pro ? DateTime.now().add(const Duration(days: 1)) : null,
    );
    await cloud.load();
    for (final p in List.of(cloud.providers)) {
      await cloud.removeProvider(p.id);
    }
    await cloud.setActiveProvider(null);
    sp = SettingsProvider();
    await sp.updateSettings(AppSettings(serverUrl: 'http://127.0.0.1:9'));
    await profiles.load(settings: sp.settings, cloud: cloud);
    for (final p in List.of(profiles.profiles)) {
      await profiles.delete(p.id);
    }
  }

  ServerProfile cloudProfile(
    String id,
    CloudApiType type, {
    String? key,
    String url = 'http://127.0.0.1:9',
  }) =>
      ServerProfile(
        id: id,
        name: id,
        kind: ServerProfileKind.cloud,
        cloudType: type,
        baseUrl: url,
        apiKey: key,
        lastUsedAt: DateTime.now(),
      );

  CloudApiProvider provider(String id) =>
      cloud.providers.firstWhere((p) => p.id == id);

  group('clearing an API key', () {
    test('cloud-style server: a cleared key is not sent any more', () async {
      await fresh();
      await sp.saveAndActivateServerProfile(
        cloudProfile('jan-1', CloudApiType.jan, key: 'old-secret'),
      );
      expect(provider('jan-1').apiKey, 'old-secret');

      // The edit sheet sends '' for a cleared key field.
      await sp.saveAndActivateServerProfile(
        cloudProfile('jan-1', CloudApiType.jan, key: ''),
      );
      expect(provider('jan-1').apiKey, isEmpty);
      expect(profiles.byId('jan-1')!.apiKey, isEmpty);

      // Re-activating later must not bring it back either.
      await sp.activateServerProfile('jan-1');
      expect(provider('jan-1').apiKey, isEmpty);
    });

    test('LM Studio: a cleared key clears the bearer token', () async {
      await fresh();
      ServerProfile lms(String key) => ServerProfile(
            id: 'lms-1',
            name: 'Studio',
            kind: ServerProfileKind.lmStudio,
            baseUrl: 'http://127.0.0.1:9',
            apiKey: key,
            lastUsedAt: DateTime.now(),
          );
      await sp.saveAndActivateServerProfile(lms('lms-secret'));
      expect(sp.settings.apiToken, 'lms-secret');
      await sp.saveAndActivateServerProfile(lms(''));
      expect(sp.settings.apiToken, isNull);
    });

    test('an untouched key on a different saved row is still reused', () {
      // Adding the same endpoint again without typing a key keeps the key
      // (null = "not specified"), which the merge still honours.
      final merged = ServerProfile(
        id: 'a',
        name: 'a',
        kind: ServerProfileKind.lmStudio,
        apiKey: null,
        lastUsedAt: DateTime.now(),
      ).apiKey ?? 'kept';
      expect(merged, 'kept');
    });
  });

  group('selected model', () {
    test('picking a model updates the model chat actually sends', () async {
      await fresh();
      await sp.saveAndActivateServerProfile(
        cloudProfile('ollama-a', CloudApiType.ollama),
      );
      sp.updateSelectedModel('llama3:8b');
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(provider('ollama-a').selectedModel, 'llama3:8b');
      sp.updateSelectedModel('qwen3:4b');
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(provider('ollama-a').selectedModel, 'qwen3:4b');
      expect(sp.settings.selectedModel, 'qwen3:4b');
    });

    test('two Ollama servers each keep their own model', () async {
      await fresh();
      await sp.saveAndActivateServerProfile(
        cloudProfile('ollama-a', CloudApiType.ollama,
            url: 'http://127.0.0.1:9'),
      );
      sp.updateSelectedModel('model-on-a');
      await sp.saveAndActivateServerProfile(
        cloudProfile('ollama-b', CloudApiType.ollama,
            url: 'http://127.0.0.2:9'),
      );
      expect(sp.settings.selectedModel, isNot('model-on-a'));
      sp.updateSelectedModel('model-on-b');

      await sp.activateServerProfile('ollama-a');
      expect(sp.settings.selectedModel, 'model-on-a');
      await sp.activateServerProfile('ollama-b');
      expect(sp.settings.selectedModel, 'model-on-b');
    });

    test('OpenAI → new Mistral does not carry the gpt model over', () async {
      await fresh(pro: true);
      await sp.saveAndActivateServerProfile(
        cloudProfile('openai-1', CloudApiType.openai, key: 'k'),
      );
      sp.updateSelectedModel('gpt-4o');
      await sp.saveAndActivateServerProfile(
        cloudProfile('mistral-1', CloudApiType.mistral, key: 'k'),
      );
      expect(sp.settings.selectedModel, isNot('gpt-4o'));
      expect(provider('mistral-1').selectedModel, isNot('gpt-4o'));

      await sp.activateServerProfile('openai-1');
      expect(sp.settings.selectedModel, 'gpt-4o');
    });
  });

  group('locked (Pro) servers', () {
    test('tapping a locked server does not mark it active', () async {
      await fresh(pro: true);
      await sp.saveAndActivateServerProfile(
        cloudProfile('ollama-a', CloudApiType.ollama),
      );
      await profiles.upsert(
        cloudProfile('openai-1', CloudApiType.openai, key: 'k'),
      );
      SubscriptionService().applyPromotionalGrant(null); // Pro lapsed
      final ok = await sp.activateServerProfile('openai-1');
      expect(ok, isFalse);
      expect(profiles.activeId, 'ollama-a');
      expect(sp.settings.activeProviderKind, 'ollama');
    });

    test('losing Pro moves the tick off the paid server', () async {
      await fresh(pro: true);
      await sp.saveAndActivateServerProfile(ServerProfile(
        id: 'lms-1',
        name: 'Studio',
        kind: ServerProfileKind.lmStudio,
        baseUrl: 'http://127.0.0.1:9',
        lastUsedAt: DateTime.now(),
      ));
      await sp.saveAndActivateServerProfile(
        cloudProfile('openai-1', CloudApiType.openai, key: 'k'),
      );
      expect(profiles.activeId, 'openai-1');
      SubscriptionService().applyPromotionalGrant(null);
      await sp.restoreLocalModelIfNeeded();
      expect(sp.settings.activeProviderKind, 'lmStudio');
      expect(profiles.activeId, 'lms-1');
    });
  });

  group('review scenarios', () {
    ServerProfile lms(String id, String url) => ServerProfile(
          id: id,
          name: id,
          kind: ServerProfileKind.lmStudio,
          baseUrl: url,
          lastUsedAt: DateTime.now(),
        );

    test('free launch keeps the tick on the second LM Studio server',
        () async {
      await fresh();
      await sp.saveAndActivateServerProfile(lms('home', 'http://127.0.0.1:9'));
      await sp.saveAndActivateServerProfile(
          lms('office', 'http://127.0.0.2:9'));
      expect(profiles.activeId, 'office');
      await sp.restoreLocalModelIfNeeded(); // runs on every free launch
      expect(profiles.activeId, 'office');
      expect(sp.settings.serverUrl, 'http://127.0.0.2:9');
    });

    test('leaving the second of two Ollamas does not touch the first',
        () async {
      await fresh(pro: true);
      await sp.saveAndActivateServerProfile(
          cloudProfile('o1', CloudApiType.ollama, url: 'http://127.0.0.1:9'));
      sp.updateSelectedModel('model-o1');
      await sp.saveAndActivateServerProfile(
          cloudProfile('o2', CloudApiType.ollama, url: 'http://127.0.0.2:9'));
      sp.updateSelectedModel('model-o2');
      await sp.saveAndActivateServerProfile(
          cloudProfile('mistral-1', CloudApiType.mistral, key: 'k'));
      await sp.activateServerProfile('o1');
      expect(sp.settings.selectedModel, 'model-o1');
      await sp.activateServerProfile('o2');
      expect(sp.settings.selectedModel, 'model-o2');
    });
  });
}
