import 'package:flutter/material.dart';

/// Parses WhatsApp-style inline markdown into TextSpans.
/// Supports: *bold*  _italic_  ~strikethrough~  ```monospace```
/// Rules mirror WhatsApp: markers must wrap non-empty content; unmatched markers
/// are rendered literally. Nesting is supported (e.g. *_bold italic_*).
class WaMarkdown {
  static List<TextSpan> spans(String input, TextStyle base) {
    return _parse(input, base);
  }

  static List<TextSpan> _parse(String text, TextStyle style) {
    final List<TextSpan> out = [];
    int i = 0;
    final buf = StringBuffer();

    void flush() {
      if (buf.isNotEmpty) {
        out.add(TextSpan(text: buf.toString(), style: style));
        buf.clear();
      }
    }

    // monospace ``` first (multi-char marker)
    // We handle it inline within the same loop.
    while (i < text.length) {
      // triple backtick
      if (text.startsWith('```', i)) {
        final close = text.indexOf('```', i + 3);
        if (close != -1 && close > i + 3) {
          flush();
          final inner = text.substring(i + 3, close);
          out.add(TextSpan(
            text: inner,
            style: style.copyWith(fontFamily: 'monospace', letterSpacing: 0),
          ));
          i = close + 3;
          continue;
        }
      }

      final ch = text[i];
      if (ch == '*' || ch == '_' || ch == '~') {
        final close = _findClose(text, i + 1, ch);
        if (close != -1) {
          flush();
          final inner = text.substring(i + 1, close);
          TextStyle childStyle;
          if (ch == '*') {
            childStyle = style.copyWith(fontWeight: FontWeight.bold);
          } else if (ch == '_') {
            childStyle = style.copyWith(fontStyle: FontStyle.italic);
          } else {
            childStyle = style.copyWith(decoration: TextDecoration.lineThrough);
          }
          // recurse for nesting
          out.addAll(_parse(inner, childStyle));
          i = close + 1;
          continue;
        }
      }

      buf.write(ch);
      i++;
    }
    flush();
    return out;
  }

  // Find the matching closing marker for [marker] starting search at [from].
  // Closing marker must have non-space immediately before it and the wrapped
  // content must be non-empty (WhatsApp behavior). Returns index of closer or -1.
  static int _findClose(String text, int from, String marker) {
    if (from >= text.length) return -1;
    // content cannot start with whitespace right after opener for it to be valid-ish;
    // WhatsApp is lenient, so we only require a closer with matching marker.
    for (int j = from; j < text.length; j++) {
      if (text[j] == marker) {
        if (j == from) return -1; // empty content
        return j;
      }
      // do not cross a newline-only? WhatsApp allows multiline bold; keep crossing.
    }
    return -1;
  }
}
