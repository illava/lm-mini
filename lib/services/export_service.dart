import 'dart:io';
import 'dart:convert';
import 'dart:math' as math;
import 'package:archive/archive_io.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:syncfusion_flutter_pdf/pdf.dart';
import 'package:share_plus/share_plus.dart';
import '../models/chat_conversation.dart';
import '../models/chat_message.dart';
import '../services/database_service.dart';
import 'export_text.dart';
import 'pdf_glyph_coverage.dart';

part '../pro/export/export_service_pro.dart';

/// Bundled Noto Sans fonts (OFL, see assets/fonts/OFL.txt) for PDF export.
/// The PDF standard fonts only cover Latin-1, so any Cyrillic / Greek /
/// emoji character used to fail the whole export.
class _PdfFontData {
  final Uint8List regular;
  final Uint8List bold;
  final Uint8List mono;

  /// Glyphs both the regular and bold faces have.
  final GlyphCoverage textCoverage;
  final GlyphCoverage monoCoverage;

  _PdfFontData(this.regular, this.bold, this.mono)
      : textCoverage = GlyphCoverage.fromTrueType(regular)
            .intersect(GlyphCoverage.fromTrueType(bold)),
        monoCoverage = GlyphCoverage.fromTrueType(mono);

  static Future<_PdfFontData>? _cached;

  static Future<_PdfFontData> load() => _cached ??= _read();

  static Future<_PdfFontData> _read() async {
    Future<Uint8List> bytes(String name) async =>
        (await rootBundle.load('assets/fonts/$name')).buffer.asUint8List();
    try {
      return _PdfFontData(
        await bytes('NotoSans-Regular.ttf'),
        await bytes('NotoSans-Bold.ttf'),
        await bytes('NotoSansMono-Regular.ttf'),
      );
    } catch (_) {
      _cached = null; // let the next export retry
      rethrow;
    }
  }
}

/// Draws flowing text onto a [PdfDocument], following the page each draw
/// ends on so long paragraphs and code blocks continue on the next page.
class _PdfFlow {
  _PdfFlow(this.document) : page = document.pages.add();

  final PdfDocument document;
  PdfPage page;
  double y = 0;

  double get width => page.getClientSize().width;
  double get height => page.getClientSize().height;

  void newPage() {
    page = document.pages.add();
    y = 0;
  }

  void ensureSpace(double needed) {
    if (y + needed > height) newPage();
  }

  /// Draws wrapped [text] and moves below it (onto later pages if needed).
  void text(
    String text,
    PdfFont font, {
    double indent = 0,
    PdfBrush? brush,
    double after = 4,
  }) {
    if (text.trim().isEmpty) return;
    ensureSpace(font.height + 2);
    final w = width - indent;
    final result = PdfTextElement(
      text: text,
      font: font,
      brush: brush ?? PdfBrushes.black,
    ).draw(
      page: page,
      bounds: Rect.fromLTWH(indent, y, w, 0),
      format: PdfLayoutFormat(
        layoutType: PdfLayoutType.paginate,
        breakType: PdfLayoutBreakType.fitPage,
        paginateBounds: Rect.fromLTWH(indent, 0, w, height),
      ),
    );
    if (result != null) {
      page = result.page;
      y = result.bounds.bottom + after;
    }
  }

  /// Code block on a grey panel; the panel is split per page.
  void code(String code, PdfFont font, {double indent = 8}) {
    const pad = 6.0;
    final panelW = width - indent;
    final innerW = panelW - pad * 2;
    final lines = code.split('\n');
    double lineHeight(String line) => font
        .measureString(line.isEmpty ? ' ' : line, layoutArea: Size(innerW, 0))
        .height;

    var i = 0;
    while (i < lines.length) {
      ensureSpace(font.height + pad * 2 + 2);
      // Small slack so a chunk measured to fit never spills.
      final available = (height - y - pad * 2) * 0.97;
      final chunk = <String>[];
      var chunkHeight = 0.0;
      while (i < lines.length) {
        final h = lineHeight(lines[i]);
        if (chunk.isNotEmpty && chunkHeight + h > available) break;
        chunk.add(lines[i]);
        chunkHeight += h;
        i++;
      }
      final panelH = math.min(chunkHeight + pad * 2, height - y);
      final panel = Rect.fromLTWH(indent, y, panelW, panelH);
      page.graphics.drawRectangle(
        brush: PdfSolidBrush(PdfColor(245, 245, 245)),
        pen: PdfPen(PdfColor(220, 220, 220)),
        bounds: panel,
      );
      final result = PdfTextElement(
        text: chunk.join('\n'),
        font: font,
        brush: PdfBrushes.black,
      ).draw(
        page: page,
        bounds: Rect.fromLTWH(indent + pad, y + pad, innerW, 0),
        format: PdfLayoutFormat(
          layoutType: PdfLayoutType.paginate,
          paginateBounds: Rect.fromLTWH(indent + pad, 0, innerW, height),
        ),
      );
      if (result != null && result.page != page) {
        // A single line taller than the page: continue after it.
        page = result.page;
        y = result.bounds.bottom + 8;
      } else {
        y = panel.bottom + 8;
      }
      if (i < lines.length) newPage();
    }
  }
}

