// AppleIntelligenceBridge.swift
//
// Bridge between Flutter (lib/services/apple_intelligence_endpoint.dart) and
// Apple's on-device model (FoundationModels, iOS 26+ / macOS 26+). The model
// ships with the OS — no download. Same file in ios/Runner and macos/Runner.
//
//   • MethodChannel("lm_mini/apple_ai")
//       availability → {available: Bool, reason: String?}
//       isAvailable  → Bool
//       cancel       → stops the running reply (and drops the chat session)
//       prewarm      {sessionKey?} → load the model ahead of a request
//       resetSession → forget the chat session
//   • EventChannel ("lm_mini/apple_ai/stream")
//       args {prompt, instructions?, maxTokens, temperature,
//             sessionKey?, mode: "fresh" | "continue"}
//       events: text deltas (String), then end of stream; errors as
//       FlutterError(code: "apple_ai_*", message: user-facing text).
//
// Sessions: one LanguageModelSession is kept for the open chat
// (sessionKey). "continue" sends only the new message on it, so the model
// doesn't re-read the history every turn; "fresh" starts a new session
// from the packed history. No sessionKey = a one-off session (titles).

#if os(iOS)
import Flutter
#else
import FlutterMacOS
#endif
import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

final class AppleIntelligenceBridge: NSObject {
  private let methodChannel: FlutterMethodChannel
  private let eventChannel: FlutterEventChannel
  private let streamHandler = AppleIntelligenceStreamHandler()

  init(messenger: FlutterBinaryMessenger) {
    methodChannel = FlutterMethodChannel(
      name: "lm_mini/apple_ai", binaryMessenger: messenger)
    eventChannel = FlutterEventChannel(
      name: "lm_mini/apple_ai/stream", binaryMessenger: messenger)
    super.init()
    eventChannel.setStreamHandler(streamHandler)
    methodChannel.setMethodCallHandler { [weak self] call, result in
      self?.handle(call: call, result: result)
    }
  }

  private func handle(call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "availability":
      result(Self.availability())
    case "isAvailable":
      result(Self.availability()["available"] as? Bool ?? false)
    case "cancel":
      streamHandler.cancel()
      result(nil)
    case "prewarm":
      let args = call.arguments as? [String: Any] ?? [:]
      streamHandler.prewarm(sessionKey: args["sessionKey"] as? String)
      result(nil)
    case "resetSession":
      streamHandler.resetSession()
      result(nil)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  static func availability() -> [String: Any] {
    #if canImport(FoundationModels)
    if #available(iOS 26.0, macOS 26.0, *) {
      switch SystemLanguageModel.default.availability {
      case .available:
        return ["available": true]
      case .unavailable(let reason):
        let code: String
        switch reason {
        case .deviceNotEligible: code = "deviceNotEligible"
        case .appleIntelligenceNotEnabled: code = "appleIntelligenceNotEnabled"
        case .modelNotReady: code = "modelNotReady"
        @unknown default: code = "unavailable"
        }
        return ["available": false, "reason": code]
      }
    }
    return ["available": false, "reason": "unsupportedOS"]
    #else
    return ["available": false, "reason": "notBundled"]
    #endif
  }
}

final class AppleIntelligenceStreamHandler: NSObject, FlutterStreamHandler {
  private var task: Task<Void, Never>?
  /// The open chat's session (type-erased: FoundationModels is iOS 26+).
  private var chatSession: AnyObject?
  private var chatSessionKey: String?
  /// Session warmed before the user hits Send; adopted by the next request.
  private var warmSession: AnyObject?

  func cancel() {
    task?.cancel()
    task = nil
    // A cut-off reply leaves the transcript half-written: start over next time.
    resetSession()
  }

  func resetSession() {
    chatSession = nil
    chatSessionKey = nil
  }

