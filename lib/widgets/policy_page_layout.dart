import 'package:flutter/material.dart';
import '../theme.dart';
import '../utils/render_log.dart';

/// Centered, branded page layout shared by all 6 policy/info pages.
/// Matches the visual style of the static /about page:
///   - white background, SafeArea, scrollable
///   - centered max-width 680 container
///   - mediBO branded header block (icon + wordmark + tagline) + divider
///   - slim back affordance (not a heavy AppBar)
///   - page title + optional "Last updated:" line
///   - [child] body below
class PolicyPageLayout extends StatelessWidget {
  final String title;
  final String? lastUpdated;
  final Widget child;

  const PolicyPageLayout({
    super.key,
    required this.title,
    this.lastUpdated,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    RenderLog.write('screen', title.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '_'));
    RenderLog.write('layout', 'policy_page_layout_v1');
    RenderLog.write('c425_logo', 'mark=medibo_logo;src=asset');

    return Scaffold(
      backgroundColor: Colors.white,
      body: SafeArea(
        child: SingleChildScrollView(
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 680),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(20, 16, 20, 56),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // ── Slim back affordance ──────────────────────────────
                    InkWell(
                      onTap: () => Navigator.of(context).pop(),
                      borderRadius: BorderRadius.circular(8),
                      child: const Padding(
                        padding: EdgeInsets.symmetric(vertical: 6, horizontal: 4),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(Icons.arrow_back_ios_new, size: 13, color: Brand.inkMuted),
                            SizedBox(width: 4),
                            Text('Back',
                                style: TextStyle(fontSize: 14, color: Brand.inkMuted)),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: 20),
                    // ── Branded header (mirrors /about) ───────────────────
                    Row(
                      children: [
                        Image.asset('assets/images/medibo_logo.png',
                            height: 30, filterQuality: FilterQuality.medium),
                        const SizedBox(width: 12),
                        const Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text('mediBO',
                                style: TextStyle(
                                    fontSize: 22,
                                    fontWeight: FontWeight.w800,
                                    color: Brand.ink,
                                    letterSpacing: -0.4)),
                            Text('B2B Pharmacy Platform',
                                style: TextStyle(fontSize: 12, color: Brand.inkMuted)),
                          ],
                        ),
                      ],
                    ),
                    const SizedBox(height: 16),
                    const Divider(),
                    const SizedBox(height: 20),
                    // ── Page title ────────────────────────────────────────
                    Text(title,
                        style: const TextStyle(
                            fontSize: 22,
                            fontWeight: FontWeight.w800,
                            color: Brand.ink)),
                    if (lastUpdated != null) ...[
                      const SizedBox(height: 6),
                      Text(lastUpdated!,
                          style: const TextStyle(
                              fontSize: 13, color: Brand.inkMuted)),
                    ],
                    const SizedBox(height: 24),
                    // ── Page body ─────────────────────────────────────────
                    child,
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
