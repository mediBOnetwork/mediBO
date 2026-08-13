import 'dart:typed_data';

import 'package:image_picker/image_picker.dart';

/// Native image pick: camera is the natural selfie source. Returns the picked
/// image's bytes and name, or null if the user cancelled or an error occurred.
Future<({Uint8List bytes, String name})?> pickImageBytes({bool camera = true}) async {
  try {
    final x = await ImagePicker()
        .pickImage(source: camera ? ImageSource.camera : ImageSource.gallery);
    if (x == null) return null;
    return (bytes: await x.readAsBytes(), name: x.name);
  } catch (_) {
    return null;
  }
}
