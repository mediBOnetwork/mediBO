import 'package:flutter/material.dart';

import '../../design_tokens.dart';
import '../../widgets/substitute_choice.dart';

/// CMD #366 row 176 — the public substitute page, reached from the WhatsApp
/// link `/substitute/<token>`. No auth: the token in the URL is the
/// authorisation, exactly the way `/stock-update/<token>` already works, which
/// is the pattern Om named.
///
/// A customer with no app still gets the SAME dropdown and the same three
/// answers as one using the app, because both render the one
/// [SubstituteChoice] widget over the one `sub_offer_*` contract. Nothing is
/// substituted here either: this records the customer's answer, and an admin
/// still has to apply it against a backend that refuses without an approval.
class SubstituteTokenScreen extends StatefulWidget {
  final String token;
  const SubstituteTokenScreen({super.key, required this.token});

  @override
  State<SubstituteTokenScreen> createState() => _SubstituteTokenScreenState();
}

class _SubstituteTokenScreenState extends State<SubstituteTokenScreen> {
  Map<String, dynamic>? _offer;
  bool _loading = true;
  String _error = '';
  bool _done = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = '';
    });
    try {
      final res =
          await SubstituteChoice.rpc('sub_offer_page', {'p_token': widget.token});
      if (!mounted) return;
      if (res is Map) {
        final m = res.cast<String, dynamic>();
        // ok:false carries the backend's own sentence — an expired or unknown
        // token explains itself; this page never writes that copy.
        if (m['ok'] == false) {
          setState(() {
            _error = (m['message'] ?? m['error'] ?? '').toString();
            _loading = false;
          });
          return;
        }
        setState(() {
          _offer = m;
          _done = (m['status'] ?? '') != 'offered';
          _loading = false;
        });
      } else {
        setState(() => _loading = false);
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = e.toString();
          _loading = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final offer = _offer;
    return Scaffold(
      backgroundColor: Ds.c.bg,
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: EdgeInsets.all(Ds.space.x16),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 520),
              child: Container(
                padding: EdgeInsets.all(Ds.space.x24),
                decoration: BoxDecoration(
                  color: Ds.c.surface,
                  borderRadius: Ds.r.rCard,
                  border: Border.all(color: Ds.c.divider),
                ),
                child: _loading
                    ? Padding(
                        padding: EdgeInsets.all(Ds.space.x32),
                        child: const Center(
                            child: CircularProgressIndicator(strokeWidth: 2)),
                      )
                    : _error.isNotEmpty
                        ? Text(_error,
                            style: Ds.t.body.copyWith(color: Ds.c.danger))
                        : offer == null
                            ? const SizedBox.shrink()
                            : _done
                                ? Text(
                                    (offer['done_label'] ?? '').toString(),
                                    style: Ds.t.body
                                        .copyWith(color: Ds.c.success),
                                  )
                                : SubstituteChoice(
                                    offer: offer,
                                    token: widget.token,
                                    onDecided: (fresh) => setState(() {
                                      _offer = fresh;
                                      _done = true;
                                    }),
                                  ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
