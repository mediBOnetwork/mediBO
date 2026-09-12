// [S2] Public dispute token page — accessible without auth at /dispute?token=<token>.
// Loads get_dispute_form; responds via submit_dispute_response.

import 'package:flutter/material.dart';
import '../design_tokens.dart';
import '../screens/admin/dispute/dispute_models.dart';
import '../services/ui_copy.dart';
import '../utils/render_log.dart';
import '../utils/toast.dart';
import '../widgets/dispute_card.dart';

class DisputeTokenPage extends StatefulWidget {
  final String token;

  const DisputeTokenPage({super.key, required this.token});

  @override
  State<DisputeTokenPage> createState() => _DisputeTokenPageState();
}

class _DisputeTokenPageState extends State<DisputeTokenPage> {
  bool _loading = true;
  String? _error;
  String _supplierName = '';
  List<DisputeItem> _items = [];
  final Map<String, bool> _responding = {};

  @override
  void initState() {
    super.initState();
    // c350_token_ready: emitted from real initState after token parsed from constructor
    RenderLog.write('c350_token_ready', 'page=s2');
    _load();
  }

  Future<void> _load() async {
    if (!mounted) return;
    if (widget.token.isEmpty) {
      setState(() { _loading = false; _error = 'invalid'; });
      return;
    }
    setState(() { _loading = true; _error = null; });
    try {
      final result = await fetchDisputeForm(widget.token);
      if (!mounted) return;
      setState(() {
        _supplierName = result.supplierName;
        _items = result.items;
        _loading = false;
      });
    } on DisputeException catch (e) {
      if (!mounted) return;
      setState(() { _loading = false; _error = e.message; });
    } catch (e) {
      if (!mounted) return;
      setState(() { _loading = false; _error = 'invalid'; });
    }
  }

  Future<void> _respond(String disputeId, String code) async {
    if (_responding[disputeId] == true) return;
    setState(() => _responding[disputeId] = true);
    try {
      await submitDisputeResponse(
        token: widget.token,
        disputeId: disputeId,
        response: code,
      );
      if (!mounted) return;
      // c350_responded: emitted from _respond handler on success (token page)
      RenderLog.write('c350_responded', 'code=$code');
      showToast(context, c('dispute_token_page.response_recorded'));
      await Future.delayed(const Duration(milliseconds: 600));
      if (mounted) _load();
    } on DisputeException catch (e) {
      if (!mounted) return;
      showToast(context, e.message);
      if (mounted) _load();
    } catch (e) {
      if (!mounted) return;
      showToast(context, c('dispute_token_page.error_try_again'));
    } finally {
      if (mounted) setState(() => _responding.remove(disputeId));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Ds.c.bg,
      body: SafeArea(child: _body()),
    );
  }

  Widget _body() {
    if (_loading) {
      return Center(
          child: CircularProgressIndicator(color: Ds.c.brand, strokeWidth: 2));
    }

    // Invalid token or RPC error
    if (_error != null) {
      final isInvalid = _error == 'invalid';
      return Center(
        child: Padding(
          padding: EdgeInsets.all(Ds.space.x32),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Icon(Icons.link_off_rounded, size: 56, color: Ds.c.warning),
            SizedBox(height: Ds.space.x16),
            // CHANGE #671: the invalid-link title and body were Dart string
            // literals on a page reached from a WhatsApp link. ui_copy now.
            Text(
              c(isInvalid
                  ? 'dispute_token_page.invalid_title'
                  : 'dispute_token_page.unable_to_load'),
              style: Ds.t.subtitle.copyWith(fontWeight: FontWeight.w700),
              textAlign: TextAlign.center,
            ),
            SizedBox(height: Ds.space.x8),
            Text(
              isInvalid ? c('dispute_token_page.invalid_body') : _error!,
              style: Ds.t.bodySecondary,
              textAlign: TextAlign.center,
            ),
            if (!isInvalid) ...[
              SizedBox(height: Ds.space.x16),
              FilledButton.icon(
                onPressed: _load,
                style: FilledButton.styleFrom(
                  backgroundColor: Ds.c.brand,
                  shape: RoundedRectangleBorder(borderRadius: Ds.r.rButton),
                ),
                icon: const Icon(Icons.refresh_rounded, size: 16),
                label: Text(c('dispute_token_page.retry')),
              ),
            ],
          ]),
        ),
      );
    }

    final active = _items.where((d) => d.isActive).toList();
    final closed = _items.where((d) => !d.isActive).toList();

    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      // Header bar
      Container(
        color: Ds.c.brand,
        padding: EdgeInsets.symmetric(
            horizontal: Ds.space.x16, vertical: Ds.space.x12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(c('dispute_token_page.title'),
              style: Ds.t.subtitle.copyWith(
                  color: Ds.c.surface, fontWeight: FontWeight.w700)),
          if (_supplierName.isNotEmpty) ...[
            SizedBox(height: Ds.space.x4),
            Text(_supplierName,
                style: Ds.t.caption.copyWith(
                    color: Ds.c.surface.withValues(alpha: 0.80),
                    fontWeight: FontWeight.w500)),
          ],
        ]),
      ),

      Expanded(
        child: RefreshIndicator(
          onRefresh: _load,
          color: Ds.c.brand,
          child: _items.isEmpty
              ? Center(
                  child: Padding(
                    padding: EdgeInsets.all(Ds.space.x32),
                    child: Text(c('dispute_token_page.no_active_disputes'),
                        style: Ds.t.subtitle
                            .copyWith(color: Ds.c.textSecondary)),
                  ),
                )
              : Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 640),
                    child: ListView(
                      padding: EdgeInsets.fromLTRB(Ds.space.x16,
                          Ds.space.x16, Ds.space.x16, Ds.space.x32),
                      children: [
                        ...active.map((item) => Padding(
                          padding: EdgeInsets.only(bottom: Ds.space.x12),
                          child: DisputeCard(
                            item: item,
                            onRespond: _respond,
                            isResponding: _responding[item.disputeId] == true,
                          ),
                        )),
                        ...closed.map((item) => Padding(
                          padding: EdgeInsets.only(bottom: Ds.space.x12),
                          child: DisputeCard(item: item), // read-only
                        )),
                      ],
                    ),
                  ),
                ),
        ),
      ),
    ]);
  }
}
