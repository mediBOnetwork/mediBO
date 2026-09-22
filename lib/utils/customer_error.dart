// lib/utils/customer_error.dart — CMD #2156 (Om)
//
// The customer app never shows technical error text: no PostgrestException,
// no "57014" or "statement timeout", no stack trace, no raw JSON. A backend
// sentence written FOR a shopper still reads through; anything that looks like
// plumbing becomes ui_copy 'net.load_failed' ("Couldn't load this. Check your
// internet."). The decision is one pure function so the test can hold it down.
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../design_tokens.dart';
import '../services/ui_copy.dart';
import '../user_state.dart';
import 'render_log.dart';

class CustomerError {
  CustomerError._();

  /// Markers that mean "this is plumbing, not a sentence for a shopper".
  static final RegExp _technical = RegExp(
    r'exception|error:|statement timeout|canceling statement|\b\d{5}\b|'
    r'\bcode\b|\bdetails\b|\bhint\b|stack|#0 |\bat [\w.]+\(|'
    r'socket|xmlhttprequest|clientexception|failed host lookup|timeout|'
    r'connection|network|http|postgrest|supabase|jwt|pgrst|null check|'
    r'nosuchmethod|typeerror|is not a subtype|rangeerror|formatexception|'
    r'[{}\[\]<>]|\b[a-z]+(_[a-z0-9]+)+\b',
    caseSensitive: false,
  );

  /// Is [text] safe to print to a shopper as it stands?
  static bool isFriendly(String text) {
    final t = text.trim();
    if (t.isEmpty || t.length > 160) return false;
    return !_technical.hasMatch(t);
  }

  /// The one line a customer screen prints for [e]: the backend's own human
  /// message when it is one, else `net.load_failed`.
  static String text(Object? e) {
    String raw;
    if (e is PostgrestException) {
      raw = e.message;
    } else if (e is String) {
      raw = e;
    } else {
      raw = e?.toString() ?? '';
    }
    if (raw.startsWith('Exception: ')) raw = raw.substring(11);
    if (isFriendly(raw)) return raw.trim();
    RenderLog.write('c2156_error_masked', 1);
    return loadFailed;
  }

  /// Staff = an admin, partner or supplier session. Everyone else — a guest
  /// or a pharmacy — is on the customer app, where this class applies.
  static bool isStaff(BuildContext context) {
    final u = context.getInheritedWidgetOfExactType<UserState>()?.notifier;
    // No session scope at all (a bare test harness): keep the old behaviour.
    if (u == null) return true;
    return u.isAdmin || u.isPartner || u.isSupplier || u.isPendingSupplier;
  }

  static String get loadFailed => UiCopy.t('net.load_failed');
  static String get tryAgain => UiCopy.t('net.try_again');
}

/// CMD #2156 — the ONE small card a part of a customer screen shows in its own
/// place when it still fails after the quiet retries: `net.load_failed` and a
/// `net.try_again` button. Never red — the rest of the screen still works.
class CustomerLoadFailedCard extends StatelessWidget {
  const CustomerLoadFailedCard({super.key, required this.onRetry, this.message});

  final VoidCallback onRetry;

  /// A friendly override (already passed through [CustomerError.text]).
  final String? message;

  @override
  Widget build(BuildContext context) {
    RenderLog.write('c2156_load_failed_card', 1);
    final line = (message == null || message!.isEmpty) ? CustomerError.loadFailed : message!;
    return Semantics(
      identifier: 'c2156_load_failed',
      child: Container(
        margin: EdgeInsets.all(Ds.space.x16),
        padding: EdgeInsets.all(Ds.space.x16),
        decoration: BoxDecoration(
          color: Ds.c.surface,
          borderRadius: Ds.r.rCard,
          border: Border.all(color: Ds.c.divider),
        ),
        child: Row(
          children: [
            Icon(Icons.wifi_off_rounded, size: Ds.space.x24, color: Ds.c.textSecondary),
            SizedBox(width: Ds.space.x12),
            Expanded(child: Text(line, style: Ds.t.body)),
            SizedBox(width: Ds.space.x8),
            SizedBox(
              height: Ds.touch.minTarget,
              child: OutlinedButton(
                onPressed: onRetry,
                child: Text(CustomerError.tryAgain, maxLines: 1),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
