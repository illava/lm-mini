import 'dart:convert';

import 'package:archive/archive.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lm_mini/models/chat_conversation.dart';
import 'package:lm_mini/models/chat_message.dart';
import 'package:lm_mini/services/export_service.dart';
import 'package:lm_mini/services/export_text.dart';
import 'package:lm_mini/services/pdf_glyph_coverage.dart';
import 'package:syncfusion_flutter_pdf/pdf.dart';

ChatConversation _conv(String title, {Map<String, dynamic>? settings}) =>
    ChatConversation(
      id: 'c-$title',
      title: title,
      createdAt: DateTime(2026, 10, 1, 12),
      updatedAt: DateTime(2026, 10, 2, 12),
      messageIds: const [],
      settings: settings ?? <String, dynamic>{},
    );

ChatMessage _msg(String role, String content,
        {String? participantId, String? model}) =>
    ChatMessage(
      id: '${role}_${content.hashCode}',
      content: content,
      role: role,
      timestamp: DateTime(2026, 10, 1, 12, 30),
      participantId: participantId,
      model: model,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('exportSafeFileName', () {
    test('keeps Cyrillic / CJK / emoji, replaces only forbidden chars', () {
      expect(exportSafeFileName('Привет мир'), 'Привет мир');
      expect(exportSafeFileName('你好 世界'), '你好 世界');
      expect(exportSafeFileName('a/b\\c:d*e?f"g<h>i|j'), 'a_b_c_d_e_f_g_h_i_j');
      expect(exportSafeFileName('Plan 🚀 v2.5'), 'Plan 🚀 v2.5');
    });

    test('newlines, tabs and runs of whitespace collapse to one space', () {
      expect(exportSafeFileName('line one\nline two\t\tend'),
          'line one line two end');
      expect(exportSafeFileName('  padded  title  '), 'padded title');
      expect(exportSafeFileName('bell\x07char'), 'bell_char');
    });

    test('caps length by characters and UTF-8 bytes', () {
      final long = 'x' * 300;
      expect(exportSafeFileName(long).length, 80);
      final cyr = 'ж' * 300; // 2 bytes each
      final cut = exportSafeFileName(cyr);
      expect(cut.runes.length, 80);
      expect(utf8.encode(cut).length, lessThan(200));
      final cjk = '漢' * 300; // 3 bytes each
      expect(utf8.encode(exportSafeFileName(cjk)).length, lessThan(200));
      final emoji = '😀' * 100; // 4 bytes each, surrogate pairs
      final e = exportSafeFileName(emoji);
      expect(utf8.encode(e).length, lessThan(200));
      expect(e.runes.every((r) => r == 0x1F600), isTrue);
    });

    test('falls back to "chat"', () {
      expect(exportSafeFileName(''), 'chat');
      expect(exportSafeFileName('   \n  '), 'chat');
      expect(exportSafeFileName('...'), 'chat');
    });
  });

  group('uniqueExportEntryName', () {
    test('suffixes duplicates case-insensitively', () {
      final taken = <String>{};
      expect(uniqueExportEntryName('Chat', '.txt', taken), 'Chat.txt');
      expect(uniqueExportEntryName('Chat', '.txt', taken), 'Chat (2).txt');
      expect(uniqueExportEntryName('chat', '.txt', taken), 'chat (3).txt');
    });
  });

  group('visible message text', () {
    test('hidden model tags and thinking are stripped', () {
      final m = _msg(
        'assistant',
        '<think>secret plan</think>[EXPRESSION: joy]Here you go! '
            '[IMG_PROMPT: a cat on a sofa] [MEMORY_SAVE: likes cats]',
      );
      final text = exportMessageText(m);
      expect(text.answer, 'Here you go!');
      expect(text.reasoning, 'secret plan');
    });

    test('TXT omits reasoning and hidden tags', () {
      final txt = ExportService().buildTxt(_conv('T'), [
        _msg('user', 'hi'),
        _msg('assistant', '<think>internal</think>Answer [IMG_PROMPT: x]'),
        _msg('tool', 'tool output'),
        _msg('assistant', 'Tool call: search'),
      ]);
      expect(txt, contains('Answer'));
      expect(txt, isNot(contains('internal')));
      expect(txt, isNot(contains('IMG_PROMPT')));
      expect(txt, isNot(contains('tool output')));
      expect(txt, isNot(contains('Tool call')));
    });

    test('group chat messages use participant names', () {
      final conv = _conv('Group', settings: {
        'isGroupChat': true,
        'participants': [
          {'id': 'p1', 'modelId': 'm1', 'displayName': 'Professor'},
          {'id': 'p2', 'modelId': 'm2', 'displayName': 'Coder'},
        ],
      });
      final txt = ExportService().buildTxt(conv, [
        _msg('user', 'question'),
        _msg('assistant', '[Professor]: Lecture time', participantId: 'p1'),
        _msg('assistant', 'Code time', participantId: 'p2'),
        _msg('assistant', 'Who am I', participantId: 'gone'),
      ]);
      expect(txt, contains('Professor:\nLecture time'));
      expect(txt, contains('Coder:\nCode time'));
      expect(txt, contains('Assistant:\nWho am I'));
      expect(txt, isNot(contains('[Professor]:')));
    });
  });

  group('ZIP export', () {
    test('UTF-8 round trip and unique entry names', () {
      final archive = ExportService().buildChatsArchive([
        (_conv('Привет'), [_msg('user', 'Как дела? 你好 😀')]),
        (_conv('Привет'), [_msg('user', 'второй')]),
        (_conv('Same'), [_msg('user', 'one')]),
        (_conv('same'), [_msg('user', 'two')]),
      ]);
      final bytes = ZipEncoder().encode(archive)!;
      final decoded = ZipDecoder().decodeBytes(bytes);
      final names = decoded.files.map((f) => f.name).toList();
      expect(names.toSet().length, names.length);
      expect(names, containsAll(['Привет.txt', 'Привет (2).txt', '_export_info.txt']));
      final first = decoded.files.firstWhere((f) => f.name == 'Привет.txt');
      final text = utf8.decode(first.content as List<int>);
      expect(text, contains('Как дела? 你好 😀'));
      expect(text, contains('Chat Export: Привет'));
      final info = decoded.files.firstWhere((f) => f.name == '_export_info.txt');
      expect(utf8.decode(info.content as List<int>),
          contains('Total Conversations: 4'));
    });
  });

  group('PDF font sanitising', () {
    late GlyphCoverage coverage;
    setUpAll(() async {
      final data = await rootBundle.load('assets/fonts/NotoSans-Regular.ttf');
      coverage = GlyphCoverage.fromTrueType(data.buffer.asUint8List());
    });

    test('Noto Sans covers Latin, Cyrillic and Greek', () {
      for (final ch in 'AzéßЖжЁΩλ…•'.runes) {
        expect(coverage.covers(ch), isTrue, reason: String.fromCharCode(ch));
      }
      expect(coverage.covers('你'.runes.first), isFalse);
      expect(coverage.covers(0x1F600), isFalse);
    });

    test('emoji are dropped, CJK runs become one marker', () {
      expect(sanitizeForPdfFont('Hi 👋 there', coverage), 'Hi there');
      expect(sanitizeForPdfFont('Привет 😀', coverage), 'Привет ');
      expect(sanitizeForPdfFont('Say 你好 世界!', coverage),
          'Say $kPdfUnsupportedMarker!');
      expect(sanitizeForPdfFont('a\tb\r\nc', coverage), 'a    b\nc');
      expect(sanitizeForPdfFont('👨‍👩‍👧 family', coverage).trim(), 'family');
    });
  });

  group('PDF export', () {
    test('Cyrillic, emoji, CJK, long paragraph and long code paginate', () async {
      final longPara = '${List.filled(900, 'Это длинный абзац с текстом.').join(' ')} ENDPARA';
      final longCode = [
        for (var i = 0; i < 260; i++) 'print("строка $i") # 😀',
        'ENDCODE',
      ].join('\n');
      final conv = _conv('Тестовый чат 😀 你好');
      final messages = [
        _msg('user', 'Привет! 👋 Как дела? 你好'),
        _msg('assistant',
            '<think>hidden reasoning</think># Заголовок\n$longPara\n```python\n$longCode\n```\n- пункт списка 🚀\n1. первый'),
      ];

      final bytes = await ExportService().buildPdfBytes(conv, messages);
      final doc = PdfDocument(inputBytes: bytes);
      try {
        final pages = doc.pages.count;
        expect(pages, greaterThan(3));
        final extractor = PdfTextExtractor(doc);
        final all = extractor.extractText();
        expect(all, contains('Привет'));
        expect(all, contains('Тестовый чат'));
        expect(all, isNot(contains('hidden reasoning')));

        int pageOf(String needle) {
          for (var i = 0; i < pages; i++) {
            final t = extractor.extractText(startPageIndex: i, endPageIndex: i);
            if (t.contains(needle)) return i;
          }
          return -1;
        }

        final paraEnd = pageOf('ENDPARA');
        final codeEnd = pageOf('ENDCODE');
        expect(paraEnd, greaterThan(0), reason: 'paragraph flowed to a later page');
        expect(codeEnd, greaterThan(paraEnd), reason: 'code continued on later pages');
        // Text must not pile up past the bottom of page 1: every page has text.
        for (var i = 0; i < pages; i++) {
          expect(
            extractor.extractText(startPageIndex: i, endPageIndex: i).trim(),
            isNotEmpty,
            reason: 'page $i is empty',
          );
        }
      } finally {
        doc.dispose();
      }
    });
  });
}
