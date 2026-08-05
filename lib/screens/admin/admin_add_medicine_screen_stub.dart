import 'dart:typed_data';
import 'package:flutter/material.dart';
import '../platform_unavailable.dart';

class AdminAddMedicineScreen extends StatelessWidget {
  final Uint8List? preloadedBytes;
  final String? preloadedFileName;
  final VoidCallback? onImportComplete;
  const AdminAddMedicineScreen({
    super.key,
    this.preloadedBytes,
    this.preloadedFileName,
    this.onImportComplete,
  });
  @override
  Widget build(BuildContext context) => const PlatformUnavailableScreen();
}
