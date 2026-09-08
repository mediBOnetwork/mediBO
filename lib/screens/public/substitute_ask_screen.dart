import 'package:flutter/material.dart';

import '../../design_tokens.dart';
import '../../utils/render_log.dart';
import '../../widgets/substitute_ask_card.dart';

/// CHANGE #698 — the public substitute page, reached from the WhatsApp link
/// `/substitute-ask/<token>`. PUBLIC and anonymous by design: the token in the
/// URL is the authorisation, exactly the way `/stock-update/<token>` works.
///
/// A pharmacy that never installed the app answers the SAME question, on the
/// same [SubstituteAskCard], against the same `substitute_ask_page` payload
/// the in-app order card reads. Every sentence on this screen — including both
/// refusal states — is the backend's.
class SubstituteAskScreen extends StatefulWidget {
  final String token;
  const SubstituteAskScreen({super.key, required this.token});

  @override
  State<SubstituteAskScreen> createState() => _SubstituteAskScreenState();
}

class _SubstituteAskScreenState extends State<SubstituteAskScreen> {
  Map<String, dynamic>? _ask;
  bool _loading = true;
  String _error = '';

  @override
  void initState() {
    super.initState();
    RenderLog.write('c698_substitute_page', 1);
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = '';
    });
    try {
      final raw = await SubstituteAskCard.rpc(
          'substitute_ask_page', {'p_token': widget.token});
      final data = raw is List ? (raw.isEmpty ? null : raw.first) : raw;
      if (!mounted) return;
      if (data is! Map) {
        setState(() => _loading = false);
        return;
      }
      final map = data.cast<String, dynamic>();
      if (map['ok'] == false) {
        setState(() {
          _error = (map['message'] ?? map['title'] ?? '').toString();
          _ask = map;
          _loading = false;
        });
        return;
      }
      setState(() {
        _ask = map;
        _loading = false;
      });
      RenderLog.write('c698_substitute_state', map['state']);
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
    final ask = _ask;
    return Scaffold(
      backgroundColor: Ds.c.bg,
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: EdgeInsets.all(Ds.space.x16),
            child: ConstrainedBox(
              constraints: BoxConstraints(maxWidth: Ds.space.x48 * 12),
              child: _loading
                  ? Padding(
                      padding: EdgeInsets.all(Ds.space.x32),
                      child: const CircularProgressIndicator(),
                    )
                  : (_error.isNotEmpty || ask == null)
                      ? _Message(
                          title: (ask?['title'] ?? '').toString(),
                          note: _error,
                        )
                      : (ask['is_open'] == true)
                          ? SubstituteAskCard(
                              ask: ask,
                              onAnswered: (_) => _load(),
                            )
                          // Closed, applied, skipped or timed out: the backend
                          // already wrote the sentence for each of those.
                          : _Message(
                              title: (ask['title'] ?? '').toString(),
                              note: (ask['note'] ?? '').toString(),
                            ),
            ),
          ),
        ),
      ),
    );
  }
}

class _Message extends StatelessWidget {
  final String title;
  final String note;
  const _Message({required this.title, required this.note});

  @override
  Widget build(BuildContext context) => Container(
        padding: EdgeInsets.all(Ds.space.x24),
        decoration: BoxDecoration(
          color: Ds.c.surface,
          borderRadius: Ds.r.rCard,
          border: Border.all(color: Ds.c.divider),
          boxShadow: Ds.elevation.e1,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (title.isNotEmpty) Text(title, style: Ds.t.subtitle),
            if (note.isNotEmpty) ...[
              SizedBox(height: Ds.space.x8),
              Text(note, style: Ds.t.caption),
            ],
          ],
        ),
      );
}
