/// What a GGUF chat template does with thinking, for the on-device engine.
///
/// fllama renders the model's template with `enable_thinking = true` and
/// hands back the raw reply. Templates such as Qwen 3.5 then put `<think>`
/// in the prompt itself, so the reply starts mid-thought and only contains
/// the closing `</think>` — the app showed the reasoning as the answer.
abstract final class ChatTemplateThinking {
  /// The generation prompt ends with an opening `<think>` (thinking on).
  /// Only the part after the last `add_generation_prompt` is checked, so a
  /// template that merely wraps old turns in `<think>` doesn't count, and
  /// the empty "thinking off" block `<think>\n\n</think>` doesn't either.
  static bool prefillsThink(String template) {
    final at = template.lastIndexOf('add_generation_prompt');
    if (at < 0) return false;
    final tail = template.substring(at);
    // Jinja source holds a literal backslash-n: `'<think>\n'`.
    return RegExp(r"<think>\\n['\x22]").hasMatch(tail);
  }

  /// The template reads `enable_thinking`, so it can be switched off.
  static bool canDisableThinking(String template) =>
      template.contains('enable_thinking');

  /// Same template with thinking forced off (the user turned Think off).
  static String withThinkingOff(String template) =>
      '{%- set enable_thinking = false -%}\n$template';
}
