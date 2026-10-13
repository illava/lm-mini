import 'package:flutter_test/flutter_test.dart';
import 'package:lm_mini/utils/server_url.dart';
import 'package:lm_mini_premium/lm_mini_premium.dart';

void main() {
  group('scheme when none is typed', () {
    test('public hosts get https (keys never go out in cleartext)', () {
      expect(normalizeCloudBaseUrl('api.example.com'), 'https://api.example.com');
      expect(normalizeCloudBaseUrl('llm.mydomain.io:8443/'),
          'https://llm.mydomain.io:8443');
      expect(normalizeCloudBaseUrl('8.8.8.8:1234'), 'https://8.8.8.8:1234');
    });

    test('this machine, LAN, VPN and local names keep http', () {
      for (final host in [
        'localhost:1234',
        '127.0.0.1:1234',
        '192.168.1.20:11434',
        '10.0.0.5:8000',
        '172.20.1.1:1234',
        '100.101.102.103:1234', // Tailscale
        'mac-mini:1234',
        'studio.local:1234',
        'box.lan',
        'pc.tail1234.ts.net:1234',
        'mypc.fritz.box:1234',
        'nas.home.arpa:11434',
        'server.localdomain',
      ]) {
        expect(normalizeCloudBaseUrl(host), 'http://$host'.replaceAll(RegExp(r'/$'), ''),
            reason: host);
      }
    });

    test('an explicit scheme is never changed', () {
      expect(normalizeCloudBaseUrl('http://api.example.com'),
          'http://api.example.com');
      expect(normalizeCloudBaseUrl('https://192.168.1.5:1234'),
          'https://192.168.1.5:1234');
    });
  });

  group('pasted /v1', () {
    test('cut back only when asked (types whose paths start with /v1/)', () {
      expect(
        normalizeCloudBaseUrl('https://openrouter.ai/api/v1',
            stripVersionSuffix: true),
        'https://openrouter.ai/api',
      );
      expect(
        normalizeCloudBaseUrl('http://192.168.1.5:8000/v1/chat/completions',
            stripVersionSuffix: true),
        'http://192.168.1.5:8000',
      );
      expect(
        normalizeCloudBaseUrl('https://openrouter.ai/api/v1'),
        'https://openrouter.ai/api/v1',
      );
    });

    test('does not touch v1beta or other versions', () {
      expect(
        normalizeCloudBaseUrl(
            'https://generativelanguage.googleapis.com/v1beta/openai',
            stripVersionSuffix: true),
        'https://generativelanguage.googleapis.com/v1beta/openai',
      );
      expect(
        normalizeCloudBaseUrl('https://api.z.ai/api/paas/v4',
            stripVersionSuffix: true),
        'https://api.z.ai/api/paas/v4',
      );
    });

    test('providers build correct request URLs from a pasted /v1', () {
      final p = CloudApiProvider(
        id: 'x',
        name: 'x',
        type: CloudApiType.openaiCompatible,
        apiKey: '',
        baseUrl: 'http://192.168.1.5:8080/v1/',
        isEnabled: true,
      );
      expect(p.effectiveBaseUrl, 'http://192.168.1.5:8080');
      expect(p.chatCompletionsUrl, 'http://192.168.1.5:8080/v1/chat/completions');
    });

    test('Gemini and Z.ai defaults are unchanged', () {
      for (final t in [CloudApiType.gemini, CloudApiType.zAi]) {
        final p = CloudApiProvider(
            id: 't', name: 't', type: t, apiKey: '', isEnabled: true);
        expect(p.effectiveBaseUrl, normalizeCloudBaseUrl(t.defaultBaseUrl));
      }
    });
  });

  group('LM Studio base URL', () {
    test('strips pasted API paths back to the server root', () {
      expect(normalizeLmStudioBaseUrl('http://192.168.1.5:1234/v1'),
          'http://192.168.1.5:1234');
      expect(normalizeLmStudioBaseUrl('192.168.1.5:1234/api/v1/'),
          'http://192.168.1.5:1234');
      expect(normalizeLmStudioBaseUrl('http://192.168.1.5:1234/api/v0/models'),
          'http://192.168.1.5:1234');
      expect(normalizeLmStudioBaseUrl('http://192.168.1.5:1234'),
          'http://192.168.1.5:1234');
    });

    test('a reverse-proxy path prefix is kept', () {
      expect(normalizeLmStudioBaseUrl('https://example.com/lmstudio/v1'),
          'https://example.com/lmstudio');
    });
  });
}
