import 'package:flutter/material.dart';

import '../design_tokens.dart';
import '../services/test_session.dart';
import 'outbound_receipt_sheet.dart';

/// CHANGE #573 — the unmissable TEST MODE strip.
///
/// It is mounted once, in `MaterialApp.builder`, above every route of every
/// role, exactly like the update bar. That placement is the point: Om walks
/// the flow from an admin, a customer, a supplier, a partner and a rider
/// login, and none of those screens has to know test mode exists.
///
/// The host reflows the page (SafeArea + Column) rather than floating over it,
/// because a banner that can be scrolled behind is a banner he can forget.
///
/// CMD #1848 — the session is bound to THIS INSTALL now. `test_session_banner()`
/// answers `on:true` only to the device carrying the session's token (whoever
/// is signed in there); every other device shows nothing, because nothing of
/// its is being stamped. The strip names WHOSE session it is
/// (`owner_label`), when it auto-ends (`ends_label`), and carries the one
/// action — End & purge — whose every word, confirm sentence and result
/// message are the backend's.
class TestModeBannerHost extends StatelessWidget {
  const TestModeBannerHost({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<Map<String, dynamic>>(
      valueListenable: TestSessionState.instance.banner,
      builder: (context, payload, _) {
        if (payload['on'] != true) return child;
        return Column(
          children: [
            TestModeBanner(
              payload: payload,
              onEndPurge: TestSessionState.instance.endAndPurge,
              onReceipt: TestSessionState.instance.receipt,
            ),
            Expanded(child: child),
          ],
        );
      },
    );
  }
}

/// The strip itself — pure presentation, so a widget test mounts it with a
/// fixture payload and no network, no timer and no service singleton. The
/// End & purge tap calls [onEndPurge]; absent, the button is inert.
class TestModeBanner extends StatelessWidget {
  const TestModeBanner({
    super.key,
    required this.payload,
    this.onEndPurge,
    this.onReceipt,
  });

  final Map<String, dynamic> payload;

  /// Runs the backend's end-and-purge and returns its payload; the banner
  /// shows that payload's `message` verbatim.
  final Future<Map<String, dynamic>> Function()? onEndPurge;

  /// CMD #1849 — reads `test_session_receipt()`: everything this session would
  /// have sent. Absent, the sheet is exactly the confirm sheet it always was.
  final Future<Map<String, dynamic>> Function()? onReceipt;

  String _s(String key) {
    final v = payload[key];
    return v is String ? v : '';
  }

  /// The action is drawn only when the BACKEND says this person may end the
  /// session (`can_end`) and has a word for the button. No Dart rule.
  bool get _showEnd => payload['can_end'] == true && _s('end_action').isNotEmpty;

  Future<void> _confirmAndEnd(BuildContext context) async {
    final confirm = _s('end_confirm');
    final action = _s('end_action');
    final cancel = _s('end_cancel');
    var ok = true;
    // CMD #1849 — the sheet exists to SHOW something before it destroys
    // something: the confirm sentence, and now the receipt of everything this
    // session would have sent. Either one is reason enough to open it; with
    // neither, the tap still runs straight through as it always did.
    if (confirm.isNotEmpty || onReceipt != null) {
      ok = await showModalBottomSheet<bool>(
            context: context,
            backgroundColor: Ds.c.surface,
            isScrollControlled: true,
            shape: RoundedRectangleBorder(borderRadius: Ds.r.rSheet),
            builder: (ctx) => _EndPurgeSheet(
              confirm: confirm,
              action: action,
              cancel: cancel,
              onReceipt: onReceipt,
            ),
          ) ==
          true;
    }
    if (!ok) return;
    final run = onEndPurge;
    if (run == null) return;
    final res = await run();
    if (!context.mounted) return;
    final msg = (res['message'] ?? res['error'] ?? '').toString();
    if (msg.isNotEmpty) {
      ScaffoldMessenger.maybeOf(context)
          ?.showSnackBar(SnackBar(content: Text(msg)));
    }
  }

