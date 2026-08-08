// Native (Android) file/photo picking — mirrors file_pick_io_web.dart.
import 'dart:typed_data';
import 'package:file_picker/file_picker.dart';
import 'package:image_picker/image_picker.dart';

const List<String> _importExts = [
  'csv', 'xlsx', 'xls', 'pdf', 'ods', 'tsv', 'txt', 'docx', 'doc',
  'html', 'htm', 'jpg', 'jpeg', 'png', 'webp', 'heic', 'heif', 'gif',
];

Future<({String name, Uint8List bytes})?> pickImportFile() async {
  final res = await FilePicker.pickFiles(
    type: FileType.custom,
    allowedExtensions: _importExts,
    withData: true,
  );
  if (res == null || res.files.isEmpty) return null;
  final f = res.files.first;
  final bytes = f.bytes;
  if (bytes == null) return null;
  return (name: f.name, bytes: bytes);
}

/// Multi-file variant of [pickImportFile]. Returns [] if cancelled.
Future<List<({String name, Uint8List bytes})>> pickImportFiles() async {
  final res = await FilePicker.pickFiles(
    type: FileType.custom,
    allowedExtensions: _importExts,
    withData: true,
    allowMultiple: true,
  );
  if (res == null) return const [];
  return [
    for (final f in res.files)
      if (f.bytes != null) (name: f.name, bytes: f.bytes!),
  ];
}

Future<({String name, Uint8List bytes})?> pickCameraPhoto() async {
  final x = await ImagePicker().pickImage(source: ImageSource.camera);
  if (x == null) return null;
  return (name: x.name, bytes: await x.readAsBytes());
}
