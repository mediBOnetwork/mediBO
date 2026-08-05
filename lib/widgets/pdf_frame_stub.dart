import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

/// Native PDF frame: no in-app PDF rasterizer, so render a tappable icon that
/// opens the PDF url in the platform's external viewer. Same public
/// constructor as the web impl.
class PdfFrame extends StatelessWidget {
  final String url;
  final bool interactive;
  const PdfFrame({super.key, required this.url, this.interactive = true});

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: () =>
          launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication),
      child: const Center(
        child: Icon(Icons.picture_as_pdf, size: 48, color: Color(0xFF6B7280)),
      ),
    );
  }
}
