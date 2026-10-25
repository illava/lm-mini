import 'package:flutter_test/flutter_test.dart';
import 'package:lm_mini/services/remote_connection_info.dart';

void main() {
  test('Macs reporting host 2.0.0 (LM Mini 1.9.8) get the update hint', () {
    expect(ConnectCompatibility.homeHostOutdated('2.0.0'), isTrue);
    expect(ConnectCompatibility.homeHostOutdated('2.1.0'), isFalse);
    expect(ConnectCompatibility.homeHostOutdated(null), isFalse);
  });

  test('the pairing link carries the host version when present', () {
    final info = RemoteRelayHttp.parseRelayUrl(
        'https://relay.lmmini.com/s/abc#t=tok&b=lmMiniDesktop&hv=2.1.0');
    expect(info?.connectVersion, '2.1.0');
    final old = RemoteRelayHttp.parseRelayUrl(
        'https://relay.lmmini.com/s/abc#t=tok&b=lmMiniDesktop');
    expect(old?.connectVersion, isNull);
  });
}
