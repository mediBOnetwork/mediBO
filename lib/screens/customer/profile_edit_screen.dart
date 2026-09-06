import 'package:flutter/material.dart';
import 'package:pharma_b2b/utils/toast.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../design_tokens.dart';
import '../../utils/render_log.dart';
import '../../services/ui_copy.dart';

/// CHANGE #460 / feature_gaps 164 — the customer edits their own details.
///
/// CMD #1815 — there is ONE profile screen now. This used to be a Scaffold of
/// its own, reached from My Account → Profile & KYC, which printed the very
/// same fields read-only and then handed the customer off to it. Two editors
/// for one set of fields is one too many, so the form moved INTO the tab: the
/// backend places it there as `{"kind":"embed","widget":"profile_form"}` and
/// this file is the body it draws. `ProfileEditScreen` is gone; every entry
/// point that named it now opens My Account.
///
/// The form itself still decides NOTHING. Which sections exist, which fields
/// are in them, their order, labels, hints, keyboard type, length caps,
/// whether a field may be edited at all and the sentence shown when it may not
/// — all of it is `my_profile_edit()`'s answer, drawn from the
/// `customer_profile_field` table. Licence numbers and GSTIN are locked there,
/// with their own "contact support" note. Opening a locked field up later is an
/// UPDATE, not a deploy. Every validation message on screen is
/// `my_profile_save()`'s own.
class CustomerProfileForm extends StatefulWidget {
  /// Called after a successful save, so the surface holding this form can
  /// refresh whatever else it printed from the same profile.
  final VoidCallback? onSaved;

  const CustomerProfileForm({super.key, this.onSaved});

  @override
  State<CustomerProfileForm> createState() => _CustomerProfileFormState();
}

class _CustomerProfileFormState extends State<CustomerProfileForm> {
  final _sb = Supabase.instance.client;
  final Map<String, TextEditingController> _ctl = {};
  Map<String, dynamic>? _p;
  bool _loading = true;
  bool _saving = false;

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

  String _s(Map m, String k) => (m[k] ?? '').toString();

