import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';

import '../models/chat_message.dart';
import 'llm_endpoint.dart';

/// Why Apple Intelligence can't run here (from the native bridge).
enum AppleIntelligenceStatus {
  available,
  deviceNotEligible,
  appleIntelligenceNotEnabled,
  modelNotReady,
  unsupportedOS,
  unavailable;

  static AppleIntelligenceStatus parse(Object? raw) {
    if (raw is Map && raw['available'] == true) return available;
    final reason = raw is Map ? raw['reason']?.toString() : null;
    return values.firstWhere(
      (v) => v.name == reason,
      orElse: () => unavailable,
    );
  }
}

/// Adapter for Apple's on-device foundation model (Apple Intelligence /
/// `FoundationModels` framework, iOS 26+ / macOS 26+).
///
/// **Native bridge:** like [OnDeviceMlxEndpoint], this Dart class talks to
/// `AppleIntelligenceBridge.swift` (ios/Runner, macos/Runner) through
/// `lm_mini/apple_ai` (methods) and `lm_mini/apple_ai/stream` (reply deltas).
/// [status] reports why the model can't run (old OS, device, setting off).
///
/// Differences vs. the other on-device endpoints:
///   - No download, no model picker — Apple ships and updates the model.
///   - Always free (Apple-provided) and always small (~3B params).
///   - Tool calling is supported via Apple's `Tool` protocol; we expose
///     `supportsToolCalls = true` and let the bridge translate.
///   - Vision is supported on iOS 26+ device-class hardware.
class AppleIntelligenceEndpoint implements LLMEndpoint {
  static const MethodChannel _channel = MethodChannel('lm_mini/apple_ai');
  static const EventChannel _stream = EventChannel('lm_mini/apple_ai/stream');

  AppleIntelligenceEndpoint();

  @override
  String get id => 'apple_intelligence';

  @override
  EndpointKind get kind => EndpointKind.appleIntelligence;

  @override
  String get displayName => 'Apple Intelligence';

  @override
  EndpointTier get tier => EndpointTier.free;

  @override
  EndpointCapabilities get capabilities => const EndpointCapabilities(
        supportsToolCalls: true,
        supportsVision: true,
        supportsStreaming: true,
        isMetered: false,
      );

  /// Asks the OS (FoundationModels) directly — the only reliable answer:
  /// it knows the device, the OS, whether Apple Intelligence is on and
  /// whether the model has finished downloading.
  static Future<AppleIntelligenceStatus> status() async {
    if (!Platform.isIOS && !Platform.isMacOS) {
      return AppleIntelligenceStatus.deviceNotEligible;
    }
    try {
      return AppleIntelligenceStatus.parse(
        await _channel.invokeMethod<Object?>('availability'),
      );
    } on MissingPluginException {
      return AppleIntelligenceStatus.unavailable;
    } catch (_) {
      return AppleIntelligenceStatus.unavailable;
    }
  }

  @override
  Future<bool> isAvailable() async =>
      await status() == AppleIntelligenceStatus.available;

  /// Stops the reply that is being generated (Stop button).
  static void cancelActive() {
    _channel.invokeMethod('cancel').catchError((_) {});
  }

  /// The system model's context window is ~4,096 tokens. Keep the prompt
  /// (history + new message) well under it, leaving room for the reply.
  static const int contextTokens = 4096;

  static int _estimateTokens(String s) => (s.length / 4).ceil();

  /// Builds the single prompt sent to the model: as much recent history as
  /// fits, then the new message. Instructions (persona / system prompt) are
  /// sent separately so the model treats them as instructions.
  static String buildPrompt({
    required List<ChatMessage> history,
    required String userMessage,
    required int budgetTokens,
  }) {
    // The chat passes the current user bubble as the last history entry
    // too (same as the GGUF path): drop it so it isn't sent twice.
    final prior = List<ChatMessage>.from(history);
    if (prior.isNotEmpty && prior.last.role == 'user') prior.removeLast();

    final turns = <String>[];
    var used = _estimateTokens(userMessage);
    for (final m in prior.reversed) {
      if (m.id.startsWith('temp_')) continue;
      if (m.role != 'user' && m.role != 'assistant') continue;
      final text = m.content.trim();
      if (text.isEmpty) continue;
      final line = '${m.role == 'user' ? 'User' : 'Assistant'}: $text';
      final cost = _estimateTokens(line);
      if (used + cost > budgetTokens) break;
      used += cost;
      turns.insert(0, line);
    }
    if (turns.isEmpty) return userMessage;
    return 'Conversation so far:\n${turns.join('\n\n')}\n\n'
        'Reply to the latest message from the user:\n$userMessage';
  }

  /// Multi-turn chat on the system model (used by the on-device engine).
  Stream<String> streamChat({
    required List<ChatMessage> history,
    required String userMessage,
    String? systemPrompt,
    String? memoryContext,
    int maxTokens = 1024,
    double temperature = 0.7,
  }) {
    final instructions = [
      if (systemPrompt != null && systemPrompt.trim().isNotEmpty)
        systemPrompt.trim(),
      if (memoryContext != null && memoryContext.trim().isNotEmpty)
        memoryContext.trim(),
    ].join('\n\n');
    final reply = maxTokens.clamp(128, 1024);
    final budget = contextTokens - reply - _estimateTokens(instructions) - 64;
    final prompt = buildPrompt(
      history: history,
      userMessage: userMessage,
      budgetTokens: budget < 256 ? 256 : budget,
    );
    return _streamFor(prompt, instructions, reply, temperature);
  }

  @override
  Future<List<EndpointModelInfo>> listModels() async => const [
        EndpointModelInfo(
          id: 'apple-intelligence-default',
          displayName: 'Apple Intelligence (system model)',
          supportsTools: true,
          supportsVision: true,
        ),
      ];

  /// Streams generated tokens from FoundationModels' `LanguageModelSession`.
  /// The Swift bridge sends `null` to signal completion.
  Stream<String> streamCompletion({
    required String prompt,
    int maxTokens = 1024,
    double temperature = 0.7,
  }) =>
      _streamFor(prompt, '', maxTokens, temperature);

  Stream<String> _streamFor(
    String prompt,
    String instructions,
    int maxTokens,
    double temperature,
  ) {
    final controller = StreamController<String>();
    StreamSubscription? sub;
    () async {
      try {
        sub = _stream.receiveBroadcastStream({
          'prompt': prompt,
          if (instructions.isNotEmpty) 'instructions': instructions,
          'maxTokens': maxTokens,
          'temperature': temperature,
        }).listen(
          (event) {
            if (event == null) {
              controller.close();
              return;
            }
            if (event is String) controller.add(event);
          },
          onError: (Object e) => controller.addError(
            e is PlatformException ? StateError(e.message ?? e.code) : e,
          ),
          onDone: controller.close,
          cancelOnError: true,
        );
      } catch (e) {
        controller.addError(e);
        await controller.close();
      }
    }();
    controller.onCancel = () async {
      await sub?.cancel();
      try {
        await _channel.invokeMethod('cancel');
      } on MissingPluginException {
        // bridge not installed
      }
    };
    return controller.stream;
  }
}
