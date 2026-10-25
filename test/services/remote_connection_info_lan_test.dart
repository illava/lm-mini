import 'package:flutter_test/flutter_test.dart';
import 'package:lm_mini/services/remote_connection_info.dart';
import 'package:lm_mini/utils/home_lan.dart';

void main() {
  const fp = 'ab12cd34ef56ab12cd34ef56ab12cd34ef56ab12cd34ef56ab12cd34ef56ab12';

  /// Built the same way as `DesktopHostService.pairingUrl`.
  String link(Map<String, String> params) =>
      Uri.parse('https://relay.lmmini.com/s/sess1')
          .replace(fragment: Uri(queryParameters: params).query)
          .toString();

  group('pairing link lan / lfp', () {
    test('round-trips endpoints and fingerprint', () {
      final info = RemoteRelayHttp.parseRelayUrl(link({
        't': 'tok',
        'b': 'lmMiniDesktop',
        'hv': '2.2.0',
        kLanLinkParam: 'https://192.168.1.20:8743,https://10.0.0.5:8743',
        kLanFingerprintLinkParam: fp.toUpperCase(),
      }))!;
      expect(info.url, 'https://relay.lmmini.com/s/sess1');
      expect(info.token, 'tok');
      expect(info.lanUrls,
          ['https://192.168.1.20:8743', 'https://10.0.0.5:8743']);
      expect(info.lanFingerprint, fp);
      expect(info.hasLan, isTrue);
    });

    test('old links (no lan params) are unchanged', () {
      final info = RemoteRelayHttp.parseRelayUrl(
          link({'t': 'tok', 'b': 'lmMiniDesktop,lmStudio'}))!;
      expect(info.lanUrls, isNull);
      expect(info.lanFingerprint, isNull);
      expect(info.hasLan, isFalse);
      expect(info.backends, ['lmMiniDesktop', 'lmStudio']);
    });

    test('public addresses and bad pins are dropped', () {
      final info = RemoteRelayHttp.parseRelayUrl(link({
        't': 'tok',
        kLanLinkParam: 'https://8.8.8.8:8743,http://192.168.1.2:8743',
        kLanFingerprintLinkParam: 'not-a-hash',
      }))!;
      expect(info.lanUrls, isEmpty);
      expect(info.lanFingerprint, isNull);
      expect(info.hasLan, isFalse);
    });
  });

  group('JSON QR lan / lanFingerprint', () {
    test('parsed when present', () {
      final info = RemoteConnectionInfo.fromJson({
        'v': 5,
        'url': 'https://relay.lmmini.com/s/sess1',
        'token': 'tok',
        kLanJsonKey: ['https://192.168.1.20:8744'],
        kLanFingerprintJsonKey: fp,
      });
      expect(info.lanUrls, ['https://192.168.1.20:8744']);
      expect(info.lanFingerprint, fp);
      expect(info.hasLan, isTrue);
    });

    test('absent on old QRs', () {
      final info = RemoteConnectionInfo.fromJson({
        'v': 5,
        'url': 'https://relay.lmmini.com/s/sess1',
        'token': 'tok',
      });
      expect(info.lanUrls, isNull);
      expect(info.hasLan, isFalse);
    });
  });
}
