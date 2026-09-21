// CMD #2120 — THE quantity popup, shared.
//
// It was built for the Bulk Upload review list (CMD #2115, cap raised to 999
// by CMD #2119) and lived inside bulk_upload_screen_web.dart. The cart row now
// opens the SAME popup from its quantity chip, so it moved here whole rather
// than being copied: one dialog, one RPC, one set of words. A second copy is
// how two surfaces start disagreeing about what "5 strip" means.
//
// Nothing in it is composed here. `bulk_qty_picker(pack_type, current)`
// returns the title, every option's number AND its printed label, which one is
// selected and the index to scroll to. This widget scrolls to that index and
// sends a number back.

import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../design_tokens.dart';
import '../services/ui_copy.dart';
import '../utils/render_log.dart';

const double _kQtyOptionH = 48.0;

/// What the popup sends back: the number AND the label the BACKEND printed
/// beside it. A caller that shows the choice before the server has answered
/// prints that label verbatim rather than composing "7 strip" in Dart.
class QtyChoice {
  final int value;
  final String label;
  const QtyChoice(this.value, this.label);
}

Future<QtyChoice?> showQtyPickerChoice(BuildContext context,
        {required String packType, required int current}) =>
    showDialog<QtyChoice>(
      context: context,
      builder: (_) => _BulkQtyPickerDialog(packType: packType, current: current),
    );

Future<int?> showBulkQtyPicker(BuildContext context,
        {required String packType, required int current}) async =>
    (await showQtyPickerChoice(context, packType: packType, current: current))
        ?.value;

class _BulkQtyPickerDialog extends StatefulWidget {
  final String packType;
  final int current;
  const _BulkQtyPickerDialog({required this.packType, required this.current});

  @override
  State<_BulkQtyPickerDialog> createState() => _BulkQtyPickerDialogState();
}

class _BulkQtyPickerDialogState extends State<_BulkQtyPickerDialog> {
  Map<String, dynamic>? _data;
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() { _failed = false; _data = null; });
    try {
      final raw = await Supabase.instance.client.rpc('bulk_qty_picker', params: {
        'p_pack_type': widget.packType,
        'p_current': widget.current,
      });
      if (!mounted) return;
      setState(() => _data = Map<String, dynamic>.from(raw as Map));
    } catch (_) {
      if (mounted) setState(() => _failed = true);
    }
  }

  @override
  Widget build(BuildContext context) {
    try { RenderLog.write('c2115_qty_picker', '1'); } catch (_) {}
    final d = _data;
    final listH = _kQtyOptionH * 5;
    return Dialog(
      insetPadding: EdgeInsets.symmetric(
          horizontal: Ds.space.x32, vertical: Ds.space.x48),
      backgroundColor: Ds.c.surface,
      shape: RoundedRectangleBorder(borderRadius: Ds.r.rCard),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Padding(
          padding: EdgeInsets.fromLTRB(
              Ds.space.x16, Ds.space.x16, Ds.space.x16, Ds.space.x8),
          child: Align(
            alignment: Alignment.centerLeft,
            child: Text(
                d == null
                    ? c('bulk.qty_picker_title')
                    : (d['title'] ?? '').toString(),
                style: Ds.t.subtitle),
          ),
        ),
        Divider(height: Ds.space.hairline, color: Ds.c.divider),
        SizedBox(
          height: listH,
          child: _failed
              ? _error()
              : d == null
                  ? _skeleton()
                  : _options(d, listH),
        ),
      ]),
    );
  }

  Widget _error() => Center(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Text(c('bulk.qty_picker_error'), style: Ds.t.caption),
          SizedBox(height: Ds.space.x8),
          SizedBox(
            height: Ds.space.x48,
            child: TextButton(
              onPressed: _load,
              child: Text(c('bulk.qty_picker_retry')),
            ),
          ),
        ]),
      );

  /// A skeleton of the same rows, so nothing moves when the list lands.
  Widget _skeleton() => ListView.builder(
        itemCount: 5,
        itemExtent: _kQtyOptionH,
        itemBuilder: (_, __) => Padding(
          padding: EdgeInsets.symmetric(
              horizontal: Ds.space.x16, vertical: Ds.space.x12),
          child: Container(
            decoration: BoxDecoration(
              color: Ds.c.divider,
              borderRadius: Ds.r.rChip,
            ),
          ),
        ),
      );

  Widget _options(Map<String, dynamic> d, double listH) {
    final opts = List<Map<String, dynamic>>.from(
        (d['options'] as List? ?? const []).map((e) => Map<String, dynamic>.from(e as Map)));
    final selected = (d['selected'] as num?)?.toInt();
    final idx = (d['selected_index'] as num?)?.toInt() ?? 0;
    // Centre the selected row: its top, minus half a viewport, plus half a row.
    final maxOffset = (opts.length * _kQtyOptionH) - listH;
    final target = (idx * _kQtyOptionH) - (listH / 2) + (_kQtyOptionH / 2);
    final offset = target < 0 ? 0.0 : (target > maxOffset ? (maxOffset < 0 ? 0.0 : maxOffset) : target);
    return ListView.builder(
      controller: ScrollController(initialScrollOffset: offset),
      itemCount: opts.length,
      itemExtent: _kQtyOptionH,
      itemBuilder: (_, i) {
        final o = opts[i];
        final v = (o['value'] as num?)?.toInt() ?? 0;
        final isSel = selected != null && v == selected;
        return Semantics(
          identifier: 'bulk_qty_option_$v',
          button: true,
          selected: isSel,
          child: InkWell(
            onTap: () => Navigator.of(context)
                .pop(QtyChoice(v, (o['label'] ?? '').toString())),
            child: Container(
              color: isSel ? Ds.c.brandSoft : null,
              padding: EdgeInsets.symmetric(horizontal: Ds.space.x16),
              alignment: Alignment.centerLeft,
              child: Row(children: [
                Expanded(
                  child: Text((o['label'] ?? '').toString(),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: isSel
                          ? Ds.t.body.copyWith(
                              color: Ds.c.brand, fontWeight: FontWeight.w700)
                          : Ds.t.body),
                ),
                if (isSel) Icon(Icons.check, size: Ds.space.x16, color: Ds.c.brand),
              ]),
            ),
          ),
        );
      },
    );
  }
}
