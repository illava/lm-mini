import '../models/app_settings.dart';
import 'package:lm_mini_premium/lm_mini_premium.dart';

/// Frozen copy of the active chat backend for iOS Siri / App Intents.
///
/// Native Swift reads this from the App Group and, when [eligible], POSTs a
/// one-shot OpenAI-compatible completion without launching Flutter. On-device
/// GGUF/MLX, USB, Apple Intelligence, and loopback URLs stay on the Dart path.
class SiriInferenceSnapshot {
  static const appGroupId = 'group.net.neuro9.lmmini';
  static const defaultsKey = 'siriInferenceSnapshot';

  static const hopByHopHeaders = {
    'content-length',
    'transfer-encoding',
    'host',
    'connection',
    'expect',
  };

  final bool eligible;
  final String providerKind;
  final String? chatUrl;
  final String? model;
  final Map<String, String> headers;
  final double temperature;
  final int maxTokens;
  final String? ineligibleReason;

  /// LM Studio's own chat API (`/api/v1/chat`). Set only when the user's MCP
  /// tools are on: the OpenAI-compatible [chatUrl] can't run MCP tools, so a
  /// Shortcut asking for news or weather had no web search.
  final String? toolsChatUrl;

  /// MCP tools for [toolsChatUrl], in LM Studio's `integrations` format
  /// (same list in-app chat sends, without Pro Search).
  final List<Map<String, dynamic>> integrations;

  const SiriInferenceSnapshot({
    required this.eligible,
    required this.providerKind,
    this.chatUrl,
    this.model,
    this.headers = const {},
    this.temperature = 0.7,
    this.maxTokens = 512,
    this.ineligibleReason,
    this.toolsChatUrl,
    this.integrations = const [],
  });

  /// The user's MCP tools as LM Studio `integrations`, matching in-app chat:
  /// LM Studio-configured (mcp.json) tools first, then URL tools, skipping a
  /// URL tool that has the same name as a configured one.
  static List<Map<String, dynamic>> mcpIntegrations(AppSettings settings) {
    if (!settings.enableToolUse) return const [];
    final integrated = settings.activeIntegratedMcps;
    final names = integrated.map((m) => m.name).toSet();
    return [
      for (final m in integrated) m.toApiFormat(),
      for (final s in settings.activeMcpServers)
        if (!names.contains(s.label)) s.toApiFormat(),
    ];
  }

  factory SiriInferenceSnapshot.from({
    required AppSettings settings,
    CloudApiProvider? cloud,
    bool forceOnDevice = false,
  }) {
    final kind = forceOnDevice
        ? (settings.activeProviderKind == 'onDeviceMlx'
            ? 'onDeviceMlx'
            : 'onDeviceGguf')
        : settings.activeProviderKind;

    if (forceOnDevice ||
        kind == 'onDeviceGguf' ||
        kind == 'onDeviceMlx' ||
        kind == 'appleIntelligence') {
      return SiriInferenceSnapshot(
        eligible: false,
        providerKind: kind,
        ineligibleReason: 'on-device',
      );
    }

    // USB and Ollama still get a chatUrl so the in-app Dart wait path can
    // POST. Native Siri HTTP skips them (`eligible: false`): USB is
    // loopback, Ollama's primary API is `/api/chat`.

    final headers = <String, String>{
      'Content-Type': 'application/json',
      'Accept': 'application/json',
    };

    String? chatUrl;
    String? toolsChatUrl;
    var integrations = const <Map<String, dynamic>>[];
    String? model = settings.selectedModel?.trim();

    if (cloud != null &&
        (kind == 'cloud' ||
            kind == 'omlx' ||
            kind == 'jan' ||
            CloudApiType.isFreeLocalKind(kind))) {
      chatUrl = _joinUrl(cloud.effectiveBaseUrl, cloud.type.chatPath);
      model = (cloud.selectedModel ?? model)?.trim();
      headers.addAll(cloud.type.extraHeaders);
      final key = cloud.apiKey.trim();
      if (key.isNotEmpty) {
        headers['Authorization'] = 'Bearer $key';
      }
      if (cloud.customHeadersEnabled && cloud.customHeaders != null) {
        _mergeHeaders(headers, cloud.customHeaders!);
      }
    } else {
      final base = settings.serverUrl.trim();
      if (base.isEmpty) {
        return SiriInferenceSnapshot(
          eligible: false,
          providerKind: kind,
          ineligibleReason: 'no-url',
        );
      }
      chatUrl = _joinUrl(base, '/v1/chat/completions');
      // MCP tools only run through LM Studio's own API (not Home's
      // llama-server or the USB bridge).
      if (kind == 'lmStudio' && !settings.usbModeEnabled) {
        integrations = mcpIntegrations(settings);
        if (integrations.isNotEmpty) {
          toolsChatUrl = _joinUrl(base, '/api/v1/chat');
        }
      }
      final token = settings.apiToken?.trim();
      if (token != null && token.isNotEmpty) {
        headers['Authorization'] = 'Bearer $token';
      }
      final extra = settings.effectiveExtraHeaders;
      if (extra != null) _mergeHeaders(headers, extra);
    }

    // Relay token + routing only for requests to the paired relay URL —
    // never to a cloud API or LAN host.
    if (settings.isActiveRelayUrl(chatUrl)) {
      final relay = settings.remoteAuthToken?.trim();
      if (relay != null && relay.isNotEmpty) {
        headers['X-LM-Mini-Token'] = relay;
        if (cloud?.type == CloudApiType.omlx) {
          headers['X-LM-Mini-Backend'] = 'omlx';
        } else if (cloud?.type == CloudApiType.ollama) {
          headers['X-LM-Mini-Backend'] = 'ollama';
        } else if (cloud?.type == CloudApiType.jan) {
          headers['X-LM-Mini-Backend'] = 'jan';
        } else if (cloud?.type == CloudApiType.unsloth) {
          headers['X-LM-Mini-Backend'] = 'unsloth';
        } else {
          headers['X-LM-Mini-Backend'] =
              headers['X-LM-Mini-Backend'] ?? 'lmStudio';
        }
      }
    }

    final host = Uri.tryParse(chatUrl ?? '')?.host;
    if (isLoopbackHost(host)) {
      return SiriInferenceSnapshot(
        eligible: false,
        providerKind: kind,
        chatUrl: chatUrl,
        model: model,
        headers: Map.unmodifiable(headers),
        temperature: settings.temperature,
        maxTokens: settings.maxTokens,
        ineligibleReason: 'loopback',
      );
    }

    if (chatUrl.isEmpty) {
      return SiriInferenceSnapshot(
        eligible: false,
        providerKind: kind,
        ineligibleReason: 'no-url',
      );
    }

    if (model == null || model.isEmpty) {
      return SiriInferenceSnapshot(
        eligible: false,
        providerKind: kind,
        chatUrl: chatUrl,
        headers: Map.unmodifiable(headers),
        ineligibleReason: 'no-model',
      );
    }

    final maxTokens = settings.maxTokens.clamp(64, 1024);
    return SiriInferenceSnapshot(
      eligible: true,
      providerKind: kind,
      chatUrl: chatUrl,
      model: model,
      headers: Map.unmodifiable(headers),
      temperature: settings.temperature,
      maxTokens: maxTokens,
      toolsChatUrl: toolsChatUrl,
      integrations: integrations,
    );
  }

