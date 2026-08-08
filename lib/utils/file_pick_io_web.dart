// Web file/photo picking via dart:html input elements. Verbatim behaviour from
// the original bulk_upload code (accept list + camera capture attribute).
// ignore_for_file: avoid_web_libraries_in_flutter, deprecated_member_use
import 'dart:async';
import 'dart:convert';
import 'dart:html' as html;
import 'dart:typed_data';

const String _importAccept =
    '.csv,.xlsx,.xls,.pdf,.ods,.tsv,.txt,.docx,.doc,.html,.htm,.jpg,.jpeg,.png,.webp,.heic,.heif,.gif';

Future<({String name, Uint8List bytes})?> _read(html.File file) async {
  final reader = html.FileReader();
  reader.readAsDataUrl(file);
  await reader.onLoad.first;
  final dataUrl = reader.result as String;
  return (name: file.name, bytes: base64Decode(dataUrl.split(',').last));
}

Future<({String name, Uint8List bytes})?> pickImportFile() async {
  final input = html.FileUploadInputElement()
    ..accept = _importAccept
    ..multiple = false;
  input.click();
  await input.onChange.first;
  final files = input.files;
  if (files == null || files.isEmpty) return null;
  return _read(files.first);
}

/// Multi-file variant of [pickImportFile]. Returns [] if cancelled.
Future<List<({String name, Uint8List bytes})>> pickImportFiles() async {
  final input = html.FileUploadInputElement()
    ..accept = _importAccept
    ..multiple = true;
  input.click();
  await input.onChange.first;
  final files = input.files;
  if (files == null || files.isEmpty) return const [];
  final out = <({String name, Uint8List bytes})>[];
  for (final f in files) {
    final r = await _read(f);
    if (r != null) out.add(r);
  }
  return out;
}

Future<({String name, Uint8List bytes})?> pickCameraPhoto() async {
  final input = html.FileUploadInputElement()
    ..accept = 'image/*'
    ..multiple = false;
  input.setAttribute('capture', 'environment');
  input.click();
  await input.onChange.first;
  final files = input.files;
  if (files == null || files.isEmpty) return null;
  return _read(files.first);
}
