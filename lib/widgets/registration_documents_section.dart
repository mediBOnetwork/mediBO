// CMD #2061 — the Documents section that lives INSIDE the registration form.
//
// It decides nothing about which papers exist. `custdoc_form_block(zone,
// owner)` — the same block the standalone documents page reads — says which
// rows to draw, whether each one is starred, what its buttons say and what
// state word to print. A document switched Off in Settings is simply absent
// from the payload, so this widget never learns the word "off".
//
// The two things it owns are local and temporary: which rows the person has
// picked a file for, and which rows they said they do not have. Both ride
// along to the ONE Submit, which is what actually writes them.
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../design_tokens.dart';

/// A file chosen but not yet uploaded — it goes up with Submit, because a
/// brand-new signup has no customer row to hang it on until then.
@immutable
class PickedDoc {
  const PickedDoc({required this.name, required this.ext, required this.bytes});
  final String name;
  final String ext;
  final Uint8List bytes;
}

class RegistrationDocumentsSection extends StatelessWidget {
  const RegistrationDocumentsSection({
    super.key,
    required this.block,
    required this.picked,
    required this.skipped,
    required this.onPick,
    required this.onSkipToggle,
    this.busyKey = '',
  });

  /// custdoc_form_block() verbatim.
  final Map<String, dynamic> block;

  /// Files chosen in this session, by document key.
  final Map<String, PickedDoc> picked;

  /// Keys the person answered "I don't have this" for.
  final Set<String> skipped;

  final void Function(Map<String, dynamic> row) onPick;
  final void Function(Map<String, dynamic> row) onSkipToggle;
  final String busyKey;

  List<Map<String, dynamic>> get _rows =>
      ((block['rows'] as List?) ?? const [])
          .whereType<Map>()
          .map((e) => Map<String, dynamic>.from(e))
          .toList();

  String _s(Map<String, dynamic> m, String k) => (m[k] ?? '').toString();

  @override
  Widget build(BuildContext context) {
    if (block['show'] != true) return const SizedBox.shrink();
    final rows = _rows;
    if (rows.isEmpty) return const SizedBox.shrink();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(height: Ds.space.x24),
        Text(_s(block, 'title'), style: Ds.t.subtitle),
        if (_s(block, 'subtitle').isNotEmpty) ...[
          SizedBox(height: Ds.space.x4),
          Text(_s(block, 'subtitle'), style: Ds.t.caption),
        ],
        SizedBox(height: Ds.space.x12),
        for (final r in rows) ...[
          _card(context, r),
          SizedBox(height: Ds.space.x8),
        ],
        if (_s(block, 'skip_note').isNotEmpty) ...[
          SizedBox(height: Ds.space.x4),
          Text(_s(block, 'skip_note'), style: Ds.t.caption),
        ],
      ],
    );
  }

  Widget _card(BuildContext context, Map<String, dynamic> row) {
    final key = _s(row, 'key');
    final isSkipped = skipped.contains(key) || row['skipped'] == true;
    final hasFile = picked.containsKey(key) || row['has_file'] == true;
    final busy = busyKey == key;

    // The state word is the backend's whenever the backend has one. A file
    // chosen in this session has not reached the ledger yet, so the row's own
    // "Added" wording is reused rather than a second sentence being invented.
    final stateLabel = _s(row, 'state_label');

    return Container(
      width: double.infinity,
      padding: EdgeInsets.all(Ds.space.x16),
      decoration: BoxDecoration(
        color: Ds.c.surface,
        borderRadius: Ds.r.rCard,
        boxShadow: Ds.elevation.e1,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Text('${_s(row, 'label')}${_s(row, 'star')}',
                    style: Ds.t.bodyStrong),
              ),
              SizedBox(width: Ds.space.x8),
              _chip(_s(row, 'requirement_label'), _s(row, 'requirement_tone')),
            ],
          ),
          if (_s(row, 'hint').isNotEmpty) ...[
            SizedBox(height: Ds.space.x4),
            Text(_s(row, 'hint'), style: Ds.t.caption),
          ],
          if (hasFile || isSkipped) ...[
            SizedBox(height: Ds.space.x8),
            Text(
              picked.containsKey(key)
                  ? picked[key]!.name
                  : (isSkipped ? _s(row, 'state_label') : _s(row, 'file_name')),
              style: Ds.t.caption,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ] else if (stateLabel.isNotEmpty) ...[
            SizedBox(height: Ds.space.x8),
            Text(stateLabel, style: Ds.t.caption),
          ],
          SizedBox(height: Ds.space.x12),
          // Phone first: two full-width-ish buttons on one row, each at the
          // minimum touch height, wrapping to their own line when the label is
          // long rather than truncating.
          Wrap(
            spacing: Ds.space.x8,
            runSpacing: Ds.space.x8,
            children: [
              SizedBox(
                height: Ds.touch.minTarget,
                child: OutlinedButton(
                  onPressed: busy ? null : () => onPick(row),
                  child: Text(hasFile
                      ? _s(row, 'replace_label')
                      : _s(row, 'add_label')),
                ),
              ),
              SizedBox(
                height: Ds.touch.minTarget,
                child: TextButton(
                  onPressed: busy ? null : () => onSkipToggle(row),
                  child: Text(isSkipped
                      ? _s(row, 'undo_label')
                      : _s(row, 'skip_label')),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _chip(String label, String tone) {
    if (label.isEmpty) return const SizedBox.shrink();
    final bg = switch (tone) {
      'warning' => Ds.c.warningSoft,
      'success' => Ds.c.successSoft,
      'danger' => Ds.c.dangerSoft,
      'info' => Ds.c.infoSoft,
      _ => Ds.c.bg,
    };
    return Container(
      padding: EdgeInsets.symmetric(
          horizontal: Ds.space.x8, vertical: Ds.space.x4),
      decoration: BoxDecoration(color: bg, borderRadius: Ds.r.rChip),
      child: Text(label, style: Ds.t.caption),
    );
  }
}
