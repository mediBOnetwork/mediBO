import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:pharma_b2b/utils/toast.dart';
import '../design_tokens.dart';
import '../services/ui_copy.dart';
import '../widgets/policy_page_layout.dart';

/// CHANGE #66 — styled from the `Ds` token layer (no style literals). Colours,
/// spacing, radii and type all come from `ui_boot().design`.
class ContactScreen extends StatefulWidget {
  const ContactScreen({super.key});

  @override
  State<ContactScreen> createState() => _ContactScreenState();
}

class _ContactScreenState extends State<ContactScreen> {
  final _formKey = GlobalKey<FormState>();
  final _nameCtrl = TextEditingController();
  final _phoneCtrl = TextEditingController();
  final _messageCtrl = TextEditingController();
  bool _submitting = false;
  bool _submitted = false;

  @override
  void dispose() {
    _nameCtrl.dispose();
    _phoneCtrl.dispose();
    _messageCtrl.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() => _submitting = true);
    try {
      // CHANGE #581 — a PUBLIC form INSERTing straight into a table. The RPC
      // shapes the write and enforces required fields and length caps in the
      // database, where a skipped client validator cannot reach.
      await Supabase.instance.client.rpc('submit_contact_inquiry', params: {
        'p_name': _nameCtrl.text.trim(),
        'p_phone': _phoneCtrl.text.trim(),
        'p_message': _messageCtrl.text.trim(),
      });
      if (!mounted) return;
      setState(() {
        _submitting = false;
        _submitted = true;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _submitting = false);
      showToast(context, c('contact.toast_send_failed'));
    }
  }

  @override
  Widget build(BuildContext context) {
    return PolicyPageLayout(
      title: c('contact.page_title'),
      child: _submitted ? _buildSuccess() : _buildForm(),
    );
  }

  Widget _buildSuccess() {
    return Center(
      child: Padding(
        padding: EdgeInsets.symmetric(vertical: Ds.space.x32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 80,
              height: 80,
              decoration: BoxDecoration(color: Ds.c.brandSoft, shape: BoxShape.circle),
              child: Icon(Icons.check_circle, color: Ds.c.brand, size: 48),
            ),
            SizedBox(height: Ds.space.x24),
            Text(c('contact.success_title'),
                style: Ds.t.title.copyWith(fontWeight: FontWeight.w800)),
            SizedBox(height: Ds.space.x12),
            Text(
              c('contact.success_body'),
              textAlign: TextAlign.center,
              style: Ds.t.body.copyWith(color: Ds.c.textSecondary, height: 1.5),
            ),
            SizedBox(height: Ds.space.x32),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(),
              child: Text(c('contact.btn_back_home')),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildForm() {
    return Form(
      key: _formKey,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(c('contact.form_title'),
              style: Ds.t.title.copyWith(fontWeight: FontWeight.w800)),
          SizedBox(height: Ds.space.x8),
          Text(
            c('contact.form_subtitle'),
            style: Ds.t.caption.copyWith(color: Ds.c.textSecondary, height: 1.5),
          ),
          SizedBox(height: Ds.space.x32),
          _field(c('contact.field_name_label'),
              c('contact.field_name_hint'), _nameCtrl),
          SizedBox(height: Ds.space.x16),
          _field(c('contact.field_phone_label'),
              c('contact.field_phone_hint'), _phoneCtrl,
              keyboard: TextInputType.phone),
          SizedBox(height: Ds.space.x16),
          _field(c('contact.field_message_label'),
              c('contact.field_message_hint'), _messageCtrl,
              maxLines: 5),
          SizedBox(height: Ds.space.x32),
          SizedBox(
            width: double.infinity,
            child: FilledButton(
              onPressed: _submitting ? null : _submit,
              child: _submitting
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(
                          strokeWidth: 2, color: Colors.white),
                    )
                  : Text(c('contact.btn_send')),
            ),
          ),
          SizedBox(height: Ds.space.x32),
          Container(
            padding: EdgeInsets.all(Ds.space.x16),
            decoration: BoxDecoration(
              color: Ds.c.brandSoft,
              borderRadius: Ds.r.rCard,
            ),
            // CHANGE #619 — mediBO's own details, from
            // platform_public_identity(). The partner's name, address and
            // GSTIN that used to sit here are shown on About and nowhere else.
            child: const _DirectContact(),
          ),
        ],
      ),
    );
  }

