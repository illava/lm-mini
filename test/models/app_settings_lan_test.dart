import 'package:flutter_test/flutter_test.dart';
import 'package:lm_mini/models/app_settings.dart';

void main() {
  test('remote LAN fields persist and old JSON loads without them', () {
    final s = AppSettings(
      remoteLanUrls: const ['https://192.168.1.20:8743'],
      remoteLanFingerprint: 'a' * 64,
    );
    final back = AppSettings.fromJson(s.toJson());
    expect(back.remoteLanUrls, ['https://192.168.1.20:8743']);
    expect(back.remoteLanFingerprint, 'a' * 64);

    final json = s.toJson()
      ..remove('remoteLanUrls')
      ..remove('remoteLanFingerprint');
    final old = AppSettings.fromJson(json);
    expect(old.remoteLanUrls, isEmpty);
    expect(old.remoteLanFingerprint, isNull);

    final cleared = back.copyWith(remoteLanFingerprint: null);
    expect(cleared.remoteLanFingerprint, isNull);
    expect(cleared.remoteLanUrls, ['https://192.168.1.20:8743']);
  });
}
