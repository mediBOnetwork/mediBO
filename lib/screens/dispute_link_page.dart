import 'package:flutter/material.dart';

import '../utils/render_log.dart';
import 'public/dispute_form_screen.dart';

/// Public supplier dispute form — accessed via a short-code redirect.
/// Delegates all logic to [DisputeFormScreen]; emits the c317 render-log key.
class DisputeLinkPage extends StatelessWidget {
  final String token;
  const DisputeLinkPage({super.key, required this.token});

  @override
  Widget build(BuildContext context) {
    RenderLog.write('c317_dispute_viewer', 'token=${token.length > 8 ? token.substring(0, 8) : token}');
    return DisputeFormScreen(token: token);
  }
}
