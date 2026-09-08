import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../design_tokens.dart';
import '../../utils/render_log.dart';

/// CHANGE #465 · supplier register row 63 — the door that did not exist.
///
/// 28 of 35 supplier_profiles rows have user_id NULL, supplier_leads had ZERO
/// rows, and the only ways to create a supplier were admin_create_supplier,
/// admin_create_suppliers and admin_import_supplier. A distributor who heard
/// about mediBO had no way in and nowhere to put a GSTIN or a drug licence.
///
/// This page is public — no session, no role — and it is a renderer: WHICH
/// fields a distributor is asked for, their labels, their hints and whether
/// each is required are rows in `supplier_signup_field`, so asking for an
/// FSSAI number tomorrow is one INSERT and not a deploy. Validation is the
/// backend's too: this screen never decides that something is missing, it
/// prints the fields the server named.
class SupplierSignupScreen extends StatefulWidget {
  const SupplierSignupScreen({super.key});

  @override
  State<SupplierSignupScreen> createState() => _SupplierSignupScreenState();
}

class _SupplierSignupScreenState extends State<SupplierSignupScreen> {
  Map<String, dynamic>? _form;
  final Map<String, TextEditingController> _ctl = {};
  bool _sending = false;

  /// The backend's confirmation, once it has accepted the application.
  Map<String, dynamic>? _done;

  /// The backend's refusal, printed verbatim. Never worded here.
  String _error = '';

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    for (final c in _ctl.values) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final raw =
          await Supabase.instance.client.rpc('supplier_signup_form');
      final map = (raw is List ? (raw.isEmpty ? null : raw.first) : raw);
      if (!mounted || map is! Map) return;
      final p = map.cast<String, dynamic>();
      for (final f in ((p['fields'] as List<dynamic>?) ?? const [])
          .whereType<Map>()) {
        _ctl[(f['key'] ?? '').toString()] = TextEditingController();
      }
      setState(() => _form = p);
      RenderLog.write('c465_sup_signup',
          'fields:${((p['fields'] as List?) ?? const []).length}');
    } catch (_) {
      // Boot resilience: a form that cannot load shows nothing rather than a
      // half-built form with fields invented here.
    }
  }

  Future<void> _submit() async {
    setState(() {
      _sending = true;
      _error = '';
    });
    final payload = <String, dynamic>{
      for (final e in _ctl.entries) e.key: e.value.text.trim(),
    };
    try {
      final raw = await Supabase.instance.client
          .rpc('supplier_signup_submit', params: {'p': payload});
      final map = (raw is List ? (raw.isEmpty ? null : raw.first) : raw);
      if (!mounted) return;
      final Map<String, dynamic> p =
          map is Map ? map.cast<String, dynamic>() : <String, dynamic>{};
      setState(() {
        _sending = false;
        if (p['ok'] == true) {
          _done = p;
        } else {
          _error = (p['message'] ?? '').toString();
        }
      });
      RenderLog.write('c465_sup_signup_submit',
          p['ok'] == true ? 'ok' : 'refused:${p['error'] ?? ''}');
    } catch (e) {
      if (!mounted) return;
      setState(() => _sending = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = _form;
    final done = _done;
    return Scaffold(
      backgroundColor: Ds.c.bg,
      appBar: AppBar(title: Text((p?['title'] ?? '').toString())),
      body: p == null
          ? const Center(child: CircularProgressIndicator())
          : Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 560),
                child: ListView(
                  padding: EdgeInsets.all(Ds.space.x16),
                  children: done != null
                      ? [
                          SizedBox(height: Ds.space.x32),
                          Text((done['title'] ?? '').toString(),
                              style: Ds.t.title),
                          SizedBox(height: Ds.space.x8),
                          Text((done['note'] ?? '').toString(),
                              style: Ds.t.body),
                        ]
                      : [
                          Text((p['subtitle'] ?? '').toString(),
                              style: Ds.t.body),
                          SizedBox(height: Ds.space.x24),
                          for (final f
                              in ((p['fields'] as List<dynamic>?) ?? const [])
                                  .whereType<Map>())
                            _field(f.cast<String, dynamic>()),
                          if (_error.isNotEmpty) ...[
                            SizedBox(height: Ds.space.x8),
                            Text(_error,
                                style: Ds.t.body.copyWith(color: Ds.c.danger)),
                          ],
                          SizedBox(height: Ds.space.x24),
                          SizedBox(
                            width: double.infinity,
                            height: Ds.touch.minTarget,
                            child: FilledButton(
                              onPressed: _sending ? null : _submit,
                              style: FilledButton.styleFrom(
                                backgroundColor: Ds.c.brand,
                                shape: RoundedRectangleBorder(
                                    borderRadius: Ds.r.rButton),
                              ),
                              child: Text((p['cta'] ?? '').toString()),
                            ),
                          ),
                          SizedBox(height: Ds.space.x32),
                        ],
                ),
              ),
            ),
    );
  }

  Widget _field(Map<String, dynamic> f) {
    final key = (f['key'] ?? '').toString();
    final hint = (f['hint'] ?? '').toString();
    // A field the payload named but this build has no controller for is skipped
    // rather than crashing — the registry may grow between deploys.
    final ctl = _ctl[key];
    if (ctl == null) return const SizedBox.shrink();
    return Padding(
      padding: EdgeInsets.only(bottom: Ds.space.x12),
      child: TextField(
        controller: ctl,
        keyboardType: (f['keyboard'] ?? '') == 'phone'
            ? TextInputType.phone
            : (f['keyboard'] ?? '') == 'email'
                ? TextInputType.emailAddress
                : TextInputType.text,
        style: Ds.t.body,
        decoration: InputDecoration(
          // The asterisk is the backend's `required` flag, rendered — the
          // screen does not decide which fields matter.
          labelText: f['required'] == true
              ? '${f['label']} *'
              : (f['label'] ?? '').toString(),
          hintText: hint.isEmpty ? null : hint,
          filled: true,
          fillColor: Ds.c.surface,
          border: OutlineInputBorder(
              borderRadius: Ds.r.rButton,
              borderSide: BorderSide(color: Ds.c.divider)),
          enabledBorder: OutlineInputBorder(
              borderRadius: Ds.r.rButton,
              borderSide: BorderSide(color: Ds.c.divider)),
          focusedBorder: OutlineInputBorder(
              borderRadius: Ds.r.rButton,
              borderSide: BorderSide(color: Ds.c.brand)),
        ),
      ),
    );
  }
}
