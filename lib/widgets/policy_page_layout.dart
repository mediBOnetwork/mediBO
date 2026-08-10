import 'package:flutter/material.dart';
import '../services/ui_copy.dart';
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

  /// CHANGE #611 — About renders its header from `about_screen()`. When these
  /// are null the 5 static policy pages keep their existing wordmark exactly.
  final String? headerName;
  final String? headerTagline;

  const PolicyPageLayout({
    super.key,
    required this.title,
    this.lastUpdated,
    required this.child,
    this.headerName,
    this.headerTagline,
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
                      child: Padding(
                        padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 4),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Icon(Icons.arrow_back_ios_new, size: 13, color: Brand.inkMuted),
                            const SizedBox(width: 4),
                            Text(c('common.back'),
                                style: const TextStyle(fontSize: 14, color: Brand.inkMuted)),
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
                        Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(headerName ?? c('brand.name'),
                                style: const TextStyle(
                                    fontSize: 22,
                                    fontWeight: FontWeight.w800,
                                    color: Brand.ink,
                                    letterSpacing: -0.4)),
                            Text(headerTagline ?? c('brand.tagline'),
                                style: const TextStyle(
                                    fontSize: 12, color: Brand.inkMuted)),
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
