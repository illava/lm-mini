import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:local_auth/local_auth.dart';
import 'package:lm_mini/utils/biometric_label.dart';

void main() {
  test('Apple devices: Face ID or Touch ID', () {
    expect(BiometricLabel.fromTypes([BiometricType.face], TargetPlatform.iOS),
        BiometricMethod.faceId);
    expect(
        BiometricLabel.fromTypes(
            [BiometricType.fingerprint], TargetPlatform.iOS),
        BiometricMethod.touchId);
    expect(BiometricLabel.fromTypes([], TargetPlatform.macOS),
        BiometricMethod.touchId);
  });

  test('Android: face unlock or fingerprint (strong/weak → fingerprint)', () {
    expect(
        BiometricLabel.fromTypes([BiometricType.face], TargetPlatform.android),
        BiometricMethod.faceUnlock);
    expect(
        BiometricLabel.fromTypes(
            [BiometricType.strong, BiometricType.weak],
            TargetPlatform.android),
        BiometricMethod.fingerprint);
  });
}
