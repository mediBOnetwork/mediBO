import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:pharma_b2b/utils/toast.dart';
import '../services/ui_copy.dart';
import '../theme.dart';
import '../widgets/policy_page_layout.dart';

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
        padding: const EdgeInsets.symmetric(vertical: 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 80,
              height: 80,
              decoration: const BoxDecoration(
                  color: Brand.mint, shape: BoxShape.circle),
              child:
                  const Icon(Icons.check_circle, color: Brand.green, size: 48),
            ),
            const SizedBox(height: 24),
            Text(c('contact.success_title'),
                style: const TextStyle(
                    fontSize: 22,
                    fontWeight: FontWeight.w800,
                    color: Brand.ink)),
            const SizedBox(height: 12),
            Text(
              c('contact.success_body'),
              textAlign: TextAlign.center,
              style: const TextStyle(
                  fontSize: 15, color: Brand.inkMuted, height: 1.5),
            ),
            const SizedBox(height: 32),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(),
              style: FilledButton.styleFrom(
                backgroundColor: Brand.green,
                padding: const EdgeInsets.symmetric(
                    horizontal: 32, vertical: 14),
              ),
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
              style: const TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.w800,
                  color: Brand.ink)),
          const SizedBox(height: 8),
          Text(
            c('contact.form_subtitle'),
            style: const TextStyle(
                fontSize: 14, color: Brand.inkMuted, height: 1.5),
          ),
          const SizedBox(height: 32),
          _field(c('contact.field_name_label'),
              c('contact.field_name_hint'), _nameCtrl),
          const SizedBox(height: 16),
          _field(c('contact.field_phone_label'),
              c('contact.field_phone_hint'), _phoneCtrl,
              keyboard: TextInputType.phone),
          const SizedBox(height: 16),
          _field(c('contact.field_message_label'),
              c('contact.field_message_hint'), _messageCtrl,
              maxLines: 5),
          const SizedBox(height: 32),
          SizedBox(
            width: double.infinity,
            child: FilledButton(
              onPressed: _submitting ? null : _submit,
              style: FilledButton.styleFrom(
                backgroundColor: Brand.green,
                padding: const EdgeInsets.symmetric(vertical: 16),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10)),
              ),
              child: _submitting
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(
                          strokeWidth: 2, color: Colors.white),
                    )
                  : Text(c('contact.btn_send'),
                      style: const TextStyle(
                          fontSize: 16, fontWeight: FontWeight.w600)),
            ),
          ),
          const SizedBox(height: 32),
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: Brand.mint,
              borderRadius: BorderRadius.circular(12),
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
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label,
            style: const TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: Brand.ink)),
        const SizedBox(height: 6),
        TextFormField(
          controller: ctrl,
          maxLines: maxLines,
          keyboardType: keyboard,
          validator: (v) =>
              (v == null || v.trim().isEmpty) ? c('contact.validator_required') : null,
          decoration: InputDecoration(
            hintText: hint,
            hintStyle:
                const TextStyle(color: Brand.inkMuted, fontSize: 14),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(10),
              borderSide: const BorderSide(color: Brand.border),
            ),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(10),
              borderSide: const BorderSide(color: Brand.border),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(10),
              borderSide: const BorderSide(color: Color(0xFFE5E7EB), width: 2),
            ),
            errorBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(10),
              borderSide:
                  const BorderSide(color: Colors.redAccent, width: 1.5),
            ),
            contentPadding: const EdgeInsets.symmetric(
                horizontal: 14, vertical: 14),
            filled: true,
            fillColor: Colors.white,
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
              style: const TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                  color: Brand.green)),
          const SizedBox(height: 12),
        ],
        ...rows.map((r) {
          final label = r['label'];
          final value = r['value'];
          return Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(
                  width: 110,
                  child: Text(label is String ? label : '',
                      style: const TextStyle(
                          fontSize: 12.5, color: Brand.inkMuted)),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(value is String ? value : '',
                      style: const TextStyle(
                          fontSize: 13,
                          color: Brand.ink,
                          fontWeight: FontWeight.w500)),
                ),
              ],
            ),
          );
        }),
      ],
    );
  }
}
