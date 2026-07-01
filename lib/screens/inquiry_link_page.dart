import 'package:flutter/material.dart';

import '../utils/render_log.dart';
import 'public/inquiry_form_screen.dart';

/// Public supplier inquiry form — accessed via a short-code redirect.
/// Delegates all logic to [InquiryFormScreen]; emits the c317 render-log key.
class InquiryLinkPage extends StatelessWidget {
  final String token;
  const InquiryLinkPage({super.key, required this.token});

  @override
  Widget build(BuildContext context) {
    RenderLog.write('c317_inquiry_viewer', 'token=${token.length > 8 ? token.substring(0, 8) : token}');
    return InquiryFormScreen(token: token);
  }
}
