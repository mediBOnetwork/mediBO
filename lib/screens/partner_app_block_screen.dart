// CMD #2100 — "Use the mediBO app": the backend's answer for a customer
// account signed in on the PARTNER app (in.medibo.partner).
//
// One payload, printed verbatim: app_home().block carries title, body, hint,
// cta_label, cta_url and signout_label. Nothing here decides who sees it —
// the root paints this screen only when app_home() said blocked:true — and no
// string on it is written in Dart.
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../design_tokens.dart';

/// Desktop is secondary: the card stops growing here so a wide window does
/// not stretch one paragraph across the whole screen (same as the storefront).
const double _kMaxContent = 480;

class PartnerAppBlockScreen extends StatelessWidget {
  const PartnerAppBlockScreen({
    super.key,
    required this.payload,
    required this.onSignOut,
    this.launch,
  });

  /// app_home().block, verbatim.
  final Map<String, dynamic> payload;
  final Future<void> Function() onSignOut;

  /// Test seam for the store link. Null -> url_launcher.
  final Future<void> Function(Uri uri)? launch;

  String _s(String key) => (payload[key] as String?) ?? '';

  Future<void> _openStore() async {
    final url = _s('cta_url');
    if (url.isEmpty) return;
    final uri = Uri.tryParse(url);
    if (uri == null) return;
    if (launch != null) {
      await launch!(uri);
      return;
    }
    try {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    final hint = _s('hint');
    final body = _s('body');
    return Scaffold(
      backgroundColor: Ds.c.bg,
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: EdgeInsets.all(Ds.space.x24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: _kMaxContent),
              child: Container(
                width: double.infinity,
                padding: EdgeInsets.all(Ds.space.x24),
                decoration: BoxDecoration(
                  color: Ds.c.surface,
                  borderRadius: Ds.r.rCard,
                  boxShadow: Ds.elevation.e1,
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(_s('title'), style: Ds.t.title),
                    if (body.isNotEmpty) ...[
                      SizedBox(height: Ds.space.x12),
                      Text(body, style: Ds.t.bodySecondary),
                    ],
                    if (hint.isNotEmpty) ...[
                      SizedBox(height: Ds.space.x8),
                      Text(hint, style: Ds.t.caption),
                    ],
                    SizedBox(height: Ds.space.x24),
                    Semantics(
                      identifier: 'partner_block_cta',
                      button: true,
                      child: SizedBox(
                        width: double.infinity,
                        height: Ds.touch.minTarget,
                        child: FilledButton(
                          onPressed: _openStore,
                          child: Text(_s('cta_label')),
                        ),
                      ),
                    ),
                    SizedBox(height: Ds.space.x12),
                    Semantics(
                      identifier: 'partner_block_signout',
                      button: true,
                      child: SizedBox(
                        width: double.infinity,
                        height: Ds.touch.minTarget,
                        child: OutlinedButton(
                          onPressed: () => onSignOut(),
                          child: Text(_s('signout_label')),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