class ExportService {
  DatabaseService get _databaseService => DatabaseService();

  /// Exports go to the temp directory so they don't pile up in Documents /
  /// iCloud backups; the share sheet copies the file where the user wants it.
  Future<Directory> _exportDirectory() async {
    final dir = Directory('${(await getTemporaryDirectory()).path}/exports');
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  Future<File> _exportFile(ChatConversation conversation, String ext) async {
    final dir = await _exportDirectory();
    final name = exportSafeFileName(conversation.title);
    return File('${dir.path}/${name}_${DateTime.now().millisecondsSinceEpoch}.$ext');
  }

  // ═════════════════════════════════════════════════════════════════════
  //  FREE FORMATS
  // ═════════════════════════════════════════════════════════════════════

  /// Plain-text transcript (visible answers only, no reasoning).
  @visibleForTesting
  String buildTxt(ChatConversation conversation, List<ChatMessage> messages) {
    final names = exportParticipantNames(conversation);
    final buffer = StringBuffer();
    buffer.writeln('=' * 60);
    buffer.writeln('Chat Export: ${conversation.title}');
    buffer.writeln('Created: ${conversation.createdAt.toString()}');
    buffer.writeln('Updated: ${conversation.updatedAt.toString()}');
    buffer.writeln('=' * 60);
    buffer.writeln();

    for (final message in exportableMessages(messages)) {
      final role = exportSpeakerName(message, names);
      final timestamp = message.timestamp.toString().substring(0, 19);
      buffer.writeln('[$timestamp] $role:');
      buffer.writeln(exportMessageText(message, speakerName: role).answer);
      buffer.writeln();
      buffer.writeln('-' * 60);
      buffer.writeln();
    }
    return buffer.toString();
  }

  /// Export a single conversation to TXT format
  Future<File> exportChatToTxt(ChatConversation conversation, List<ChatMessage> messages) async {
    final file = await _exportFile(conversation, 'txt');
    await file.writeAsString(buildTxt(conversation, messages));
    return file;
  }

  /// PDF bytes for a conversation: markdown-ish layout, images and
  /// attachment names. Text the bundled Noto fonts can't draw (emoji, CJK …)
  /// is dropped or replaced with "[…]" instead of failing the export.
  @visibleForTesting
  Future<List<int>> buildPdfBytes(
    ChatConversation conversation,
    List<ChatMessage> messages,
  ) async {
    final fonts = await _PdfFontData.load();
    String t(String s) => sanitizeForPdfFont(s, fonts.textCoverage);
    String c(String s) => sanitizeForPdfFont(s, fonts.monoCoverage);
    PdfFont regular(double size) => PdfTrueTypeFont(fonts.regular, size);
    PdfFont bold(double size) => PdfTrueTypeFont(fonts.bold, size);

    final document = PdfDocument();
    document.pageSettings.margins.all = 50;
    try {
      final titleFont = bold(18);
      final headerFont = bold(12);
      final h1Font = bold(14);
      final h3Font = bold(10.5);
      final bodyFont = regular(10);
      final codeFont = PdfTrueTypeFont(fonts.mono, 8.5);
      final metaFont = regular(8);
      final attachmentFont = regular(9);
      final names = exportParticipantNames(conversation);

      final flow = _PdfFlow(document);

      flow.text(t(conversation.title), titleFont, after: 10);
      flow.text(
        'Created: ${conversation.createdAt.toString().substring(0, 19)} | '
        'Updated: ${conversation.updatedAt.toString().substring(0, 19)}',
        metaFont,
        brush: PdfBrushes.gray,
        after: 8,
      );
      flow.page.graphics.drawLine(
        PdfPen(PdfColor(200, 200, 200)),
        Offset(0, flow.y),
        Offset(flow.width, flow.y),
      );
      flow.y += 14;

      for (final message in exportableMessages(messages)) {
        flow.ensureSpace(60);
        final role = exportSpeakerName(message, names);
        final timestamp = message.timestamp.toString().substring(0, 19);
        flow.text(
          t('$role • $timestamp'),
          headerFont,
          brush: message.role == 'user' ? PdfBrushes.blue : PdfBrushes.green,
          after: 6,
        );

        // Attached images
        for (final imageUrl in message.imageUrls ?? const <String>[]) {
          try {
            Uint8List? imageBytes;
            if (imageUrl.startsWith('data:image')) {
              imageBytes = base64Decode(imageUrl.split(',').last);
            } else if (imageUrl.startsWith('/') || !imageUrl.contains('://')) {
              final imageFile = File(imageUrl);
              if (await imageFile.exists()) {
                imageBytes = await imageFile.readAsBytes();
              }
            }
            if (imageBytes == null) continue;
            final image = PdfBitmap(imageBytes);
            var imgWidth = image.width.toDouble();
            var imgHeight = image.height.toDouble();
            final maxWidth = flow.width - 20;
            const maxHeight = 200.0;
            if (imgWidth > maxWidth) {
              imgHeight *= maxWidth / imgWidth;
              imgWidth = maxWidth;
            }
            if (imgHeight > maxHeight) {
              imgWidth *= maxHeight / imgHeight;
              imgHeight = maxHeight;
            }
            flow.ensureSpace(imgHeight + 10);
            flow.page.graphics.drawImage(
              image,
              Rect.fromLTWH(10, flow.y, imgWidth, imgHeight),
            );
            flow.y += imgHeight + 10;
          } catch (_) {
            flow.text('[Image attachment - unable to load]', attachmentFont,
                indent: 10, brush: PdfBrushes.gray);
          }
        }

        // File attachment names
        for (final attachment in message.fileAttachments ?? const []) {
          flow.text(
            t('Attachment: ${attachment.fileName} (${attachment.typeDisplayName})'),
            attachmentFont,
            indent: 10,
            brush: PdfBrushes.darkGray,
          );
        }

        // Markdown-ish body (visible answer only)
        final content = exportMessageText(message, speakerName: role).answer;
        final lines = content.split('\n');
        var inCodeBlock = false;
        final code = <String>[];

        for (final line in lines) {
          if (line.trim().startsWith('```')) {
            if (inCodeBlock) {
              if (code.isNotEmpty) flow.code(c(code.join('\n')), codeFont);
              code.clear();
            }
            inCodeBlock = !inCodeBlock;
            continue;
          }
          if (inCodeBlock) {
            code.add(line);
            continue;
          }
          if (line.trim().isEmpty) {
            flow.y += 6;
            continue;
          }

          if (line.startsWith('### ')) {
            flow.text(t(line.substring(4)), h3Font, indent: 10);
          } else if (line.startsWith('## ')) {
            flow.text(t(line.substring(3)), headerFont, indent: 10);
          } else if (line.startsWith('# ')) {
            flow.text(t(line.substring(2)), h1Font, indent: 10);
          } else if (line.startsWith('- ') || line.startsWith('* ')) {
            flow.text(t('• ${_stripInlineMarkdown(line.substring(2))}'),
                bodyFont,
                indent: 20);
          } else if (RegExp(r'^\d+\. ').hasMatch(line)) {
            flow.text(t(_stripInlineMarkdown(line)), bodyFont, indent: 20);
          } else {
            flow.text(t(_stripInlineMarkdown(line)), bodyFont, indent: 10);
          }
        }
        // Unclosed fence (e.g. truncated output): still show the code.
        if (inCodeBlock && code.isNotEmpty) {
          flow.code(c(code.join('\n')), codeFont);
        }

        flow.y += 8;
        flow.ensureSpace(15);
        flow.page.graphics.drawLine(
          PdfPen(PdfColor(230, 230, 230)),
          Offset(0, flow.y),
          Offset(flow.width, flow.y),
        );
        flow.y += 14;
      }

      return await document.save();
    } finally {
      document.dispose();
    }
  }

  static String _stripInlineMarkdown(String line) => line
      .replaceAllMapped(RegExp(r'\*\*(.+?)\*\*'), (m) => m[1]!)
      .replaceAllMapped(
          RegExp(r'(?<![\w*])\*(?!\s)(.+?)\*(?!\w)'), (m) => m[1]!)
      .replaceAllMapped(RegExp(r'`(.+?)`'), (m) => m[1]!);

  /// Export a single conversation to PDF format with markdown, images, and attachments
  Future<File> exportChatToPdf(ChatConversation conversation, List<ChatMessage> messages) async {
    final bytes = await buildPdfBytes(conversation, messages);
    final file = await _exportFile(conversation, 'pdf');
    await file.writeAsBytes(bytes);
    return file;
  }

  /// ZIP archive with one UTF-8 TXT transcript per conversation (unique
  /// entry names) plus `_export_info.txt`.
  @visibleForTesting
  Archive buildChatsArchive(
    List<(ChatConversation, List<ChatMessage>)> chats, {
    DateTime? exportedAt,
  }) {
    final archive = Archive();
    final timestamp = (exportedAt ?? DateTime.now())
        .toString()
        .substring(0, 19)
        .replaceAll(':', '-');
    final taken = <String>{'_export_info.txt'};

    for (final (conversation, messages) in chats) {
      final name = uniqueExportEntryName(
        exportSafeFileName(conversation.title),
        '.txt',
        taken,
      );
      final bytes = utf8.encode(buildTxt(conversation, messages));
      archive.addFile(ArchiveFile(name, bytes.length, bytes));
    }

    final metadata = StringBuffer();
    metadata.writeln('LM Mini - Chat Export');
    metadata.writeln('Export Date: $timestamp');
    metadata.writeln('Total Conversations: ${chats.length}');
    metadata.writeln();
    metadata.writeln('Conversations:');
    for (final (conv, messages) in chats) {
      metadata.writeln(
          '- ${conv.title.replaceAll(RegExp(r'\s+'), ' ')} (${exportableMessages(messages).length} messages)');
    }
    final metaBytes = utf8.encode(metadata.toString());
    archive.addFile(
        ArchiveFile('_export_info.txt', metaBytes.length, metaBytes));
    return archive;
  }

  /// Export all conversations to a ZIP file
  Future<File> exportAllChatsToZip() async {
    final conversations = await _databaseService.getAllConversations();
    final chats = <(ChatConversation, List<ChatMessage>)>[];
    for (final conversation in conversations) {
      chats.add((
        conversation,
        await _databaseService.getMessagesForConversation(conversation.id),
      ));
    }
    final now = DateTime.now();
    final archive = buildChatsArchive(chats, exportedAt: now);

    final dir = await _exportDirectory();
    final stamp = now.toString().substring(0, 19).replaceAll(':', '-');
    final zipFile = File('${dir.path}/lm_mini_export_$stamp.zip');
    final outputStream = OutputFileStream(zipFile.path);
    ZipEncoder().encode(archive, output: outputStream);
    await outputStream.close();
    return zipFile;
  }

  /// Share a file using the native share dialog. [sharePositionOrigin]
  /// anchors the iPad / macOS popover (see `shareOriginFor`).
  Future<ShareResult> shareFile(
    File file,
    String mimeType, {
    Rect? sharePositionOrigin,
  }) {
    return Share.shareXFiles(
      [XFile(file.path, mimeType: mimeType)],
      subject: 'Chat Export from LM Mini',
      sharePositionOrigin:
          sharePositionOrigin ?? const Rect.fromLTWH(0, 0, 1, 1),
    );
  }

  /// Export single chat with format selection, then open the share sheet.
  Future<ShareResult> exportChat(
    ChatConversation conversation,
    List<ChatMessage> messages,
    String format, {
    Rect? sharePositionOrigin,
  }) async {
    File exportedFile;
    String mimeType;

    switch (format) {
      case 'pdf':
        exportedFile = await exportChatToPdf(conversation, messages);
        mimeType = 'application/pdf';
      case 'markdown':
        exportedFile = await exportChatToMarkdown(conversation, messages);
        mimeType = 'text/markdown';
      case 'obsidian':
        exportedFile = await exportChatToObsidian(conversation, messages);
        mimeType = 'text/markdown';
      case 'json':
        exportedFile = await exportChatToJson(conversation, messages);
        mimeType = 'application/json';
      default:
        exportedFile = await exportChatToTxt(conversation, messages);
        mimeType = 'text/plain';
    }

    return shareFile(exportedFile, mimeType,
        sharePositionOrigin: sharePositionOrigin);
  }

  /// Export all chats as ZIP, then open the share sheet.
  Future<ShareResult> exportAllChats({Rect? sharePositionOrigin}) async {
    final zipFile = await exportAllChatsToZip();
    return shareFile(zipFile, 'application/zip',
        sharePositionOrigin: sharePositionOrigin);
  }

  // ═════════════════════════════════════════════════════════════════════
  //  PREMIUM FORMATS (implemented in the Pro part; the open-source build
  //  throws UnsupportedError)
  // ═════════════════════════════════════════════════════════════════════

  /// Copy a conversation to clipboard as Markdown.
  Future<void> copyToClipboard(
    ChatConversation conversation,
    List<ChatMessage> messages,
  ) =>
      _proCopyToClipboard(conversation, messages);

  /// Export a conversation to a clean Markdown file.
  Future<File> exportChatToMarkdown(
    ChatConversation conversation,
    List<ChatMessage> messages,
  ) =>
      _proExportMarkdown(conversation, messages);

  /// Export with YAML frontmatter suitable for Obsidian vaults.
  Future<File> exportChatToObsidian(
    ChatConversation conversation,
    List<ChatMessage> messages,
  ) =>
      _proExportObsidian(conversation, messages);

  /// Export conversation with all metadata as structured JSON.
  Future<File> exportChatToJson(
    ChatConversation conversation,
    List<ChatMessage> messages,
  ) =>
      _proExportJson(conversation, messages);
}
