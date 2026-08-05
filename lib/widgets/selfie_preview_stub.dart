import 'dart:typed_data';

import 'package:flutter/material.dart';

/// Native selfie preview: paints the picked bytes and opens the fullscreen
/// viewer on tap. Same builder signature as the web impl.
Widget selfiePreview({
  required Uint8List bytes,
  required String dataUrl,
  required VoidCallback onTap,
}) {
  return GestureDetector(
    onTap: onTap,
    child: Image.memory(bytes, fit: BoxFit.cover),
  );
}
