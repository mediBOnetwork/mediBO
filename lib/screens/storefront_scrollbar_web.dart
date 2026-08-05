// ignore_for_file: avoid_web_libraries_in_flutter
import 'dart:html' as html;

void injectScrollbarCss() {
  final style = html.StyleElement()
    ..text = '''
          ::-webkit-scrollbar { width: 5px; height: 5px; }
          ::-webkit-scrollbar-track { background: transparent; }
          ::-webkit-scrollbar-thumb { background: rgba(27,122,67,0.45); border-radius: 8px; }
          ::-webkit-scrollbar-thumb:hover { background: #1B7A43; }
        ''';
  html.document.head!.append(style);
}
