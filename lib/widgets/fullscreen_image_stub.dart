import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

void openFullscreenImage(BuildContext context, String imageUrl) {
  showDialog(
    context: context,
    barrierColor: Colors.black.withOpacity(0.92),
    builder: (ctx) => GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => Navigator.of(ctx).pop(),
      child: Stack(children: [
        Positioned.fill(child: Container(color: Colors.transparent)),
        Center(
          child: SizedBox(
            width: MediaQuery.of(ctx).size.width * 0.95,
            height: MediaQuery.of(ctx).size.height * 0.85,
            child: InteractiveViewer(
              child: CachedNetworkImage(
                imageUrl: imageUrl,
                fit: BoxFit.contain,
              ),
            ),
          ),
        ),
      ]),
    ),
  );
}
