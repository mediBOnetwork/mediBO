import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../utils/render_log.dart';
import 'public/public_order_page.dart';
import 'public/inquiry_form_screen.dart';
import 'public/dispute_form_screen.dart';

// CHANGE #318: render viewer IN PLACE — no navigation, no redirect.
// The short /<CODE> URL stays in the address bar after the page loads.

const _kGreen       = Color(0xFF1B7A43);
const _kBg          = Color(0xFFF5F6F8);
const _kCard        = Color(0xFFFFFFFF);
const _kBorder      = Color(0xFFE5E7EB);
const _kTextPrimary = Color(0xFF111827);
const _kTextMuted   = Color(0xFF6B7280);

/// Resolves a short tracking code (e.g. SPO300626SAG100O1) to a full token
/// and renders the correct viewer INLINE — the /<CODE> URL stays in the bar.
///
/// CHANGE #318 — NO context.go / context.push / pushReplacement / Navigator
/// anywhere in the resolve→render path. Viewer widget returned directly from
/// build() once the resolve_code RPC completes.
class CodeResolverPage extends StatefulWidget {
  final String code;
  const CodeResolverPage({super.key, required this.code});

  @override
  State<CodeResolverPage> createState() => _CodeResolverPageState();
}

class _CodeResolverPageState extends State<CodeResolverPage> {
  // null = still loading; 'notfound'|'badcode'|'error' = failed.
  String? _error;
  // Resolved kind ('order' | 'inquiry' | 'dispute') and its token.
  String? _kind;
  String? _token;

  @override
  void initState() {
    super.initState();
    // Load-time proof: bare-code route registered + resolves inline (#318).
    try { RenderLog.write('c317_code_route_built', 'code=${widget.code}'); } catch (_) {}
    try { RenderLog.write('c318_no_redirect', 'inline_render=#318'); } catch (_) {}
    _resolve();
  }

  Future<void> _resolve() async {
    try { RenderLog.write('c317_resolve_called', 'code=${widget.code}'); } catch (_) {}
    try {
      final result = await Supabase.instance.client
          .rpc('resolve_code', params: {'p_code': widget.code.toUpperCase().trim()});
      if (!mounted) return;

      final data = result is Map
          ? Map<String, dynamic>.from(result)
          : <String, dynamic>{};

      final kind  = data['kind']  as String? ?? '';
      final token = data['token'] as String? ?? '';
      final err   = data['error'] as String?;

      if (err != null || kind.isEmpty || token.isEmpty) {
        setState(() { _error = err ?? 'notfound'; });
        return;
      }

      // Store kind + token; build() returns the viewer widget inline.
      // NO navigation. URL stays /<CODE>.
      setState(() { _kind = kind; _token = token; });
    } catch (_) {
      if (!mounted) return;
      setState(() { _error = 'error'; });
    }
  }

  @override
  Widget build(BuildContext context) {
    // ── Resolved: render viewer inline ──────────────────────────────────────
    final token = _token;
    final kind  = _kind;
    if (token != null && kind != null) {
      try { RenderLog.write('c318_resolver_inline', 'kind=$kind'); } catch (_) {}
      if (kind == 'order') {
        return PublicOrderPage(token: token);
      } else if (kind == 'inquiry') {
        return InquiryFormScreen(token: token);
      } else if (kind == 'dispute') {
        return DisputeFormScreen(token: token);
      }
    }

    // ── Error: not found ─────────────────────────────────────────────────────
    if (_error != null) {
      return _NotFoundScaffold(code: widget.code);
    }

    // ── Loading spinner ──────────────────────────────────────────────────────
    return Scaffold(
      backgroundColor: _kBg,
      appBar: AppBar(
        backgroundColor: _kGreen,
        elevation: 0,
        automaticallyImplyLeading: false,
        title: const Text('mediBO',
            style: TextStyle(
                color: Colors.white, fontWeight: FontWeight.w700, fontSize: 18)),
      ),
      body: const Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            CircularProgressIndicator(color: _kGreen, strokeWidth: 2.5),
            SizedBox(height: 16),
            Text('Opening your link…',
                style: TextStyle(fontSize: 15, color: _kTextMuted)),
          ],
        ),
      ),
    );
  }
}

class _NotFoundScaffold extends StatelessWidget {
  final String code;
  const _NotFoundScaffold({required this.code});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _kBg,
      appBar: AppBar(
        backgroundColor: _kGreen,
        elevation: 0,
        automaticallyImplyLeading: false,
        title: const Text('mediBO',
            style: TextStyle(
                color: Colors.white, fontWeight: FontWeight.w700, fontSize: 18)),
      ),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 72, height: 72,
                decoration: BoxDecoration(
                  color: const Color(0xFFF3F4F6),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: const Icon(Icons.link_off_outlined,
                    size: 36, color: Color(0xFF9CA3AF)),
              ),
              const SizedBox(height: 20),
              const Text(
                'Link not found or expired',
                style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w700,
                    color: _kTextPrimary),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 8),
              const Text(
                'Please contact mediBO for assistance.',
                style: TextStyle(fontSize: 14, color: _kTextMuted),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 28),
              Container(
                decoration: BoxDecoration(
                  color: _kCard,
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: _kBorder),
                ),
                child: InkWell(
                  borderRadius: BorderRadius.circular(10),
                  // Navigate home — this is intentional (going TO home, not a token route).
                  onTap: () => Navigator.of(context).pushReplacementNamed('/'),
                  child: const Padding(
                    padding: EdgeInsets.symmetric(horizontal: 24, vertical: 14),
                    child: Text('Go to mediBO',
                        style: TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                            color: _kGreen)),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
