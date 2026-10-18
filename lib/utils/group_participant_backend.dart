import '../models/local_model_spec.dart';
import '../services/local_model_catalog.dart';
import '../services/local_model_download_service.dart';

/// Resolve which backend a group-chat participant should use.
///
/// Stored [providerKind] wins. If it was never written (legacy / add-persona),
/// infer from the persona default, a bound cloud provider, or the model id
/// against on-device / LM Studio catalogs — not "whatever Settings is on now".
abstract final class GroupParticipantBackend {
  static const knownKinds = <String>{
    'lmStudio',
    'lmMiniDesktop',
    'onDeviceGguf',
    'onDeviceMlx',
    'cloud',
    'omlx',
    'ollama',
    'jan',
    'unsloth',
    'appleIntelligence',
  };

  static bool isKnown(String? kind) =>
      kind != null && kind.isNotEmpty && knownKinds.contains(kind);

  static LocalModelSpec? localSpec(String id) {
    if (id.isEmpty) return null;
    final catalog = LocalModelCatalog.byId(id);
    if (catalog != null) return catalog;
    for (final entry in LocalModelDownloadService.instance.readyEntries) {
      if (entry.spec.id == id) return entry.spec;
    }
    return null;
  }

  static bool isLocalMlxId(String id) =>
      localSpec(id)?.engine == LocalEngine.mlx;

  static bool isLocalGgufId(String id) =>
      localSpec(id)?.engine == LocalEngine.fllama;

  static String resolve({
    String? storedKind,
    String? personaKind,
    String? cloudProviderKind,
    String? modelId,
    String? globalKind,
    bool Function(String id)? isLocalMlx,
    bool Function(String id)? isLocalGguf,
    bool Function(String id)? isLmStudioModel,
  }) {
    if (isKnown(storedKind)) return storedKind!;
    if (isKnown(personaKind)) return personaKind!;
    if (isKnown(cloudProviderKind)) return cloudProviderKind!;

    final id = (modelId ?? '').trim();
    if (id.isNotEmpty) {
      if (isLocalMlx?.call(id) == true) return 'onDeviceMlx';
      if (isLocalGguf?.call(id) == true) return 'onDeviceGguf';
      if (isLmStudioModel?.call(id) == true) return 'lmStudio';
    }

    if (isKnown(globalKind)) return globalKind!;
    return 'lmStudio';
  }

  /// Setup-screen check for a non-cloud participant. Returns the problem to
  /// show, or null when it can chat. Cloud providers are checked by the
  /// caller (they need the provider list and Pro state).
  ///
  /// * [readyLocalEngine]: engine of a downloaded on-device model, or null.
  /// * [lmStudioModelKnown] / [homeModelKnown]: null when the catalog is not
  ///   loaded (then any non-empty id is accepted, like 1:1 chat).
  /// * [appleIntelligenceAvailable]: null while the OS check is pending.
  static String? configError({
    required String kind,
    required String displayName,
    required String modelId,
    LocalEngine? Function(String id)? readyLocalEngine,
    bool Function(String id)? lmStudioModelKnown,
    bool Function(String id)? homeModelKnown,
    bool? appleIntelligenceAvailable,
  }) {
    switch (kind) {
      case 'onDeviceGguf':
      case 'onDeviceMlx':
        if (modelId.isEmpty) return '$displayName: pick an on-device model.';
        final engine = readyLocalEngine?.call(modelId);
        if (engine == null) {
          return '$displayName: on-device model is not downloaded.';
        }
        final expected =
            kind == 'onDeviceMlx' ? LocalEngine.mlx : LocalEngine.fllama;
        if (engine != expected) {
          return '$displayName: model engine does not match provider.';
        }
        return null;
      case 'lmStudio':
        if (modelId.isEmpty) return '$displayName: pick an LM Studio model.';
        if (lmStudioModelKnown != null && !lmStudioModelKnown(modelId)) {
          return '$displayName: model not available on LM Studio.';
        }
        return null;
      case 'lmMiniDesktop':
        if (modelId.isEmpty) return '$displayName: pick a model on Home.';
        if (homeModelKnown != null && !homeModelKnown(modelId)) {
          return '$displayName: model not available on Home.';
        }
        return null;
      case 'appleIntelligence':
        if (appleIntelligenceAvailable == false) {
          return '$displayName: Apple Intelligence is not available on this device.';
        }
        return null;
      default:
        return '$displayName: unknown provider. Pick provider & model again.';
    }
  }
}
