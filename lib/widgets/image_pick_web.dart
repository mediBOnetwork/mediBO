// ignore_for_file: avoid_web_libraries_in_flutter
import 'dart:async';
import 'dart:convert';
import 'dart:html' as html;
import 'dart:typed_data';

/// Opens a browser file picker for a single image and returns its bytes and
/// name, or null if nothing was picked. The FileUploadInputElement +
/// FileReader flow moved here verbatim from the cash sheet.
Future<({Uint8List bytes, String name})?> pickImageBytes() async {
  final completer = Completer<({Uint8List bytes, String name})?>();
  final input = html.FileUploadInputElement();
  input.accept = 'image/*';
  input.multiple = false;
  input.click();

  // Cancel detection: the browser dialog fires NO event on cancel, so the
  // onChange future would hang forever and lock the attach button. When the
  // window regains focus after the dialog closes, if no file arrived shortly
  // after, resolve null so the caller resets and the picker can reopen.
  html.window.onFocus.first.then((_) {
    Future.delayed(const Duration(milliseconds: 700), () {
      if (!completer.isCompleted) completer.complete(null);
    });
  });

  input.onChange.listen((_) async {
    final files = input.files;
    if (files == null || files.isEmpty) {
      if (!completer.isCompleted) completer.complete(null);
      return;
    }
    final file = files.first;

    final reader = html.FileReader();
    reader.readAsDataUrl(file);
    await reader.onLoad.first;
    final dataUrl = reader.result as String;
    final comma = dataUrl.indexOf(',');
    final b64 = dataUrl.substring(comma + 1);
    final bytes = base64Decode(b64);
    if (!completer.isCompleted) {
      completer.complete((bytes: bytes, name: file.name));
    }
  });

  return completer.future;
}
