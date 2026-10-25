import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lm_mini/utils/home_lan.dart';

void main() {
  group('isPrivateIPv4', () {
    test('accepts RFC 1918 ranges', () {
      for (final ip in [
        '10.0.0.1',
        '10.255.255.254',
        '172.16.0.1',
        '172.31.255.1',
        '192.168.0.1',
        '192.168.1.20',
      ]) {
        expect(isPrivateIPv4(ip), isTrue, reason: ip);
      }
    });

    test('rejects public, loopback, link-local, CGNAT and junk', () {
      for (final ip in [
        '8.8.8.8',
        '172.15.0.1',
        '172.32.0.1',
        '192.169.0.1',
        '127.0.0.1',
        '169.254.10.2',
        '100.64.0.1', // Tailscale / CGNAT
        '0.0.0.0',
        '256.1.1.1',
        '10.0.0',
        '10.0.0.1.5',
        'fe80::1',
        '',
        'example.com',
      ]) {
        expect(isPrivateIPv4(ip), isFalse, reason: ip);
      }
    });

    test('LAN peers: private + loopback, IPv4-mapped allowed', () {
      expect(isLanPeerAddress('192.168.1.7'), isTrue);
      expect(isLanPeerAddress('::ffff:10.0.0.3'), isTrue);
      expect(isLanPeerAddress('127.0.0.1'), isTrue);
      expect(isLanPeerAddress('203.0.113.9'), isFalse);
      expect(isLanPeerAddress('100.100.1.1'), isFalse);
    });
  });

  group('advertisableLanAddresses', () {
    test('keeps private addresses, skips VPN / virtual interfaces', () {
      final out = advertisableLanAddresses(const [
        LanInterfaceAddress('lo0', '127.0.0.1'),
        LanInterfaceAddress('utun3', '10.8.0.2'), // VPN
        LanInterfaceAddress('bridge100', '192.168.64.1'), // VM / sharing
        LanInterfaceAddress('en7', '10.0.0.5'),
        LanInterfaceAddress('en0', '192.168.1.20'),
        LanInterfaceAddress('en0', '192.168.1.20'), // duplicate
        LanInterfaceAddress('en1', '84.10.20.30'), // public
        LanInterfaceAddress('ipsec0', '172.20.0.2'),
        LanInterfaceAddress('awdl0', '169.254.3.3'),
      ]);
      expect(out, ['10.0.0.5', '192.168.1.20']);
    });

    test('physical en* first, then other private interfaces', () {
      final out = advertisableLanAddresses(const [
        LanInterfaceAddress('eth0', '172.16.4.4'),
        LanInterfaceAddress('en0', '192.168.0.9'),
      ]);
      expect(out, ['192.168.0.9', '172.16.4.4']);
    });

    test('lanUrlsFor builds https endpoints', () {
      expect(lanUrlsFor(['192.168.1.20'], 8743), ['https://192.168.1.20:8743']);
    });
  });

  group('parseLanEndpoint / parseLanUrls', () {
    test('accepts https://private-ip:port only', () {
      expect(parseLanEndpoint('https://192.168.1.20:8743').toString(),
          'https://192.168.1.20:8743');
      expect(parseLanEndpoint('https://192.168.1.20:8743/'), isNotNull);
      expect(parseLanEndpoint('http://192.168.1.20:8743'), isNull);
      expect(parseLanEndpoint('https://192.168.1.20'), isNull); // no port
      expect(parseLanEndpoint('https://8.8.8.8:8743'), isNull);
      expect(parseLanEndpoint('https://relay.lmmini.com:443'), isNull);
      expect(parseLanEndpoint('https://192.168.1.20:8743/x'), isNull);
      expect(parseLanEndpoint('https://u:p@192.168.1.20:8743'), isNull);
    });

    test('comma list and JSON list, invalid and duplicate entries dropped',
        () {
      expect(
        parseLanUrls(
            'https://192.168.1.20:8743, https://8.8.8.8:1,https://10.0.0.2:8744,'
            'https://192.168.1.20:8743'),
        ['https://192.168.1.20:8743', 'https://10.0.0.2:8744'],
      );
      expect(parseLanUrls(['https://10.1.2.3:8743', 42, 'nope']),
          ['https://10.1.2.3:8743']);
      expect(parseLanUrls(null), isEmpty);
      expect(parseLanUrls(''), isEmpty);
    });
  });

  group('fingerprints', () {
    final der = List<int>.generate(300, (i) => i % 256);
    final hex = sha256.convert(der).toString();

    test('normalize accepts colon / upper-case form, rejects junk', () {
      final colons = [
        for (var i = 0; i < hex.length; i += 2) hex.substring(i, i + 2)
      ].join(':').toUpperCase();
      expect(normalizeFingerprint(colons), hex);
      expect(normalizeFingerprint(hex), hex);
      expect(normalizeFingerprint('abc'), isNull);
      expect(normalizeFingerprint('z' * 64), isNull);
      expect(normalizeFingerprint(null), isNull);
    });

    test('certificate matches only its own pin', () {
      expect(certificateFingerprint(der), hex);
      expect(certificateMatchesPin(der, hex), isTrue);
      expect(certificateMatchesPin(der, hex.toUpperCase()), isTrue);
      expect(certificateMatchesPin(der, 'a' * 64), isFalse);
      expect(certificateMatchesPin(der, null), isFalse);
      expect(certificateMatchesPin(der, ''), isFalse);
      expect(certificateMatchesPin(const [], hex), isFalse);
      final tampered = List<int>.of(der)..[10] ^= 1;
      expect(certificateMatchesPin(tampered, hex), isFalse);
    });

    test('constantTimeEquals', () {
      expect(constantTimeEquals('abc', 'abc'), isTrue);
      expect(constantTimeEquals('abc', 'abd'), isFalse);
      expect(constantTimeEquals('abc', 'abcd'), isFalse);
      expect(constantTimeEquals('', ''), isTrue);
      expect(constantTimeEquals('', 'a'), isFalse);
    });
  });

  group('lanUriForRelayRequest', () {
    const relay = 'https://relay.lmmini.com/s/abc123';
    final lan = Uri.parse('https://192.168.1.20:8743');

    test('maps the relay path and query onto the direct endpoint', () {
      expect(
        lanUriForRelayRequest(
                Uri.parse('$relay/v1/chat/completions?x=1&y=a%20b'), relay, lan)
            .toString(),
        'https://192.168.1.20:8743/v1/chat/completions?x=1&y=a%20b',
      );
      expect(lanUriForRelayRequest(Uri.parse(relay), relay, lan).toString(),
          'https://192.168.1.20:8743/');
      expect(
        lanUriForRelayRequest(Uri.parse('$relay/view?filename=a%2Fb.png'),
                '$relay/', lan)
            .toString(),
        'https://192.168.1.20:8743/view?filename=a%2Fb.png',
      );
    });

    test('leaves other hosts, sessions and schemes alone', () {
      for (final other in [
        'https://api.openai.com/v1/models',
        'https://relay.lmmini.com/s/other/v1/models',
        'https://relay.lmmini.com/s/abc1234/v1/models',
        'http://relay.lmmini.com/s/abc123/v1/models',
        'https://relay.lmmini.com.evil.io/s/abc123/v1/models',
        'http://192.168.1.20:1234/v1/models',
      ]) {
        expect(lanUriForRelayRequest(Uri.parse(other), relay, lan), isNull,
            reason: other);
      }
      expect(lanUriForRelayRequest(Uri.parse(relay), null, lan), isNull);
    });
  });
}
