// [S2] Public dispute token page — accessible without auth at /dispute?token=<token>.
// Loads get_dispute_form; responds via submit_dispute_response.

import 'package:flutter/material.dart';
import '../screens/admin/dispute/dispute_models.dart';
import '../services/ui_copy.dart';
import '../utils/render_log.dart';
import '../utils/toast.dart';
import '../widgets/dispute_card.dart';

const _kGreen = Color(0xFF1B7A43);
const _kSub   = Color(0xFF6B7280);
const _kText  = Color(0xFF111827);

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
      backgroundColor: const Color(0xFFF5F6F8),
      body: SafeArea(child: _body()),
    );
  }

  Widget _body() {
    if (_loading) {
      return const Center(child: CircularProgressIndicator(color: _kGreen, strokeWidth: 2));
    }

    // Invalid token or RPC error
    if (_error != null) {
      final isInvalid = _error == 'invalid';
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            const Icon(Icons.link_off_rounded, size: 56, color: Color(0xFFD97706)),
            const SizedBox(height: 16),
            Text(
              isInvalid ? 'Link invalid' : c('dispute_token_page.unable_to_load'),
              style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700, color: _kText),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 8),
            Text(
              isInvalid
                  ? 'This dispute link has expired or is not valid.'
                  : _error!,
              style: const TextStyle(fontSize: 14, color: _kSub),
              textAlign: TextAlign.center,
            ),
            if (!isInvalid) ...[
              const SizedBox(height: 16),
              FilledButton.icon(
                onPressed: _load,
                style: FilledButton.styleFrom(
                  backgroundColor: _kGreen,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
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
        color: const Color(0xFF1B7A43),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(c('dispute_token_page.title'),
              style: const TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.w700)),
          if (_supplierName.isNotEmpty) ...[
            const SizedBox(height: 2),
            Text(_supplierName,
                style: const TextStyle(color: Color(0xFFBBF7D0), fontSize: 13,
                    fontWeight: FontWeight.w500)),
          ],
        ]),
      ),

      Expanded(
        child: RefreshIndicator(
          onRefresh: _load,
          color: _kGreen,
          child: _items.isEmpty
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(32),
                    child: Text(c('dispute_token_page.no_active_disputes'),
                        style: const TextStyle(fontSize: 16, color: _kSub)),
                  ),
                )
              : Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 640),
                    child: ListView(
                      padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
                      children: [
                        ...active.map((item) => Padding(
                          padding: const EdgeInsets.only(bottom: 12),
                          child: DisputeCard(
                            item: item,
                            onRespond: _respond,
                            isResponding: _responding[item.disputeId] == true,
                          ),
                        )),
                        ...closed.map((item) => Padding(
                          padding: const EdgeInsets.only(bottom: 12),
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
