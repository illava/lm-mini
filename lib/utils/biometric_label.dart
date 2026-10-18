import 'package:flutter/foundation.dart';
import 'package:local_auth/local_auth.dart';

import '../l10n/app_localizations.dart';

/// Which biometric this device unlocks with, for user-facing copy
/// ("Require Face ID or a PIN…"). Detected once; until then (or if
/// detection fails) the platform's usual method is assumed.
enum BiometricMethod { faceId, touchId, fingerprint, faceUnlock }

abstract final class BiometricLabel {
  static BiometricMethod? _detected;

  static BiometricMethod get current => _detected ?? _platformDefault();

  static BiometricMethod _platformDefault() {
    switch (defaultTargetPlatform) {
      case TargetPlatform.iOS:
        return BiometricMethod.faceId;
      case TargetPlatform.macOS:
        return BiometricMethod.touchId;
      default:
        return BiometricMethod.fingerprint;
    }
  }

  /// Maps the plugin's reported types to a method (pure, for tests).
  static BiometricMethod fromTypes(
    List<BiometricType> types,
    TargetPlatform platform,
  ) {
    final apple =
        platform == TargetPlatform.iOS || platform == TargetPlatform.macOS;
    if (types.contains(BiometricType.face)) {
      return apple ? BiometricMethod.faceId : BiometricMethod.faceUnlock;
    }
    if (types.contains(BiometricType.fingerprint)) {
      return apple ? BiometricMethod.touchId : BiometricMethod.fingerprint;
    }
    // Android often reports only strong / weak.
    if (platform == TargetPlatform.iOS) return BiometricMethod.faceId;
    if (platform == TargetPlatform.macOS) return BiometricMethod.touchId;
    return BiometricMethod.fingerprint;
  }

  static Future<BiometricMethod> load() async {
    if (_detected != null) return _detected!;
    try {
      final types = await LocalAuthentication().getAvailableBiometrics();
      _detected = fromTypes(types, defaultTargetPlatform);
    } catch (_) {
      _detected = _platformDefault();
    }
    return _detected!;
  }

  static String text(AppLocalizations l10n, [BiometricMethod? method]) {
    switch (method ?? current) {
      case BiometricMethod.faceId:
        return l10n.biometricFaceId;
      case BiometricMethod.touchId:
        return l10n.biometricTouchId;
      case BiometricMethod.faceUnlock:
        return l10n.biometricFaceUnlock;
      case BiometricMethod.fingerprint:
        return l10n.biometricFingerprint;
    }
  }
}
