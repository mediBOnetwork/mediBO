// CMD #2128 — Step 3 · Licences.
//
// `custreg_licences_block()` says everything: which groups exist and in what
// order, which rows sit in each, the counter next to "Required", the status
// line under every label (including the number that was read off the paper),
// which control the row's right edge carries, whether "Don't have" is offered
// and what the upload sheet for THAT row is called. This file renders it.
//
// It composes no sentence and counts nothing. "1 of 3 done" is a string the
// backend built; a rejected paper is in the "Needs your attention" group
// because the backend put it there, not because Dart looked at its status.
import 'package:flutter/material.dart';

import '../design_tokens.dart';
import 'registration_documents_section.dart' show PickedDoc;

Map<String, dynamic> _m(dynamic v) =>
    v is Map ? Map<String, dynamic>.from(v) : const {};

List<Map<String, dynamic>> _list(dynamic v) =>
    ((v as List?) ?? const []).map(_m).toList();

String _s(Map<String, dynamic> m, String k) => (m[k] ?? '').toString();

/// The tone words the backend uses, mapped onto the one palette. A tone this
/// app has never heard of falls back to ordinary text rather than throwing.
Color licTone(String tone) => switch (tone) {
      'success' => Ds.c.brand,
      'warning' => Ds.c.warning,
      'danger' => Ds.c.danger,
      'info' => Ds.c.info,
      _ => Ds.c.textSecondary,
    };

Color licToneSoft(String tone) => switch (tone) {
      'success' => Ds.c.successSoft,
      'warning' => Ds.c.warningSoft,
      'danger' => Ds.c.dangerSoft,
      'info' => Ds.c.infoSoft,
      _ => Ds.c.bg,
    };

class RegistrationLicencesSection extends StatelessWidget {
  const RegistrationLicencesSection({
    super.key,
    required this.block,
    required this.picked,
    required this.skipped,
    required this.thumbUrls,
    required this.onUpload,
    required this.onView,
    required this.onSkipToggle,
    required this.onScan,
    this.busyKey = '',
    this.scanning = false,
  });

  /// custreg_licences_block() verbatim.
  final Map<String, dynamic> block;

  /// Files chosen on this device that have not reached storage yet — they go
  /// up with Submit, so their thumbnail comes from the bytes in hand.
  final Map<String, PickedDoc> picked;

  /// Keys answered "Don't have" in this session.
  final Set<String> skipped;

  /// Signed URLs for the papers already in storage, by document key.
  final Map<String, String> thumbUrls;

  final void Function(Map<String, dynamic> row) onUpload;
  final void Function(Map<String, dynamic> row) onView;
  final void Function(Map<String, dynamic> row) onSkipToggle;
  final VoidCallback onScan;
  final String busyKey;
  final bool scanning;

  List<Map<String, dynamic>> get _groups => _list(block['groups']);

