import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'platform_unavailable.dart';

class BulkUploadScreen extends StatelessWidget {
  final List<({String name, int qty})>? preloadedItems;
  final String? preloadedTitle;
  const BulkUploadScreen({super.key, this.preloadedItems, this.preloadedTitle});

  static VoidCallback? navToBulkUpload;
  static Future<void> Function(String orderId)? onWaOrderPlaced;

  static void startWaConvert({
    required Uint8List imageBytes,
    required String mimeType,
    required String imageName,
    required String imageId,
    required String userId,
    required String customerName,
    required String pharmacy,
    required String phone,
    required String address,
    required bool isApproved,
  }) {}

  @override
  Widget build(BuildContext context) => const PlatformUnavailableScreen();
}