  func prewarm(sessionKey: String?) {
    #if canImport(FoundationModels)
    if #available(iOS 26.0, macOS 26.0, *) {
      guard case .available = SystemLanguageModel.default.availability else { return }
      if let key = sessionKey, key == chatSessionKey,
         let session = chatSession as? LanguageModelSession {
        session.prewarm()
        return
      }
      let session = LanguageModelSession()
      session.prewarm()
      warmSession = session
    }
    #endif
  }

  func onListen(withArguments arguments: Any?,
                eventSink events: @escaping FlutterEventSink) -> FlutterError? {
    let args = arguments as? [String: Any] ?? [:]
    let prompt = args["prompt"] as? String ?? ""
    let instructions = (args["instructions"] as? String) ?? ""
    let maxTokens = (args["maxTokens"] as? NSNumber)?.intValue ?? 1024
    let temperature = (args["temperature"] as? NSNumber)?.doubleValue ?? 0.7
    let sessionKey = args["sessionKey"] as? String
    let continuing = (args["mode"] as? String) == "continue"

    func send(_ value: Any?) {
      DispatchQueue.main.async { events(value) }
    }

    #if canImport(FoundationModels)
    if #available(iOS 26.0, macOS 26.0, *) {
      task?.cancel()
      let session: LanguageModelSession
      if continuing {
        guard let key = sessionKey, key == chatSessionKey,
              let existing = chatSession as? LanguageModelSession else {
          // Dart falls back to a fresh session with the packed history.
          return FlutterError(
            code: "apple_ai_session_lost",
            message: "Apple Intelligence session ended.",
            details: nil)
        }
        session = existing
      } else {
        if instructions.isEmpty, let warm = warmSession as? LanguageModelSession {
          session = warm
        } else {
          session = instructions.isEmpty
            ? LanguageModelSession()
            : LanguageModelSession(instructions: instructions)
        }
        warmSession = nil
        if let key = sessionKey {
          chatSession = session
          chatSessionKey = key
        } else {
          // One-off (e.g. a chat title): don't disturb the chat's session.
        }
      }
      task = Task {
        do {
          let options = GenerationOptions(
            temperature: temperature,
            maximumResponseTokens: maxTokens)
          var sent = ""
          for try await snapshot in session.streamResponse(
            to: prompt, options: options) {
            if Task.isCancelled { break }
            // Each snapshot is the whole reply so far: forward only the new part.
            let text = snapshot.content
            if text.hasPrefix(sent) {
              let delta = String(text.dropFirst(sent.count))
              if !delta.isEmpty { send(delta) }
            } else if !text.isEmpty {
              send(text)
            }
            sent = text
          }
          send(FlutterEndOfEventStream)
        } catch is CancellationError {
          send(FlutterEndOfEventStream)
        } catch let error as LanguageModelSession.GenerationError {
          if case .exceededContextWindowSize = error {
            // Dart retries once with a fresh session from packed history.
            send(FlutterError(
              code: "apple_ai_context",
              message: Self.message(for: error),
              details: nil))
            return
          }
          send(FlutterError(
            code: "apple_ai_generation",
            message: Self.message(for: error),
            details: nil))
        } catch {
          send(FlutterError(
            code: "apple_ai_failed",
            message: "Apple Intelligence couldn't answer: \(error.localizedDescription)",
            details: nil))
        }
      }
      return nil
    }
    #endif
    return FlutterError(
      code: "apple_ai_unavailable",
      message: "Apple Intelligence needs iOS 26 or macOS 26 on a supported device.",
      details: nil)
  }

  func onCancel(withArguments arguments: Any?) -> FlutterError? {
    cancel()
    return nil
  }

  #if canImport(FoundationModels)
  @available(iOS 26.0, macOS 26.0, *)
  private static func message(for error: LanguageModelSession.GenerationError) -> String {
    switch error {
    case .exceededContextWindowSize:
      return "This chat is too long for Apple Intelligence. Start a new chat to continue."
    case .guardrailViolation:
      return "Apple Intelligence declined to answer this request."
    case .unsupportedLanguageOrLocale:
      return "Apple Intelligence doesn't support this language yet."
    case .assetsUnavailable:
      return "Apple Intelligence is still getting ready on this device. Try again in a few minutes."
    case .rateLimited:
      return "Apple Intelligence is busy. Try again in a moment."
    default:
      return "Apple Intelligence couldn't answer: \(error.localizedDescription)"
    }
  }
  #endif
}