  List<Map<String, dynamic>> _sections() =>
      ((_p ?? const {})['sections'] as List? ?? const [])
          .whereType<Map>()
          .map((e) => Map<String, dynamic>.from(e))
          .toList();

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final res = await _sb.rpc('my_profile_edit');
      _p = (res is Map) ? Map<String, dynamic>.from(res) : <String, dynamic>{};
    } catch (_) {
      _p = <String, dynamic>{'ok': false};
    }
    for (final sec in _sections()) {
      for (final f in (sec['fields'] as List? ?? const []).whereType<Map>()) {
        final key = _s(f, 'key');
        if (key.isEmpty) continue;
        _ctl.putIfAbsent(key, () => TextEditingController()).text = _s(f, 'value');
      }
    }
    if (!mounted) return;
    setState(() => _loading = false);
    RenderLog.write('customer_profile_edit', {
      'sections': _sections().length,
      'editable': _sections()
          .expand((s) => (s['fields'] as List? ?? const []).whereType<Map>())
          .where((f) => f['editable'] == true)
          .length,
    });
  }

  Future<void> _save() async {
    if (_saving) return;
    setState(() => _saving = true);
    final patch = <String, dynamic>{};
    for (final sec in _sections()) {
      for (final f in (sec['fields'] as List? ?? const []).whereType<Map>()) {
        if (f['editable'] != true) continue;
        final key = _s(f, 'key');
        patch[key] = _ctl[key]?.text ?? '';
      }
    }
    Map<String, dynamic> m = const {};
    try {
      final res = await _sb.rpc('my_profile_save', params: {'p': patch});
      m = (res is Map) ? Map<String, dynamic>.from(res) : const {};
    } catch (e) {
      m = {'ok': false, 'message': ''};
    }
    if (!mounted) return;
    setState(() => _saving = false);
    final msg = _s(m, 'message');
    if (msg.isNotEmpty) showToast(context, msg, isError: m['ok'] != true);
    if (m['ok'] == true) widget.onSaved?.call();
  }

  @override
  Widget build(BuildContext context) {
    final p = _p ?? const {};
    if (_loading) return const _FormSkeleton();
    if (p['ok'] != true) {
      return _LoadError(
        message: _s(p, 'message').isNotEmpty
            ? _s(p, 'message')
            : c('cust_profile.load_failed'),
        retryLabel: c('cust_profile.retry'),
        onRetry: _load,
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (_s(p, 'title').isNotEmpty) ...[
          Text(_s(p, 'title'), style: Ds.t.subtitle),
          SizedBox(height: Ds.space.x8),
        ],
        if (_s(p, 'note').isNotEmpty) ...[
          Text(_s(p, 'note'), style: Ds.t.caption),
          SizedBox(height: Ds.space.x12),
        ],
        for (final sec in _sections()) ...[
          _sectionCard(sec, _s(p, 'locked_chip')),
          SizedBox(height: Ds.space.x12),
        ],
        SizedBox(
          height: Ds.touch.minTarget,
          child: FilledButton(
            onPressed: _saving ? null : _save,
            child: Text(_s(p, 'save_label')),
          ),
        ),
      ],
    );
  }

  Widget _sectionCard(Map<String, dynamic> sec, String lockedChip) {
    final fields =
        (sec['fields'] as List? ?? const []).whereType<Map>().toList();
    return Container(
      decoration: BoxDecoration(
        color: Ds.c.surface,
        borderRadius: BorderRadius.circular(Ds.r.card),
        boxShadow: Ds.elevation.e1,
      ),
      padding: EdgeInsets.all(Ds.space.x16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text((sec['title'] ?? '').toString(), style: Ds.t.subtitle),
          SizedBox(height: Ds.space.x12),
          for (int i = 0; i < fields.length; i++) ...[
            _field(Map<String, dynamic>.from(fields[i]), lockedChip),
            if (i != fields.length - 1) SizedBox(height: Ds.space.x12),
          ],
        ],
      ),
    );
  }

  Widget _field(Map<String, dynamic> f, String lockedChip) {
    final key = _s(f, 'key');
    final editable = f['editable'] == true;
    final maxLen = (f['max_len'] is num) ? (f['max_len'] as num).toInt() : null;
    final type = _s(f, 'input_type');

    if (!editable) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(child: Text(_s(f, 'label'), style: Ds.t.caption)),
              if (lockedChip.isNotEmpty)
                Container(
                  padding: EdgeInsets.symmetric(
                      horizontal: Ds.space.x8, vertical: Ds.space.x4),
                  decoration: BoxDecoration(
                    color: Ds.c.infoSoft,
                    borderRadius: BorderRadius.circular(Ds.r.chip),
                  ),
                  child: Text(lockedChip, style: Ds.t.caption),
                ),
            ],
          ),
          SizedBox(height: Ds.space.x4),
          Text(_s(f, 'value'), style: Ds.t.body),
          if (_s(f, 'locked_note').isNotEmpty) ...[
            SizedBox(height: Ds.space.x4),
            Text(_s(f, 'locked_note'), style: Ds.t.caption),
          ],
        ],
      );
    }

    return TextField(
      controller: _ctl[key],
      maxLength: maxLen,
      maxLines: type == 'multiline' ? 3 : 1,
      keyboardType: type == 'phone'
          ? TextInputType.phone
          : type == 'email'
              ? TextInputType.emailAddress
              : type == 'multiline'
                  ? TextInputType.multiline
                  : TextInputType.text,
      decoration: InputDecoration(
        labelText: _s(f, 'label'),
        hintText: _s(f, 'hint'),
        counterText: '',
      ),
    );
  }
}

class _FormSkeleton extends StatelessWidget {
  const _FormSkeleton();

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        for (int i = 0; i < 3; i++) ...[
          Container(
            height: Ds.space.x48 * 3,
            decoration: BoxDecoration(
              color: Ds.c.surface,
              borderRadius: BorderRadius.circular(Ds.r.card),
            ),
          ),
          SizedBox(height: Ds.space.x16),
        ],
      ],
    );
  }
}

/// The one shape all three #460 screens use when their RPC refused or threw.
/// The sentence is the backend's when there is one and boot copy when the call
/// never got far enough to return one — never a Dart literal, and never a blank
/// centred screen with no way out (design-QA gate, check 6).
class _LoadError extends StatelessWidget {
  final String message;
  final String retryLabel;
  final VoidCallback onRetry;
  const _LoadError({
    required this.message,
    required this.retryLabel,
    required this.onRetry,
  });

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: EdgeInsets.all(Ds.space.x24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(message,
                textAlign: TextAlign.center, style: Ds.t.bodySecondary),
            SizedBox(height: Ds.space.x16),
            SizedBox(
              height: Ds.touch.minTarget,
              child: OutlinedButton(onPressed: onRetry, child: Text(retryLabel)),
            ),
          ],
        ),
      ),
    );
  }
}
