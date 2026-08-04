// CHANGE — WhatsApp campaign builder + tracking link redirect (PART A).
//
// /r/<code> — the short link inside a campaign message. PUBLIC: no login, no
// admin gate, opened on a logged-out phone browser straight from WhatsApp.
//
// wa_link_click() is the whole feature. It stamps the click (and the recipient's
// clicked_at, which is what click and revenue attribution are counted from) and
// returns where to go. This page therefore does exactly three things: call it,
// hand the browser the target, and — when the code is unknown — print the
// backend's own expiry copy.
//
// The app must never invent the destination. There is no "if it looks like a
// product go to /product/..." here: the target is a column, and guessing at one
// would put a customer on the wrong page with a click already counted.
import 'package:flutter/material.dart';

import '../../features/whatsapp/data/wa_campaign_api.dart';
import '../../url_sync.dart' as url_sync;
import '../../utils/render_log.dart';

/// Copy of last resort. Reachable ONLY when wa_link_click() could not be
/// reached at all (the device is offline, or Supabase is down) — in that case
/// there is no payload to print, so there is nothing to render verbatim. Every
/// path where the backend DID answer renders the backend's own strings.
const _kOfflineTitle = 'That link has expired';
const _kOfflineNote = 'Browse mediBO to find what you were looking for.';
const _kOfflineCta = 'Go to mediBO';
const _kOfflineHome = '/';

class WaLinkRedirectPage extends StatefulWidget {
  final String code;

  /// Injected for tests; production hits Supabase.
  final WaLinkClickRpc? linkClickRpc;

  /// Injected for tests. Production replaces the browser location so the Back
  /// button returns to WhatsApp rather than bouncing through this resolver.
  final void Function(String url)? onRedirect;

  const WaLinkRedirectPage({
    super.key,
    required this.code,
    this.linkClickRpc,
    this.onRedirect,
  });

  @override
  State<WaLinkRedirectPage> createState() => _WaLinkRedirectPageState();
}

class _WaLinkRedirectPageState extends State<WaLinkRedirectPage> {
  bool _resolving = true;

  // Expiry copy, taken from the payload when the backend answered.
  String _title = _kOfflineTitle;
  String _note = _kOfflineNote;
  String _cta = _kOfflineCta;
  String _home = _kOfflineHome;

  @override
  void initState() {
    super.initState();
    try {
      RenderLog.write('wa_link_route', 'code=${widget.code}');
    } catch (_) {}
    _resolve();
  }

  void _go(String url) {
    final redirect = widget.onRedirect ?? url_sync.replaceLocation;
    redirect(url);
  }

  Future<void> _resolve() async {
    final rpc = widget.linkClickRpc ?? waLinkClick;
    try {
      // The code is handed over EXACTLY as it arrived in the URL. No trim, no
      // case-fold: the app does not know what a valid code looks like, and
      // wa_links.code is matched with plain equality.
      final res = await rpc(widget.code);
      if (!mounted) return;

      final ok = res['ok'] == true;
      final target = (res['target'] ?? '').toString();

      if (ok && target.isNotEmpty) {
        try {
          RenderLog.write('wa_link_hit', 'ok=1');
        } catch (_) {}
        // Leave the spinner up: the browser is on its way out of this page.
        _go(target);
        return;
      }

      // Unknown link (or ok:true with no target, which we cannot navigate to).
      // Every string below is the backend's — this page writes none of them.
      setState(() {
        _resolving = false;
        _title = _str(res['expired_title'], _kOfflineTitle);
        _note = _str(res['expired_note'], _kOfflineNote);
        _cta = _str(res['expired_cta'], _kOfflineCta);
        _home = _str(res['home_route'], _kOfflineHome);
      });
      try {
        RenderLog.write('wa_link_expired', 'code=${widget.code}');
      } catch (_) {}
    } catch (e) {
      // Never a crash, never a blank page — the expiry card is also the
      // couldn't-reach-the-server card.
      if (!mounted) return;
      setState(() => _resolving = false);
      try {
        RenderLog.write('wa_link_error', e.toString());
      } catch (_) {}
    }
  }

  /// Falls back only when the field is absent or empty — an empty string here
  /// would render a blank card, which reads as a broken page.
  static String _str(dynamic v, String fallback) {
    final s = (v ?? '').toString();
    return s.isEmpty ? fallback : s;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF5F6F8),
      body: Center(
        child: _resolving
            ? const SizedBox(
                width: 28,
                height: 28,
                child: CircularProgressIndicator(
                  strokeWidth: 2.5,
                  valueColor: AlwaysStoppedAnimation(Color(0xFF1B7A43)),
                ),
              )
            : _expiredCard(),
      ),
    );
  }

  Widget _expiredCard() => Padding(
        padding: const EdgeInsets.all(24),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 380),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.link_off_rounded,
                  size: 44, color: Color(0xFF9CA3AF)),
              const SizedBox(height: 16),
              Text(
                _title,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w700,
                  color: Color(0xFF111827),
                ),
              ),
              const SizedBox(height: 8),
              Text(
                _note,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  fontSize: 14,
                  height: 1.4,
                  color: Color(0xFF6B7280),
                ),
              ),
              const SizedBox(height: 20),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  onPressed: () => _go(_home),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF1B7A43),
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10),
                    ),
                  ),
                  child: Text(
                    _cta,
                    style: const TextStyle(
                        fontSize: 15, fontWeight: FontWeight.w600),
                  ),
                ),
              ),
            ],
          ),
        ),
      );
}
