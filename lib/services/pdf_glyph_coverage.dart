import 'dart:typed_data';

/// Which Unicode code points a TrueType font has glyphs for, read from its
/// `cmap` table. The PDF export uses it to keep text the bundled fonts can't
/// draw (emoji, CJK, …) from failing or rendering as empty boxes.
class GlyphCoverage {
  GlyphCoverage._(this._bits);

  static const int _maxCodePoint = 0x110000;
  final Uint8List _bits;

  bool covers(int codePoint) =>
      codePoint >= 0 &&
      codePoint < _maxCodePoint &&
      (_bits[codePoint >> 3] & (1 << (codePoint & 7))) != 0;

  /// Code points covered by both this and [other].
  GlyphCoverage intersect(GlyphCoverage other) {
    final out = Uint8List(_bits.length);
    for (var i = 0; i < out.length; i++) {
      out[i] = _bits[i] & other._bits[i];
    }
    return GlyphCoverage._(out);
  }

  /// Parses the font's cmap (format 12 preferred, else format 4). An
  /// unreadable font yields printable ASCII only.
  factory GlyphCoverage.fromTrueType(List<int> fontBytes) {
    final bits = Uint8List(_maxCodePoint >> 3);
    void set(int cp) => bits[cp >> 3] |= 1 << (cp & 7);
    try {
      final data = ByteData.sublistView(Uint8List.fromList(fontBytes));
      final cmap = _findTable(data, 'cmap');
      if (cmap == null) throw const FormatException('no cmap');
      final numSub = data.getUint16(cmap + 2);
      int? fmt12;
      int? fmt4;
      for (var i = 0; i < numSub; i++) {
        final rec = cmap + 4 + i * 8;
        final platform = data.getUint16(rec);
        final encoding = data.getUint16(rec + 2);
        final off = cmap + data.getUint32(rec + 4);
        final format = data.getUint16(off);
        final unicode = platform == 0 ||
            (platform == 3 && (encoding == 1 || encoding == 10));
        if (!unicode) continue;
        if (format == 12) fmt12 ??= off;
        if (format == 4) fmt4 ??= off;
      }
      if (fmt12 != null) {
        final groups = data.getUint32(fmt12 + 12);
        for (var g = 0; g < groups; g++) {
          final p = fmt12 + 16 + g * 12;
          final start = data.getUint32(p);
          final end = data.getUint32(p + 4);
          final startGlyph = data.getUint32(p + 8);
          for (var cp = start; cp <= end && cp < _maxCodePoint; cp++) {
            if (startGlyph + (cp - start) != 0) set(cp);
          }
        }
      } else if (fmt4 != null) {
        final segX2 = data.getUint16(fmt4 + 6);
        final ends = fmt4 + 14;
        final starts = ends + segX2 + 2;
        final deltas = starts + segX2;
        final rangeOffsets = deltas + segX2;
        for (var s = 0; s < segX2 ~/ 2; s++) {
          final end = data.getUint16(ends + s * 2);
          final start = data.getUint16(starts + s * 2);
          final delta = data.getInt16(deltas + s * 2);
          final roPos = rangeOffsets + s * 2;
          final ro = data.getUint16(roPos);
          for (var cp = start; cp <= end && cp != 0xFFFF; cp++) {
            int glyph;
            if (ro == 0) {
              glyph = (cp + delta) & 0xFFFF;
            } else {
              final at = roPos + ro + (cp - start) * 2;
              if (at + 1 >= data.lengthInBytes) continue;
              glyph = data.getUint16(at);
              if (glyph != 0) glyph = (glyph + delta) & 0xFFFF;
            }
            if (glyph != 0) set(cp);
          }
        }
      } else {
        throw const FormatException('no unicode cmap');
      }
    } catch (_) {
      for (var cp = 0x20; cp < 0x7F; cp++) {
        set(cp);
      }
    }
    return GlyphCoverage._(bits);
  }

  static int? _findTable(ByteData data, String tag) {
    final numTables = data.getUint16(4);
    for (var i = 0; i < numTables; i++) {
      final rec = 12 + i * 16;
      final t = String.fromCharCodes([
        data.getUint8(rec),
        data.getUint8(rec + 1),
        data.getUint8(rec + 2),
        data.getUint8(rec + 3),
      ]);
      if (t == tag) return data.getUint32(rec + 8);
    }
    return null;
  }
}