  @override
  Widget build(BuildContext context) {
    if (block['show'] != true) {
      final empty = _s(block, 'empty_label');
      if (empty.isEmpty) return const SizedBox.shrink();
      return Padding(
        padding: EdgeInsets.symmetric(vertical: Ds.space.x24),
        child: Text(empty, style: Ds.t.bodySecondary),
      );
    }

    final scan = _m(block['scan']);
    final groups = _groups.where((g) => _list(g['rows']).isNotEmpty).toList();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (scan['show'] == true) ...[
          _ScanCard(scan: scan, busy: scanning, onTap: onScan),
          SizedBox(height: Ds.space.x24),
        ],
        for (var i = 0; i < groups.length; i++) ...[
          if (i > 0) SizedBox(height: Ds.space.x24),
          _group(groups[i]),
        ],
        if (_s(block, 'footnote').isNotEmpty) ...[
          SizedBox(height: Ds.space.x16),
          Text(_s(block, 'footnote'), style: Ds.t.caption),
        ],
      ],
    );
  }

  Widget _group(Map<String, dynamic> g) {
    final rows = _list(g['rows']);
    final counter = _s(g, 'counter_label');
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(children: [
          Expanded(child: Text(_s(g, 'title'), style: Ds.t.subtitle)),
          if (counter.isNotEmpty) ...[
            SizedBox(width: Ds.space.x8),
            Semantics(
              identifier: 'reg_lic_counter_${_s(g, 'key')}',
              child: Container(
                padding: EdgeInsets.symmetric(
                    horizontal: Ds.space.x12, vertical: Ds.space.x4),
                decoration: BoxDecoration(
                  color: licToneSoft(_s(g, 'counter_tone')),
                  borderRadius: Ds.r.rChip,
                ),
                child: Text(counter,
                    style: Ds.t.caption.copyWith(
                        color: licTone(_s(g, 'counter_tone')),
                        fontWeight: FontWeight.w600)),
              ),
            ),
          ],
        ]),
        SizedBox(height: Ds.space.x12),
        Container(
          decoration: BoxDecoration(
            color: Ds.c.surface,
            borderRadius: Ds.r.rCard,
            boxShadow: Ds.elevation.e1,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (var i = 0; i < rows.length; i++) ...[
                if (i > 0)
                  Divider(height: Ds.space.hairline, color: Ds.c.divider),
                _row(rows[i]),
              ],
            ],
          ),
        ),
      ],
    );
  }

  Widget _row(Map<String, dynamic> row) {
    final key = _s(row, 'key');
    final local = picked[key];
    final isSkipped = skipped.contains(key);
    final action = _m(row['action']);
    final dontHave = _m(row['dont_have']);
    final busy = busyKey == key;

    // A file chosen a moment ago is not in the ledger yet, so the row reads
    // as uploaded using the words the backend already sent for that state.
    final hasLocal = local != null;
    final state = hasLocal ? 'uploaded' : _s(row, 'state');
    final canView = hasLocal || row['can_view'] == true;
    final statusLabel = _s(row, 'status_label');

    return Semantics(
      identifier: 'reg_lic_row_$key',
      child: Container(
        constraints: BoxConstraints(minHeight: Ds.touch.minTarget),
        padding: EdgeInsets.symmetric(
            horizontal: Ds.space.x16, vertical: Ds.space.x12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            _Thumb(
              row: row,
              local: local,
              url: thumbUrls[key] ?? '',
              onTap: canView ? () => onView(row) : null,
            ),
            Expanded(
              child: Padding(
                padding: EdgeInsets.symmetric(horizontal: Ds.space.x12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(_s(row, 'label'), style: Ds.t.body),
                    if (statusLabel.isNotEmpty) ...[
                      SizedBox(height: Ds.space.x4),
                      InkWell(
                        onTap: canView ? () => onView(row) : null,
                        child: Text(
                          isSkipped && !hasLocal && state != 'uploaded'
                              ? _s(dontHave, 'label')
                              : statusLabel,
                          style: Ds.t.caption.copyWith(
                            color: licTone(hasLocal
                                ? 'success'
                                : _s(row, 'status_tone')),
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
            if (dontHave['show'] == true && !hasLocal)
              Semantics(
                identifier: 'reg_lic_skip_$key',
                button: true,
                child: ConstrainedBox(
                  constraints: BoxConstraints(minHeight: Ds.touch.minTarget),
                  child: TextButton(
                    onPressed: busy ? null : () => onSkipToggle(row),
                    child: Text(
                        isSkipped
                            ? _s(dontHave, 'undo_label')
                            : _s(dontHave, 'label'),
                        style: Ds.t.caption
                            .copyWith(fontWeight: FontWeight.w600)),
                  ),
                ),
              ),
            SizedBox(width: Ds.space.x8),
            _ActionCircle(
              action: action,
              done: state == 'uploaded',
              busy: busy,
              docKey: key,
              onTap: () =>
                  state == 'uploaded' && canView ? onView(row) : onUpload(row),
            ),
          ],
        ),
      ),
    );
  }
}

/// The green band at the top of the step (approved design, Image A): one tap
/// takes a photo of a licence and the backend fills the numbers.
class _ScanCard extends StatelessWidget {
  const _ScanCard({required this.scan, required this.busy, required this.onTap});

  final Map<String, dynamic> scan;
  final bool busy;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      identifier: 'reg_lic_scan',
      button: true,
      child: Material(
        color: Ds.c.brand,
        borderRadius: Ds.r.rCard,
        child: InkWell(
          borderRadius: Ds.r.rCard,
          onTap: busy ? null : onTap,
          child: Padding(
            padding: EdgeInsets.all(Ds.space.x16),
            child: Row(children: [
              Container(
                width: Ds.space.x48,
                height: Ds.space.x48,
                decoration: BoxDecoration(
                  color: Ds.c.surface,
                  borderRadius: Ds.r.rChip,
                ),
                alignment: Alignment.center,
                child: busy
                    ? SizedBox(
                        width: Ds.space.x24,
                        height: Ds.space.x24,
                        child: CircularProgressIndicator(
                            strokeWidth: Ds.space.hairline * 2,
                            color: Ds.c.brand),
                      )
                    : Icon(Icons.photo_camera_rounded, color: Ds.c.brand),
              ),
              SizedBox(width: Ds.space.x12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(_s(scan, 'title'),
                        style: Ds.t.subtitle.copyWith(color: Ds.c.surface)),
                    SizedBox(height: Ds.space.x4),
                    Text(
                        busy
                            ? _s(scan, 'reading_label')
                            : _s(scan, 'subtitle'),
                        style: Ds.t.caption.copyWith(color: Ds.c.surface)),
                  ],
                ),
              ),
            ]),
          ),
        ),
      ),
    );
  }
}

/// The 56-square on the left of an answered row: the photo itself, or the PDF
/// tile with its badge. An unanswered row has no tile — the design leaves the
/// space to the label.
class _Thumb extends StatelessWidget {
  const _Thumb(
      {required this.row,
      required this.local,
      required this.url,
      required this.onTap});

  final Map<String, dynamic> row;
  final PickedDoc? local;
  final String url;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final thumb = _m(row['thumb']);
    final localBytes = local?.bytes;
    final localIsPdf = (local?.ext ?? '').toLowerCase() == 'pdf';
    final kind = local != null
        ? (localIsPdf ? 'pdf' : 'image')
        : _s(thumb, 'kind');
    if (kind != 'pdf' && kind != 'image') return const SizedBox.shrink();

    final side = Ds.space.x48 + Ds.space.x8;
    Widget inner;
    if (kind == 'pdf') {
      inner = Container(
        color: Ds.c.dangerSoft,
        alignment: Alignment.center,
        child: Text(_s(thumb, 'badge'),
            style: Ds.t.caption
                .copyWith(color: Ds.c.danger, fontWeight: FontWeight.w700)),
      );
    } else if (localBytes != null) {
      inner = Image.memory(localBytes, fit: BoxFit.cover);
    } else if (url.isNotEmpty) {
      inner = Image.network(url,
          fit: BoxFit.cover,
          errorBuilder: (_, _, _) => Container(color: Ds.c.bg));
    } else {
      inner = Container(color: Ds.c.bg);
    }

    return Semantics(
      identifier: 'reg_lic_thumb_${_s(row, 'key')}',
      button: onTap != null,
      child: InkWell(
        onTap: onTap,
        borderRadius: Ds.r.rChip,
        child: Container(
          width: side,
          height: side,
          decoration: BoxDecoration(
            borderRadius: Ds.r.rChip,
            border: Border.all(color: Ds.c.divider),
            color: Ds.c.bg,
          ),
          clipBehavior: Clip.antiAlias,
          child: inner,
        ),
      ),
    );
  }
}

