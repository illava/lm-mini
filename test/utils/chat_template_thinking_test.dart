import 'package:flutter_test/flutter_test.dart';
import 'package:lm_mini/utils/chat_template_thinking.dart';
import 'package:lm_mini/utils/response_parser.dart';

// Generation-prompt tails as shipped in the lmstudio-community GGUFs.
const _qwen35_9b = r"""
{%- for message in messages %}{{ message.content }}{%- endfor %}
{%- if add_generation_prompt %}
    {{- '<|im_start|>assistant\n' }}
    {%- if enable_thinking is defined and enable_thinking is false %}
        {{- '<think>\n\n</think>\n\n' }}
    {%- else %}
        {{- '<think>\n' }}
    {%- endif %}
{%- endif %}""";

const _qwen35_2b = r"""
{%- if add_generation_prompt %}
    {{- '<|im_start|>assistant\n' }}
    {%- if enable_thinking is defined and enable_thinking is true %}
        {{- '<think>\n' }}
    {%- else %}
        {{- '<think>\n\n</think>\n\n' }}
    {%- endif %}
{%- endif %}""";

// Qwen 3 (2504): history uses '<think>\n', the prompt never pre-fills it.
const _qwen3 = r"""
{{- '<|im_start|>assistant\n<think>\n' + reasoning_content + '\n</think>\n\n' }}
{%- if add_generation_prompt %}
    {{- '<|im_start|>assistant\n' }}
    {%- if enable_thinking is defined and enable_thinking is false %}
        {{- '<think>\n\n</think>\n\n' }}
    {%- endif %}
{%- endif %}""";

const _r1 = r"""{% if add_generation_prompt %}{{'<｜Assistant｜><think>\n'}}{% endif %}""";

const _llama = r"""{% if add_generation_prompt %}{{ '<|start_header_id|>assistant<|end_header_id|>\n\n' }}{% endif %}""";

void main() {
  group('prefillsThink', () {
    test('Qwen 3.5 (both template styles) and R1 distills pre-fill <think>',
        () {
      expect(ChatTemplateThinking.prefillsThink(_qwen35_9b), isTrue);
      expect(ChatTemplateThinking.prefillsThink(_qwen35_2b), isTrue);
      expect(ChatTemplateThinking.prefillsThink(_r1), isTrue);
    });

    test('Qwen 3 and plain templates do not', () {
      expect(ChatTemplateThinking.prefillsThink(_qwen3), isFalse);
      expect(ChatTemplateThinking.prefillsThink(_llama), isFalse);
    });
  });

  test('thinking can be switched off only where the template reads it', () {
    expect(ChatTemplateThinking.canDisableThinking(_qwen35_9b), isTrue);
    expect(ChatTemplateThinking.canDisableThinking(_llama), isFalse);
    expect(
      ChatTemplateThinking.withThinkingOff(_qwen35_9b),
      startsWith('{%- set enable_thinking = false -%}'),
    );
  });

  group('closing </think> without an opening tag', () {
    test('text before it is thinking, after it is the answer', () {
      final p = ResponseParser.parse(
          'Thinking Process:\n1. Analyze the request\n</think>\n\nHello!');
      expect(p.thinking, 'Thinking Process:\n1. Analyze the request');
      expect(p.answer, 'Hello!');
    });

    test('normal <think> blocks are unchanged', () {
      final p = ResponseParser.parse('<think>plan</think>\n\nHi');
      expect(p.thinking, 'plan');
      expect(p.answer, 'Hi');
    });
  });
}