  @override
  Widget build(BuildContext context) {
    final label = _s('label');
    final owner = _s('owner_label');
    final ends = _s('ends_label');
    final caption = [label, owner, ends].where((s) => s.isNotEmpty).join('  ·  ');
    return Material(
      color: Ds.c.danger,
      child: SafeArea(
        bottom: false,
        child: Padding(
          padding: EdgeInsets.symmetric(
            horizontal: Ds.space.x16,
            vertical: Ds.space.x8,
          ),
          child: Row(
            children: [
              Container(
                padding: EdgeInsets.symmetric(
                  horizontal: Ds.space.x8,
                  vertical: Ds.space.x4,
                ),
                decoration: BoxDecoration(
                  color: Ds.c.surface,
                  borderRadius: Ds.r.rChip,
                ),
                child: Text(
                  _s('badge'),
                  style: Ds.t.caption.copyWith(
                    color: Ds.c.danger,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              SizedBox(width: Ds.space.x12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      _s('text'),
                      style: Ds.t.body.copyWith(
                        color: Ds.c.surface,
                        fontWeight: FontWeight.w700,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    if (caption.isNotEmpty)
                      Text(
                        caption,
                        style: Ds.t.caption.copyWith(color: Ds.c.surface),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                  ],
                ),
              ),
              if (_showEnd) ...[
                SizedBox(width: Ds.space.x12),
                SizedBox(
                  height: Ds.touch.minTarget,
                  child: OutlinedButton(
                    key: const ValueKey('test_session_end_purge'),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: Ds.c.surface,
                      side: BorderSide(color: Ds.c.surface),
                      shape: RoundedRectangleBorder(
                          borderRadius: Ds.r.rButton),
                      padding: EdgeInsets.symmetric(
                          horizontal: Ds.space.x12),
                    ),
                    onPressed: () => _confirmAndEnd(context),
                    child: Text(
                      _s('end_action'),
                      style: Ds.t.caption.copyWith(
                        color: Ds.c.surface,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}


/// The End & purge sheet — CMD #1849.
///
/// It asks the backend ONCE for the receipt and prints it above the confirm
/// sentence, so the last thing seen before a session's rows are destroyed is
/// the transcript of what that session would have sent. The sheet computes
/// nothing about the receipt: it hands the payload to [OutboundReceiptView],
/// which prints it. A refusal, an empty session or no reader at all leaves the
/// sheet as the plain confirm sheet — never a Dart-worded apology.
class _EndPurgeSheet extends StatefulWidget {
  const _EndPurgeSheet({
    required this.confirm,
    required this.action,
    required this.cancel,
    this.onReceipt,
  });

  final String confirm;
  final String action;
  final String cancel;
  final Future<Map<String, dynamic>> Function()? onReceipt;

  @override
  State<_EndPurgeSheet> createState() => _EndPurgeSheetState();
}

class _EndPurgeSheetState extends State<_EndPurgeSheet> {
  Map<String, dynamic>? _receipt;
  bool _loading = false;

  @override
  void initState() {
    super.initState();
    final read = widget.onReceipt;
    if (read == null) return;
    _loading = true;
    read().then((r) {
      if (!mounted) return;
      setState(() {
        _receipt = r;
        _loading = false;
      });
    });
  }

  @override
  Widget build(BuildContext context) {
    final r = _receipt;
    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.of(context).size.height * 0.85,
        ),
        child: Padding(
          padding: EdgeInsets.all(Ds.space.x24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Flexible(
                child: SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (_loading) const _ReceiptSkeleton(),
                      if (r != null) OutboundReceiptView(payload: r),
                      if (widget.confirm.isNotEmpty) ...[
                        if (_loading || r != null)
                          SizedBox(height: Ds.space.x24),
                        Text(widget.confirm, style: Ds.t.body),
                      ],
                    ],
                  ),
                ),
              ),
              SizedBox(height: Ds.space.x24),
              SizedBox(
                width: double.infinity,
                height: Ds.touch.minTarget,
                child: FilledButton(
                  style: FilledButton.styleFrom(
                    backgroundColor: Ds.c.danger,
                    shape: RoundedRectangleBorder(borderRadius: Ds.r.rButton),
                  ),
                  onPressed: () => Navigator.pop(context, true),
                  child: Text(widget.action,
                      style: Ds.t.body.copyWith(color: Ds.c.surface)),
                ),
              ),
              if (widget.cancel.isNotEmpty) ...[
                SizedBox(height: Ds.space.x8),
                SizedBox(
                  width: double.infinity,
                  height: Ds.touch.minTarget,
                  child: TextButton(
                    onPressed: () => Navigator.pop(context, false),
                    child: Text(widget.cancel,
                        style:
                            Ds.t.body.copyWith(color: Ds.c.textSecondary)),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// A skeleton, not a spinner: the receipt is a list, so the wait looks like the
/// list that is coming.
class _ReceiptSkeleton extends StatelessWidget {
  const _ReceiptSkeleton();

  @override
  Widget build(BuildContext context) {
    return Column(
      key: const ValueKey('outbound_receipt_loading'),
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var i = 0; i < 3; i++) ...[
          Container(
            height: Ds.space.x16,
            width: double.infinity,
            decoration: BoxDecoration(
              color: Ds.c.divider,
              borderRadius: Ds.r.rChip,
            ),
          ),
          SizedBox(height: Ds.space.x8),
        ],
      ],
    );
  }
}