  Widget _field(
    String label,
    String hint,
    TextEditingController ctrl, {
    int maxLines = 1,
    TextInputType? keyboard,
  }) {
    OutlineInputBorder border(Color c, double w) => OutlineInputBorder(
          borderRadius: Ds.r.rButton,
          borderSide: BorderSide(color: c, width: w),
        );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label,
            style: Ds.t.caption.copyWith(
                fontWeight: FontWeight.w600, color: Ds.c.text)),
        SizedBox(height: Ds.space.x4 + 2),
        TextFormField(
          controller: ctrl,
          maxLines: maxLines,
          keyboardType: keyboard,
          validator: (v) =>
              (v == null || v.trim().isEmpty) ? c('contact.validator_required') : null,
          decoration: InputDecoration(
            hintText: hint,
            hintStyle: Ds.t.caption.copyWith(color: Ds.c.textSecondary),
            border: border(Ds.c.divider, 1),
            enabledBorder: border(Ds.c.divider, 1),
            focusedBorder: border(Ds.c.brand, 1.5),
            errorBorder: border(Ds.c.danger, 1.5),
            contentPadding: EdgeInsets.symmetric(
                horizontal: Ds.space.x16, vertical: Ds.space.x12),
            filled: true,
            fillColor: Ds.c.surface,
          ),
        ),
      ],
    );
  }
}

/// CHANGE #619 — mediBO's own contact block, rendered from
/// `platform_public_identity()`. The heading and every label/value pair come
/// from the payload; this widget writes no copy of its own. The RPC returns
/// no partner data, so the partner cannot appear here.
class _DirectContact extends StatefulWidget {
  const _DirectContact();

  @override
  State<_DirectContact> createState() => _DirectContactState();
}

class _DirectContactState extends State<_DirectContact> {
  Map<String, dynamic>? _data;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final raw =
          await Supabase.instance.client.rpc('platform_public_identity');
      if (!mounted) return;
      setState(() => _data = Map<String, dynamic>.from(raw as Map));
    } catch (e) {
      // Nothing to show without a payload — the block stays empty rather
      // than inventing a fallback.
      if (!mounted) return;
    }
  }

  @override
  Widget build(BuildContext context) {
    final d = _data;
    if (d == null) return const SizedBox.shrink();

    final title = d['contact_title'];
    final raw = d['contact_rows'];
    final rows = raw is List
        ? raw.whereType<Map>().map((e) => Map<String, dynamic>.from(e)).toList()
        : const <Map<String, dynamic>>[];
    if (rows.isEmpty) return const SizedBox.shrink();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (title is String && title.isNotEmpty) ...[
          Text(title,
              style: Ds.t.caption.copyWith(
                  fontWeight: FontWeight.w700, color: Ds.c.brand)),
          SizedBox(height: Ds.space.x12),
        ],
        ...rows.map((r) {
          final label = r['label'];
          final value = r['value'];
          return Padding(
            padding: EdgeInsets.only(bottom: Ds.space.x8),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(
                  width: 110,
                  child: Text(label is String ? label : '', style: Ds.t.caption),
                ),
                SizedBox(width: Ds.space.x8),
                Expanded(
                  child: Text(value is String ? value : '',
                      style: Ds.t.caption.copyWith(
                          color: Ds.c.text, fontWeight: FontWeight.w500)),
                ),
              ],
            ),
          );
        }),
      ],
    );
  }
}