/// Marker drawn in place of a run of characters the PDF font can't show
/// (CJK, Arabic, …).
const String kPdfUnsupportedMarker = '[…]';

bool _isEmojiOrSymbol(int cp) =>
    (cp >= 0x1F000 && cp <= 0x1FAFF) || // emoji, flags, pictographs
    (cp >= 0x2190 && cp <= 0x21FF) || // arrows
    (cp >= 0x2300 && cp <= 0x23FF) || // misc technical (⌚ ⏰)
    (cp >= 0x2460 && cp <= 0x24FF) || // enclosed alphanumerics
    (cp >= 0x25A0 && cp <= 0x27BF) || // shapes, misc symbols, dingbats
    (cp >= 0x2900 && cp <= 0x297F) ||
    (cp >= 0x2B00 && cp <= 0x2BFF) || // misc symbols and arrows (⭐)
    (cp >= 0xFE00 && cp <= 0xFE0F) || // variation selectors
    (cp >= 0xE0000 && cp <= 0xE01EF) || // tags, VS supplement
    (cp >= 0xE000 && cp <= 0xF8FF) || // private use
    (cp >= 0xD800 && cp <= 0xDFFF) || // lone surrogates
    cp == 0x200D || // ZWJ
    cp == 0x20E3 || // keycap
    cp == 0x3030 ||
    cp == 0x303D ||
    cp == 0x3297 ||
    cp == 0x3299 ||
    cp == 0xFFFD;

/// Makes [text] drawable with a font of [coverage]: tabs become spaces,
/// unsupported emoji / symbols are dropped, and each run of other unsupported
/// characters (CJK, …, including spaces inside the run) becomes
/// [kPdfUnsupportedMarker]. Never throws.
String sanitizeForPdfFont(String text, GlyphCoverage coverage) {
  final out = StringBuffer();
  var inRun = false;
  final pendingSpaces = StringBuffer();
  var droppedSinceWrite = false;
  var lastWritten = -1;

  void write(int cp) {
    out.writeCharCode(cp);
    lastWritten = cp;
    droppedSinceWrite = false;
  }

  void closeRun() {
    if (!inRun) return;
    out.write(kPdfUnsupportedMarker);
    lastWritten = 0x5D; // ']'
    final spaces = pendingSpaces.toString();
    if (spaces.isNotEmpty) {
      out.write(spaces);
      lastWritten = 0x20;
    }
    pendingSpaces.clear();
    inRun = false;
    droppedSinceWrite = false;
  }

  for (var cp in text.runes) {
    if (cp == 0x0D) continue; // \r
    if (cp == 0x09) {
      if (inRun) {
        pendingSpaces.write('    ');
      } else {
        out.write('    ');
        lastWritten = 0x20;
      }
      continue;
    }
    if (cp == 0x0A) {
      closeRun();
      write(cp);
      continue;
    }
    // Emoji joiners / presentation selectors: meaningless once the emoji
    // around them are gone, even when the font has a glyph for them.
    if (cp == 0x200D || cp == 0x20E3 || (cp >= 0xFE00 && cp <= 0xFE0F)) {
      droppedSinceWrite = true;
      continue;
    }
    if (cp == 0xA0 && !coverage.covers(cp)) cp = 0x20;
    if (cp == 0x20) {
      if (inRun) {
        pendingSpaces.write(' ');
      } else if (!(droppedSinceWrite && lastWritten == 0x20)) {
        write(cp);
      }
      continue;
    }
    if (coverage.covers(cp)) {
      closeRun();
      write(cp);
      continue;
    }
    if (_isEmojiOrSymbol(cp) || (cp < 0x20)) {
      droppedSinceWrite = true;
      continue;
    }
    // Unsupported script character: fold into a marker run.
    if (!inRun) {
      inRun = true;
      pendingSpaces.clear();
    } else {
      pendingSpaces.clear(); // spaces between unsupported chars join the run
    }
  }
  closeRun();
  return out.toString();
}
