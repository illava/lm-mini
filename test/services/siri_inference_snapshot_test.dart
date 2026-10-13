import 'package:flutter_test/flutter_test.dart';
import 'package:lm_mini/models/app_settings.dart';
import 'package:lm_mini/services/siri_inference_snapshot.dart';
import 'package:lm_mini_premium/lm_mini_premium.dart';

void main() {
  group('SiriInferenceSnapshot', () {
    test('LAN LM Studio is eligible for native Siri HTTP', () {
      final snap = SiriInferenceSnapshot.from(
        settings: AppSettings(
          serverUrl: 'http://192.168.1.20:1234',
          selectedModel: 'google/gemma-3-4b',
          apiToken: 'secret-token',
          activeProviderKind: 'lmStudio',
        ),
      );
      expect(snap.eligible, isTrue);
      expect(snap.chatUrl, 'http://192.168.1.20:1234/v1/chat/completions');
      expect(snap.model, 'google/gemma-3-4b');
      expect(snap.headers['Authorization'], 'Bearer secret-token');
      expect(snap.ineligibleReason, isNull);
    });

    test('localhost is not eligible (phone loopback / USB)', () {
      final snap = SiriInferenceSnapshot.from(
        settings: AppSettings(
          serverUrl: 'http://127.0.0.1:1234',
          selectedModel: 'google/gemma-3-4b',
          activeProviderKind: 'lmStudio',
        ),
      );
      expect(snap.eligible, isFalse);
      expect(snap.ineligibleReason, 'loopback');
      expect(snap.chatUrl, contains('/v1/chat/completions'));
      expect(snap.model, 'google/gemma-3-4b');
    });

    test('on-device GGUF is not eligible', () {
      final snap = SiriInferenceSnapshot.from(
        settings: AppSettings(
          serverUrl: 'http://192.168.1.20:1234',
          selectedModel: 'google/gemma-3-4b',
          activeProviderKind: 'onDeviceGguf',
        ),
      );
      expect(snap.eligible, isFalse);
      expect(snap.ineligibleReason, 'on-device');
      expect(snap.chatUrl, isNull);
    });

    test('forceOnDevice skips a LAN server', () {
      final snap = SiriInferenceSnapshot.from(
        settings: AppSettings(
          serverUrl: 'http://192.168.1.20:1234',
          selectedModel: 'google/gemma-3-4b',
          activeProviderKind: 'lmStudio',
        ),
        forceOnDevice: true,
      );
      expect(snap.eligible, isFalse);
      expect(snap.ineligibleReason, 'on-device');
    });

    test('missing model is not eligible', () {
      final snap = SiriInferenceSnapshot.from(
        settings: AppSettings(
          serverUrl: 'http://192.168.1.20:1234',
          activeProviderKind: 'lmStudio',
        ),
      );
      expect(snap.eligible, isFalse);
      expect(snap.ineligibleReason, 'no-model');
    });

    test('cloud OpenRouter is eligible and keeps extra headers', () {
      final cloud = CloudApiProvider(
        id: 'or1',
        name: 'OpenRouter',
        type: CloudApiType.openRouter,
        apiKey: 'sk-or-test',
        selectedModel: 'openai/gpt-4o-mini',
      );
      final snap = SiriInferenceSnapshot.from(
        settings: AppSettings(activeProviderKind: 'cloud'),
        cloud: cloud,
      );
      expect(snap.eligible, isTrue);
      expect(snap.chatUrl, contains('openrouter'));
      expect(snap.chatUrl, endsWith('/v1/chat/completions'));
      expect(snap.headers['Authorization'], 'Bearer sk-or-test');
      expect(snap.headers['HTTP-Referer'], 'https://lmmini.app');
      expect(snap.headers['X-Title'], 'LM Mini');
    });

    test('strips hop-by-hop custom headers', () {
      final snap = SiriInferenceSnapshot.from(
        settings: AppSettings(
          serverUrl: 'http://10.0.0.8:1234',
          selectedModel: 'qwen',
          activeProviderKind: 'lmStudio',
          customHeadersEnabled: true,
          customRequestHeaders: {
            'X-Proxy': 'ok',
            'Content-Length': '999',
            'Host': 'evil.example',
          },
        ),
      );
      expect(snap.eligible, isTrue);
      expect(snap.headers['X-Proxy'], 'ok');
      expect(snap.headers.containsKey('Content-Length'), isFalse);
      expect(snap.headers.containsKey('Host'), isFalse);
    });

    test('joinUrl strips trailing slashes', () {
      expect(
        SiriInferenceSnapshot.joinUrl(
            'http://10.0.0.1:1234/', '/v1/chat/completions'),
        'http://10.0.0.1:1234/v1/chat/completions',
      );
    });

    test('isLoopbackHost covers localhost aliases', () {
      expect(SiriInferenceSnapshot.isLoopbackHost('localhost'), isTrue);
      expect(SiriInferenceSnapshot.isLoopbackHost('127.0.0.1'), isTrue);
      expect(SiriInferenceSnapshot.isLoopbackHost('::1'), isTrue);
      expect(SiriInferenceSnapshot.isLoopbackHost('192.168.1.5'), isFalse);
    });

    test('toMap/fromMap round-trip', () {
      final original = SiriInferenceSnapshot.from(
        settings: AppSettings(
          serverUrl: 'http://10.0.0.2:1234',
          selectedModel: 'm',
          activeProviderKind: 'lmStudio',
          temperature: 0.2,
          maxTokens: 2000,
        ),
      );
      final copy = SiriInferenceSnapshot.fromMap(original.toMap());
      expect(copy.eligible, original.eligible);
      expect(copy.chatUrl, original.chatUrl);
      expect(copy.model, original.model);
      expect(copy.maxTokens, 1024);
    });
  });

  group('MCP tools for Shortcuts', () {
    AppSettings lms({bool tools = true, String? token = 'tok', bool usb = false}) =>
        AppSettings(
          serverUrl: 'http://192.168.1.5:1234',
          selectedModel: 'gemma',
          apiToken: token,
          enableToolUse: tools,
          usbModeEnabled: usb,
          integratedMcps: [IntegratedMcpConfig(name: 'web-search')],
          mcpServers: [
            McpServerConfig(label: 'web-search', url: 'https://a.example/mcp'),
            McpServerConfig(label: 'weather', url: 'https://w.example/mcp'),
          ],
        );

    test('LM Studio with tools on uses /api/v1/chat with the MCP list', () {
      final snap = SiriInferenceSnapshot.from(settings: lms());
      expect(snap.usesTools, isTrue);
      expect(snap.toolsChatUrl, 'http://192.168.1.5:1234/api/v1/chat');
      // Configured tool first; the same-named URL tool is skipped.
      expect(snap.integrations, [
        {'type': 'plugin', 'id': 'mcp/web-search'},
        containsPair('server_label', 'weather'),
      ]);
      expect(snap.chatUrl, 'http://192.168.1.5:1234/v1/chat/completions');
    });

    test('tools off, or no tools configured: plain completion only', () {
      expect(SiriInferenceSnapshot.from(settings: lms(tools: false)).usesTools,
          isFalse);
      final none = SiriInferenceSnapshot.from(
        settings: AppSettings(
          serverUrl: 'http://192.168.1.5:1234',
          selectedModel: 'gemma',
          enableToolUse: true,
        ),
      );
      expect(none.usesTools, isFalse);
      expect(none.toMap().containsKey('integrations'), isFalse);
    });

    test('no LM Studio token: configured tools need auth, URL tools stay', () {
      final snap = SiriInferenceSnapshot.from(settings: lms(token: null));
      expect(snap.integrations.length, 2);
      expect(snap.integrations.every((m) => m['type'] == 'ephemeral_mcp'),
          isTrue);
    });

    test('USB mode never uses the tools API', () {
      expect(SiriInferenceSnapshot.from(settings: lms(usb: true)).usesTools,
          isFalse);
    });

    test('tools survive the trip to the native side', () {
      final snap = SiriInferenceSnapshot.from(settings: lms());
      final back = SiriInferenceSnapshot.fromMap(snap.toMap());
      expect(back.toolsChatUrl, snap.toolsChatUrl);
      expect(back.integrations, snap.integrations);
    });
  });
}