  bool get usesTools => toolsChatUrl != null && integrations.isNotEmpty;

  Map<String, dynamic> toMap() => {
        'eligible': eligible,
        'providerKind': providerKind,
        'chatUrl': chatUrl,
        'model': model,
        'headers': headers,
        'temperature': temperature,
        'maxTokens': maxTokens,
        'ineligibleReason': ineligibleReason,
        if (toolsChatUrl != null) 'toolsChatUrl': toolsChatUrl,
        if (integrations.isNotEmpty) 'integrations': integrations,
      };

  factory SiriInferenceSnapshot.fromMap(Map<String, dynamic> map) {
    final rawHeaders = map['headers'];
    final headers = <String, String>{};
    if (rawHeaders is Map) {
      for (final entry in rawHeaders.entries) {
        headers['${entry.key}'] = '${entry.value}';
      }
    }
    return SiriInferenceSnapshot(
      eligible: map['eligible'] == true,
      providerKind: (map['providerKind'] as String?) ?? 'lmStudio',
      chatUrl: map['chatUrl'] as String?,
      model: map['model'] as String?,
      headers: Map.unmodifiable(headers),
      temperature: (map['temperature'] as num?)?.toDouble() ?? 0.7,
      maxTokens: (map['maxTokens'] as num?)?.toInt() ?? 512,
      ineligibleReason: map['ineligibleReason'] as String?,
      toolsChatUrl: map['toolsChatUrl'] as String?,
      integrations: [
        for (final e in (map['integrations'] as List?) ?? const [])
          if (e is Map) Map<String, dynamic>.from(e),
      ],
    );
  }

  static bool isLoopbackHost(String? host) {
    if (host == null || host.isEmpty) return true;
    final h = host.toLowerCase();
    if (h == 'localhost' ||
        h == '127.0.0.1' ||
        h == '0.0.0.0' ||
        h == '::1' ||
        h == '[::1]') {
      return true;
    }
    return h.endsWith('.localhost');
  }

  static String joinUrl(String base, String path) => _joinUrl(base, path);

  static String _joinUrl(String base, String path) {
    var b = base.trim();
    while (b.endsWith('/')) {
      b = b.substring(0, b.length - 1);
    }
    final p = path.startsWith('/') ? path : '/$path';
    return '$b$p';
  }

  static void _mergeHeaders(
    Map<String, String> into,
    Map<String, String> extra,
  ) {
    extra.forEach((key, value) {
      final trimmed = key.trim();
      if (trimmed.isEmpty) return;
      if (hopByHopHeaders.contains(trimmed.toLowerCase())) return;
      into[trimmed] = value;
    });
  }
}
