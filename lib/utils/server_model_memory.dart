import '../models/app_settings.dart';

/// Last-used chat model is stored per server slot so switching backends
/// does not keep another server's model id in [AppSettings.selectedModel].
class ServerModelMemory {
  ServerModelMemory._();

  /// [cloudProviderId] is the active Ollama / oMLX / JAN / Unsloth / cloud
  /// provider: each one remembers its own model (two Ollama servers, or
  /// OpenAI vs Mistral, must not share a slot).
  static String keyFor(AppSettings settings, {String? cloudProviderId}) => key(
        providerKind: settings.activeProviderKind,
        isRemoteActive: settings.isRemoteActive,
        usbModeEnabled: settings.usbModeEnabled,
        serverUrl: settings.serverUrl,
        cloudProviderId: cloudProviderId,
      );

  /// Stable slot id. Remote backends share the relay URL, so they key by
  /// kind (`remote:lmMiniDesktop` vs `remote:lmStudio`), not URL.
  static String key({
    required String providerKind,
    required bool isRemoteActive,
    required bool usbModeEnabled,
    required String serverUrl,
    String? cloudProviderId,
  }) {
    if (providerKind == 'onDeviceGguf' ||
        providerKind == 'onDeviceMlx' ||
        providerKind == 'appleIntelligence') {
      return 'onDevice:$providerKind';
    }
    if (isRemoteActive) {
      final remoteKind = (providerKind == 'ollama' ||
              providerKind == 'omlx' ||
              providerKind == 'lmMiniDesktop')
          ? providerKind
          : 'lmStudio';
      return 'remote:$remoteKind';
    }
    if (usbModeEnabled) return 'usb:lmStudio';
    if (providerKind == 'ollama' ||
        providerKind == 'omlx' ||
        providerKind == 'jan' ||
        providerKind == 'unsloth' ||
        providerKind == 'cloud') {
      final id = cloudProviderId?.trim() ?? '';
      return id.isEmpty ? 'cloud:$providerKind' : 'cloud:$providerKind:$id';
    }
    final url = serverUrl.trim();
    return 'local:${url.isEmpty ? 'lmStudio' : url}';
  }

  /// Prefer the remembered id when it is in the new catalog. Never keep a
  /// current id that belongs to another server's catalog.
  static String? pick({
    required String? remembered,
    required String? current,
    required Iterable<String> availableIds,
  }) {
    final ids = availableIds.toSet();
    if (ids.isEmpty) return remembered;
    if (remembered != null &&
        remembered.isNotEmpty &&
        ids.contains(remembered)) {
      return remembered;
    }
    if (current != null && current.isNotEmpty && ids.contains(current)) {
      return current;
    }
    return null;
  }
}