/// The circle on the right edge. Filled green when the paper is in, outlined
/// green when it is still wanted, outlined red when it was rejected — the
/// backend names the icon and the tone; this only draws them.
class _ActionCircle extends StatelessWidget {
  const _ActionCircle({
    required this.action,
    required this.done,
    required this.busy,
    required this.docKey,
    required this.onTap,
  });

  final Map<String, dynamic> action;
  final bool done;
  final bool busy;
  final String docKey;
  final VoidCallback onTap;

  IconData get _icon => switch (_s(action, 'icon')) {
        'check' => Icons.check_rounded,
        'retry' => Icons.refresh_rounded,
        _ => Icons.arrow_upward_rounded,
      };

  @override
  Widget build(BuildContext context) {
    final tone = done ? 'success' : _s(action, 'tone');
    final colour = tone == 'brand' ? Ds.c.brand : licTone(tone);
    final filled = done;
    return Semantics(
      identifier: 'reg_lic_action_$docKey',
      button: true,
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: busy ? null : onTap,
        child: SizedBox(
          width: Ds.touch.minTarget,
          height: Ds.touch.minTarget,
          child: Center(
            child: Container(
              width: Ds.space.x32 + Ds.space.x4,
              height: Ds.space.x32 + Ds.space.x4,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: filled ? colour : Colors.transparent,
                border: Border.all(color: colour),
              ),
              alignment: Alignment.center,
              child: busy
                  ? SizedBox(
                      width: Ds.space.x16,
                      height: Ds.space.x16,
                      child: CircularProgressIndicator(
                          strokeWidth: Ds.space.hairline * 2, color: colour),
                    )
                  : Icon(_icon,
                      size: Ds.space.x16 + Ds.space.x4,
                      color: filled ? Ds.c.surface : colour),
            ),
          ),
        ),
      ),
    );
  }
}
