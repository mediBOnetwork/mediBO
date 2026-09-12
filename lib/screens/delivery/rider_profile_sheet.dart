import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../design_tokens.dart';

/// CHANGE #463 · register row 119 — the rider's own details, editable.
///
/// `my_delivery_profile_update()` had existed for some time and nothing in
/// lib/ called it, so a rider whose phone number changed had to ask an admin.
/// This sheet is the missing half.
///
/// It hard-codes no field. `my_delivery_profile()` returns the title, the save
/// label, and a `fields[]` list carrying each key, label, current value and
/// keyboard; this widget builds one input per entry, in payload order, and
/// posts a map back. A seventh editable field is a row in the RPC, not a
/// deploy. Every message the rider reads — success, refusal, the duplicate
/// -phone hint — is the backend's own string.
class RiderProfileSheet extends StatefulWidget {
  const RiderProfileSheet({super.key});

  static Future<bool?> show(BuildContext context) => showModalBottomSheet<bool>(
        context: context,
        isScrollControlled: true,
        backgroundColor: Colors.transparent,
        builder: (_) => const RiderProfileSheet(),
      );

  @override
  State<RiderProfileSheet> createState() => _RiderProfileSheetState();
}

class _RiderProfileSheetState extends State<RiderProfileSheet> {
  final _controllers = <String, TextEditingController>{};
  List<Map<String, dynamic>> _fields = const [];
  String _title = '';
  String _saveLabel = '';
  String? _error;
  bool _loading = true;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    for (final c in _controllers.values) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final raw = await Supabase.instance.client.rpc('my_delivery_profile');
      final m = Map<String, dynamic>.from((raw is List ? raw.first : raw) as Map);
      if (!mounted) return;
      if (m['ok'] != true) {
        setState(() {
          _error = (m['message'] as String?) ?? '';
          _loading = false;
        });
        return;
      }
      final fields = ((m['fields'] as List?) ?? const [])
          .map((e) => Map<String, dynamic>.from(e as Map))
          .toList();
      for (final f in fields) {
        _controllers[f['key'] as String] =
            TextEditingController(text: (f['value'] as String?) ?? '');
      }
      setState(() {
        _fields = fields;
        _title = (m['title'] as String?) ?? '';
        _saveLabel = (m['save_label'] as String?) ?? '';
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _error = '';
        _loading = false;
      });
    }
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    try {
      // Only the keys the payload named — this widget never invents a column.
      final payload = <String, dynamic>{
        for (final f in _fields)
          f['key'] as String: _controllers[f['key'] as String]!.text.trim(),
      };
      final raw = await Supabase.instance.client
          .rpc('my_delivery_profile_update', params: {'p': payload});
      final m = Map<String, dynamic>.from((raw is List ? raw.first : raw) as Map);
      if (!mounted) return;
      final ok = m['ok'] == true;
      // Success or refusal, the rider reads the BACKEND's sentence — including
      // the 'identity_taken' hint when a number belongs to someone else.
      final msg = (m['message'] as String?) ?? (m['hint'] as String?) ?? '';
      if (ok) Navigator.of(context).pop(true);
      if (msg.isNotEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(msg), behavior: SnackBarBehavior.floating),
        );
      }
      if (!ok && mounted) setState(() => _saving = false);
    } catch (_) {
      if (mounted) setState(() => _saving = false);
    }
  }

  TextInputType _keyboard(String? k) {
    switch (k) {
      case 'phone':
        return TextInputType.phone;
      case 'email':
        return TextInputType.emailAddress;
      default:
        return TextInputType.text;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(
          bottom: MediaQuery.of(context).viewInsets.bottom),
      child: Container(
        decoration: BoxDecoration(
          color: Ds.c.surface,
          borderRadius: BorderRadius.vertical(top: Radius.circular(Ds.r.sheet)),
        ),
        padding: EdgeInsets.fromLTRB(
            Ds.space.x16, Ds.space.x12, Ds.space.x16, Ds.space.x24),
        child: SafeArea(
          top: false,
          child: _loading
              ? Padding(
                  padding: EdgeInsets.all(Ds.space.x32),
                  child: Center(
                      child: CircularProgressIndicator(color: Ds.c.brand)),
                )
              : SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Center(
                        child: Container(
                          width: 40,
                          height: 4,
                          decoration: BoxDecoration(
                            color: Ds.c.divider,
                            borderRadius: Ds.r.rChip,
                          ),
                        ),
                      ),
                      SizedBox(height: Ds.space.x16),
                      if (_error != null) ...[
                        Text(_error!.isEmpty ? '' : _error!,
                            style: Ds.t.body),
                        SizedBox(height: Ds.space.x16),
                      ] else ...[
                        Text(_title, style: Ds.t.subtitle),
                        SizedBox(height: Ds.space.x16),
                        for (final f in _fields) ...[
                          TextField(
                            controller: _controllers[f['key'] as String],
                            keyboardType: _keyboard(f['keyboard'] as String?),
                            inputFormatters: f['keyboard'] == 'phone'
                                ? [FilteringTextInputFormatter.digitsOnly]
                                : null,
                            decoration: InputDecoration(
                              labelText: (f['label'] as String?) ?? '',
                              border: OutlineInputBorder(
                                  borderRadius: Ds.r.rButton),
                            ),
                          ),
                          SizedBox(height: Ds.space.x12),
                        ],
                        SizedBox(height: Ds.space.x4),
                        SizedBox(
                          width: double.infinity,
                          height: 48,
                          child: FilledButton(
                            onPressed: _saving ? null : _save,
                            style: FilledButton.styleFrom(
                              backgroundColor: Ds.c.brand,
                              shape: RoundedRectangleBorder(
                                  borderRadius: Ds.r.rButton),
                            ),
                            child: _saving
                                ? const SizedBox(
                                    width: 18,
                                    height: 18,
                                    child: CircularProgressIndicator(
                                        strokeWidth: 2, color: Colors.white))
                                : Text(_saveLabel),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
        ),
      ),
    );
  }
}
