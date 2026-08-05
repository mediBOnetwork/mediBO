// ignore_for_file: avoid_web_libraries_in_flutter
import 'dart:html' as html;

const bool kQrSaveSupported = true;

void saveQrPng(String b64, String filename) {
  html.AnchorElement(href: 'data:image/png;base64,$b64')
    ..setAttribute('download', filename)
    ..click();
}
