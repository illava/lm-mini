import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
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
    _live = null;
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

  /// What the native chat session has seen: its key, instructions, every
  /// turn (normalized text) and a token estimate. Lets the next message be
  /// sent alone instead of re-sending the history.
  static _AppleChatSession? _live;

  static String _turnKey(String role, String text) =>
      '$role:${text.trim().replaceAll(RegExp(r'\s+'), ' ')}';

  /// History as the session would have seen it (user/assistant, no temp).
  static List<String> _signature(List<ChatMessage> history) {
    final prior = List<ChatMessage>.from(history);
    if (prior.isNotEmpty && prior.last.role == 'user') prior.removeLast();
    return [
      for (final m in prior)
        if (!m.id.startsWith('temp_') &&
            (m.role == 'user' || m.role == 'assistant') &&
            m.content.trim().isNotEmpty)
          _turnKey(m.role, m.content),
    ];
  }

  /// True when [sessionKey]'s live session already holds exactly [history]
  /// with these [instructions] and has room for the next turn.
  @visibleForTesting
  static bool canContinue({
    required String? sessionKey,
    required List<ChatMessage> history,
    required String instructions,
    required String userMessage,
    required int replyTokens,
  }) {
    final live = _live;
    if (sessionKey == null || live == null) return false;
    if (live.key != sessionKey || live.instructions != instructions) {
      return false;
    }
    final sig = _signature(history);
    if (sig.length != live.turns.length) return false;
    for (var i = 0; i < sig.length; i++) {
      if (sig[i] != live.turns[i]) return false;
    }
    // Leave headroom: past this, rebuild from packed recent history.
    return live.tokens + _estimateTokens(userMessage) + replyTokens <
        contextTokens - 256;
  }

  /// Forget the chat session (both sides).
  static void resetSession() {
    _live = null;
    _channel.invokeMethod('resetSession').catchError((_) {});
  }

  @visibleForTesting
  static void debugSetLive(
    String key,
    String instructions,
    List<String> turns,
    int tokens,
  ) =>
      _live = _AppleChatSession(key, instructions, turns, tokens);

  @visibleForTesting
  static List<String> debugSignature(List<ChatMessage> history) =>
      _signature(history);

  static DateTime? _lastPrewarm;

  /// Load the model ahead of a request (call when the user starts typing).
  /// Cheap and throttled; a no-op off Apple platforms.
  static void prewarm({String? sessionKey}) {
    if (kIsWeb || !(Platform.isIOS || Platform.isMacOS)) return;
    final now = DateTime.now();
    if (_lastPrewarm != null &&
        now.difference(_lastPrewarm!) < const Duration(seconds: 30)) {
      return;
    }
    _lastPrewarm = now;
    _channel.invokeMethod('prewarm', {
      if (sessionKey != null) 'sessionKey': sessionKey,
    }).catchError((_) {});
  }

  /// Multi-turn chat on the system model (used by the on-device engine).
  /// With [sessionKey] (the conversation id), the session is kept between
  /// messages: if it already holds this exact history, only the new message
  /// is sent. Edits, regenerations, Stop, a changed system prompt or a full
  /// context window start a fresh session from the packed recent history.
  Stream<String> streamChat({
    required List<ChatMessage> history,
    required String userMessage,
    String? systemPrompt,
    String? memoryContext,
    int maxTokens = 1024,
    double temperature = 0.7,
    String? sessionKey,
  }) async* {
    final instructions = [
      if (systemPrompt != null && systemPrompt.trim().isNotEmpty)
        systemPrompt.trim(),
      if (memoryContext != null && memoryContext.trim().isNotEmpty)
        memoryContext.trim(),
    ].join('\n\n');
    final reply = maxTokens.clamp(128, 1024);
    final sig = _signature(history);

    void remember(int promptTokens, String answer) {
      if (sessionKey == null) return;
      final base = _live != null &&
              _live!.key == sessionKey &&
              promptTokens == _estimateTokens(userMessage)
          ? _live!
          : _AppleChatSession(
              sessionKey, instructions, const [], _estimateTokens(instructions));
      _live = _AppleChatSession(
        sessionKey,
        instructions,
        [
          ...sig,
          _turnKey('user', userMessage),
          _turnKey('assistant', answer),
        ],
        base.tokens + promptTokens + _estimateTokens(answer),
      );
    }

    if (canContinue(
      sessionKey: sessionKey,
      history: history,
      instructions: instructions,
      userMessage: userMessage,
      replyTokens: reply,
    )) {
      final answer = StringBuffer();
      try {
        await for (final d in _streamFor(
            userMessage, instructions, reply, temperature,
            sessionKey: sessionKey, continuing: true)) {
          answer.write(d);
          yield d;
        }
        remember(_estimateTokens(userMessage), answer.toString());
        return;
      } on _AppleSessionUnusable {
        // Window full or session gone: rebuild below (nothing was shown).
        if (answer.isNotEmpty) rethrow;
      }
    }

    // Fresh session from the packed recent history.
    _live = null;
    final budget = contextTokens - reply - _estimateTokens(instructions) - 64;
    final prompt = buildPrompt(
      history: history,
      userMessage: userMessage,
      budgetTokens: budget < 256 ? 256 : budget,
    );
    final answer = StringBuffer();
    try {
      await for (final d in _streamFor(
          prompt, instructions, reply, temperature,
          sessionKey: sessionKey)) {
        answer.write(d);
        yield d;
      }
    } on _AppleSessionUnusable catch (e) {
      throw StateError(e.message);
    }
    remember(_estimateTokens(prompt), answer.toString());
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
    double temperature, {
    String? sessionKey,
    bool continuing = false,
  }) {
    final controller = StreamController<String>();
    StreamSubscription? sub;
    var finished = false;
    () async {
      try {
        sub = _stream.receiveBroadcastStream({
          'prompt': prompt,
          if (instructions.isNotEmpty) 'instructions': instructions,
          'maxTokens': maxTokens,
          'temperature': temperature,
          if (sessionKey != null) 'sessionKey': sessionKey,
          'mode': continuing ? 'continue' : 'fresh',
        }).listen(
          (event) {
            if (event == null) {
              finished = true;
              controller.close();
              return;
            }
            if (event is String) controller.add(event);
          },
          onError: (Object e) {
            finished = true;
            _live = null;
            if (e is PlatformException &&
                (e.code == 'apple_ai_context' ||
                    e.code == 'apple_ai_session_lost')) {
              controller.addError(_AppleSessionUnusable(e.message ?? e.code));
            } else {
              controller.addError(
                e is PlatformException ? StateError(e.message ?? e.code) : e,
              );
            }
            controller.close();
          },
          onDone: () {
            finished = true;
            controller.close();
          },
          cancelOnError: true,
        );
      } catch (e) {
        finished = true;
        controller.addError(e);
        await controller.close();
      }
    }();
    controller.onCancel = () async {
      await sub?.cancel();
      // Only a reply abandoned mid-way stops the model (and its session).
      if (finished) return;
      _live = null;
      try {
        await _channel.invokeMethod('cancel');
      } on MissingPluginException {
        // bridge not installed
      }
    };
    return controller.stream;
  }
}

class _AppleChatSession {
  final String key;
  final String instructions;
  final List<String> turns;
  final int tokens;
  const _AppleChatSession(this.key, this.instructions, this.turns, this.tokens);
}

/// The native session can't take this turn (context full / gone).
class _AppleSessionUnusable implements Exception {
  final String message;
  const _AppleSessionUnusable(this.message);
}
