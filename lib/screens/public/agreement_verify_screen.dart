import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../design_tokens.dart';
import '../../utils/render_log.dart';

/// CMD #1986 — the page the QR in the agreement footer opens.
///
/// PUBLIC and anonymous, exactly the way `/stock-update/<token>` is: a printed
/// contract is read by a bank, a landlord or a drug inspector who has no mediBO
/// login, and `agreement_verify()` is granted to anon for that single purpose.
/// The code in the URL carries the first twelve characters of the sha256 that
/// was printed on the copy, so the backend can say whether the paper in the
/// reader's hand and the signature mediBO holds are the same document.
///
/// This screen decides NOTHING. The heading, the verdict word, its tone, the
/// explanation, every field label and the closing note all arrive from
/// `agreement_verify(p_code)` and are printed verbatim. Five verdicts —
/// verified, drifted, mismatch, void, not found — plus the unsigned preview,
/// are all just different payloads.
class AgreementVerifyScreen extends StatefulWidget {
  final String code;
  const AgreementVerifyScreen({super.key, required this.code});

  /// Test seam, same shape as StockUpdateFormScreen.rpcTransport.
  @visibleForTesting
  static Future<dynamic> Function(String fn, Map<String, dynamic>? params)?
      rpcTransport;

  static Future<dynamic> rpc(String fn, [Map<String, dynamic>? params]) {
    final t = rpcTransport;
    if (t != null) return t(fn, params);
    return Supabase.instance.client.rpc(fn, params: params);
  }

  @override
  State<AgreementVerifyScreen> createState() => _AgreementVerifyScreenState();
}

class _AgreementVerifyScreenState extends State<AgreementVerifyScreen> {
  bool _loading = true;
  Map<String, dynamic> _p = const {};

  @override
  void initState() {
    super.initState();
    _load();
  }

  Map<String, dynamic>? _asMap(dynamic raw) {
    final data = raw is List ? (raw.isEmpty ? null : raw.first) : raw;
    return data is Map ? data.cast<String, dynamic>() : null;
  }

  String _s(String k) => (_p[k] ?? '').toString();

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final map = _asMap(await AgreementVerifyScreen.rpc(
          'agreement_verify', {'p_code': widget.code}));
      if (!mounted) return;
      setState(() {
        _p = map ?? const {};
        _loading = false;
      });
      RenderLog.write('c1986_agreement_verify', _s('state'));
    } catch (_) {
      if (!mounted) return;
      setState(() => _loading = false);
    }
  }

  /// The backend names the tone; this maps its word onto the app's palette. It
  /// never picks a tone from the verdict itself.
  ({Color bg, Color fg}) _tone() {
    switch (_s('status_tone')) {
      case 'success':
        return (bg: Ds.c.successSoft, fg: Ds.c.success);
      case 'warning':
        return (bg: Ds.c.warningSoft, fg: Ds.c.warning);
      case 'danger':
        return (bg: Ds.c.dangerSoft, fg: Ds.c.danger);
      default:
        return (bg: Ds.c.infoSoft, fg: Ds.c.info);
    }
  }

  @override
  Widget build(BuildContext context) {
    final rows = (_p['rows'] is List) ? (_p['rows'] as List) : const [];
    final tone = _tone();
    return Scaffold(
      backgroundColor: Ds.c.bg,
      body: SafeArea(
        child: _loading
            ? const Center(child: CircularProgressIndicator())
            : LayoutBuilder(
                builder: (context, c) {
                  // Mobile first: the column is the viewport on a phone and
                  // stops growing past a comfortable measure on a desktop.
                  final wide = c.maxWidth > 640;
                  return SingleChildScrollView(
                    padding: EdgeInsets.symmetric(
                      horizontal: wide ? Ds.space.x32 : Ds.space.x16,
                      vertical: Ds.space.x24,
                    ),
                    child: Center(
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 560),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Text(_s('heading'), style: Ds.t.title),
                            SizedBox(height: Ds.space.x16),
                            Container(
                              padding: EdgeInsets.all(Ds.space.x16),
                              decoration: BoxDecoration(
                                color: tone.bg,
                                borderRadius: Ds.r.rCard,
                              ),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(_s('status_label'),
                                      style: Ds.t.subtitle
                                          .copyWith(color: tone.fg)),
                                  if (_s('message').isNotEmpty) ...[
                                    SizedBox(height: Ds.space.x8),
                                    Text(_s('message'), style: Ds.t.body),
                                  ],
                                ],
                              ),
                            ),
                            if (rows.isNotEmpty) ...[
                              SizedBox(height: Ds.space.x24),
                              Container(
                                padding: EdgeInsets.all(Ds.space.x16),
                                decoration: BoxDecoration(
                                  color: Ds.c.surface,
                                  borderRadius: Ds.r.rCard,
                                  boxShadow: Ds.elevation.e1,
                                ),
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    for (var i = 0; i < rows.length; i++) ...[
                                      if (i > 0)
                                        Padding(
                                          padding: EdgeInsets.symmetric(
                                              vertical: Ds.space.x12),
                                          child: Divider(
                                              height: 1,
                                              color: Ds.c.divider),
                                        ),
                                      _VerifyRow(
                                          row: (rows[i] is Map)
                                              ? (rows[i] as Map)
                                                  .cast<String, dynamic>()
                                              : const {}),
                                    ],
                                  ],
                                ),
                              ),
                            ],
                            if (_s('note').isNotEmpty) ...[
                              SizedBox(height: Ds.space.x24),
                              Text(_s('note'), style: Ds.t.caption),
                            ],
                            SizedBox(height: Ds.space.x32),
                          ],
                        ),
                      ),
                    ),
                  );
                },
              ),
      ),
    );
  }
}

/// One label/value pair. The hash is long and must never push the page
/// sideways, so the value wraps under its label on a narrow phone and sits
/// beside it when there is room.
class _VerifyRow extends StatelessWidget {
  const _VerifyRow({required this.row});
  final Map<String, dynamic> row;

  @override
  Widget build(BuildContext context) {
    final label = (row['label'] ?? '').toString();
    final value = (row['value'] ?? '').toString();
    return LayoutBuilder(
      builder: (context, c) {
        if (c.maxWidth < 360) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(label, style: Ds.t.caption),
              SizedBox(height: Ds.space.x4),
              SelectableText(value, style: Ds.t.bodyStrong),
            ],
          );
        }
        return Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 132,
              child: Text(label, style: Ds.t.caption),
            ),
            SizedBox(width: Ds.space.x12),
            Expanded(child: SelectableText(value, style: Ds.t.bodyStrong)),
          ],
        );
      },
    );
  }
}
