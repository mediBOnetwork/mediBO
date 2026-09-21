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
    this.onEdit,
    this.reading = const {},
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

  /// CMD #2135 — Edit / Type on a v3 row (the row's own `edit` sheet).
  final void Function(Map<String, dynamic> row)? onEdit;

  /// CMD #2135 — rows whose photo is being read right now.
  final Set<String> reading;

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

    final saved = _s(block, 'saved_note');
    final progress = _m(block['progress']);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (progress.isNotEmpty) ...[
          _ProgressCard(progress: progress),
          SizedBox(height: Ds.space.x24),
        ],
        if (saved.isNotEmpty) ...[
          Semantics(
            identifier: 'reg_doc_saved_note',
            child: Container(
              padding: EdgeInsets.all(Ds.space.x12),
              decoration: BoxDecoration(
                  color: Ds.c.successSoft, borderRadius: Ds.r.rCard),
              child: Text(saved, style: Ds.t.caption),
            ),
          ),
          SizedBox(height: Ds.space.x24),
        ],
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

  /// CMD #2129 — the staff flow's words for a skipped paper ("Customer will
  /// add"); the customer's own flow sends none and keeps "Don't have".
  String _skippedLabel(Map<String, dynamic> dontHave) {
    final staff = _s(dontHave, 'skipped_label');
    return staff.isNotEmpty ? staff : _s(dontHave, 'label');
  }

  String _skippedTone(Map<String, dynamic> dontHave) {
    final t = _s(dontHave, 'skipped_tone');
    return t.isNotEmpty ? t : 'neutral';
  }

  Widget _row(Map<String, dynamic> row) {
    if (row['circle'] is Map) return _rowV4(row);
    if (row['act'] is Map) return _rowV3(row);
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
                              ? _skippedLabel(dontHave)
                              : statusLabel,
                          style: Ds.t.caption.copyWith(
                            color: licTone(hasLocal
                                ? 'success'
                                : isSkipped && state != 'uploaded'
                                    ? _skippedTone(dontHave)
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
  /// CMD #2135 — the Registration v3 row: the number read off the photo in
  /// bold, "Valid till …" under it, and Edit on the right; "Reading the
  /// number…" while the photo is being read; "Couldn't read — tap to type"
  /// with Type when it could not be; View for a photo-only paper. Every word,
  /// and which of these a row is, comes from the row.
  Widget _rowV3(Map<String, dynamic> row) {
    final key = _s(row, 'key');
    final act = _m(row['act']);
    final kind = _s(act, 'kind');
    final dontHave = _m(row['dont_have']);
    final isSkipped = skipped.contains(key) || dontHave['on'] == true;
    final busy = busyKey == key;
    final isReading = reading.contains(key);
    final canView = row['can_view'] == true;
    final number = _s(row, 'number');
    final validLine = _s(row, 'valid_line');
    final line = _s(row, 'line');
    final status = _s(row, 'status_label');

    final lines = <Widget>[];
    if (isReading) {
      lines.addAll([
        SizedBox(height: Ds.space.x4),
        Row(children: [
          SizedBox(
            width: Ds.space.x12,
            height: Ds.space.x12,
            child: CircularProgressIndicator(
                strokeWidth: Ds.space.hairline * 2, color: Ds.c.brand),
          ),
          SizedBox(width: Ds.space.x8),
          Flexible(
            child: Text(_s(block, 'reading_label'),
                style: Ds.t.caption.copyWith(
                    color: Ds.c.brand, fontWeight: FontWeight.w600)),
          ),
        ]),
        SizedBox(height: Ds.space.x8),
        ClipRRect(
          borderRadius: Ds.r.rChip,
          child: LinearProgressIndicator(
              minHeight: Ds.space.x4,
              color: Ds.c.brand,
              backgroundColor: Ds.c.divider),
        ),
      ]);
    } else if (number.isNotEmpty) {
      lines.addAll([
        SizedBox(height: Ds.space.x4),
        Text(number, style: Ds.t.bodyStrong),
        if (validLine.isNotEmpty) ...[
          SizedBox(height: Ds.space.x4),
          Text(validLine, style: Ds.t.caption),
        ],
      ]);
    } else if (line.isNotEmpty) {
      lines.addAll([
        SizedBox(height: Ds.space.x4),
        Text(line,
            style: Ds.t.caption.copyWith(
                color: licTone(_s(row, 'line_tone')),
                fontWeight: FontWeight.w600)),
      ]);
    } else if (status.isNotEmpty) {
      lines.addAll([
        SizedBox(height: Ds.space.x4),
        Text(isSkipped ? _skippedLabel(dontHave) : status,
            style: Ds.t.caption.copyWith(
                color: licTone(
                    isSkipped ? _skippedTone(dontHave) : _s(row, 'status_tone')),
                fontWeight: FontWeight.w600)),
      ]);
    }

    Widget trailing;
    if (kind == 'upload' || isReading) {
      trailing = Row(mainAxisSize: MainAxisSize.min, children: [
        if (dontHave['show'] == true && !isReading)
          Semantics(
            identifier: 'reg_lic_skip_$key',
            button: true,
            child: ConstrainedBox(
              constraints: BoxConstraints(minHeight: Ds.touch.minTarget),
              child: TextButton(
                onPressed: busy ? null : () => onSkipToggle(row),
                child: Text(
                    isSkipped ? _s(dontHave, 'undo_label') : _s(dontHave, 'label'),
                    style: Ds.t.caption.copyWith(color: Ds.c.textSecondary)),
              ),
            ),
          ),
        SizedBox(width: Ds.space.x4),
        _ActionCircle(
          action: _m(row['action']),
          done: false,
          busy: busy || isReading,
          docKey: key,
          onTap: () => onUpload(row),
        ),
      ]);
    } else {
      final tap = switch (kind) {
        'edit' || 'type' => () => (onEdit ?? onView)(row),
        'retake' => () => onUpload(row),
        _ => () => onView(row),
      };
      trailing = Semantics(
        identifier: 'reg_doc_act_$key',
        button: true,
        child: ConstrainedBox(
          constraints: BoxConstraints(
              minHeight: Ds.touch.minTarget, minWidth: Ds.touch.minTarget),
          child: TextButton(
            onPressed: busy ? null : tap,
            child: Text(_s(act, 'label'),
                style: Ds.t.bodyStrong.copyWith(
                    color: kind == 'retake' ? Ds.c.danger : Ds.c.brand)),
          ),
        ),
      );
    }

    return Semantics(
      identifier: 'reg_lic_row_$key',
      child: Container(
        constraints: BoxConstraints(minHeight: Ds.touch.minTarget + Ds.space.x12),
        padding: EdgeInsets.symmetric(
            horizontal: Ds.space.x16, vertical: Ds.space.x12),
        child: Row(children: [
          if (canView || isReading || picked.containsKey(key)) ...[
            _Thumb(
              row: row,
              local: picked[key],
              url: thumbUrls[key] ?? '',
              onTap: canView ? () => onView(row) : null,
            ),
          ],
          Expanded(
            child: Padding(
              padding: EdgeInsets.symmetric(horizontal: Ds.space.x12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(_s(row, 'label'), style: Ds.t.body),
                  ...lines,
                ],
              ),
            ),
          ),
          trailing,
        ]),
      ),
    );
  }
}

/// CMD #2141 — Registration v4: every row is a thumbnail, the paper's name,
/// ONE sub-line (Needed / Optional / the number · till date / Uploaded /
/// Couldn't read — tap to type / Rejected — reason) and ONE circle: ↑ still
/// needed, ✓ green when it is in, ✎ when it could not be read, ↻ when it was
/// rejected. "Don't have" sits beside ↑ when the zone allows it. The row and
/// its circle decide nothing: `sub` and `circle` are the backend's.
extension _RowV4 on RegistrationLicencesSection {
  Widget _rowV4(Map<String, dynamic> row) {
    final key = _s(row, 'key');
    final circle = _m(row['circle']);
    final sub = _m(row['sub']);
    final dontHave = _m(row['dont_have']);
    final busy = busyKey == key;
    final isReading = reading.contains(key);
    final canView = row['can_view'] == true;
    final tap = switch (_s(circle, 'tap')) {
      'edit' => () => (onEdit ?? onView)(row),
      'view' => () => onView(row),
      _ => () => onUpload(row),
    };
    // Om, 22 Sep — no Skip anywhere unless the BACKEND offers it on the row
    // (it sends dont_have.show=false on every row today). No client-side
    // "required" rule, and a key skipped earlier draws nothing either.
    final skippable = dontHave['show'] == true;
    final isSkipped = skippable && skipped.contains(key);
    final showDontHave =
        skippable && !isReading && _s(circle, 'tap') == 'upload';
    final subText = isReading
        ? _s(block, 'reading_label')
        : (isSkipped ? _s(dontHave, 'label') : _s(sub, 'text'));
    final subTone = isReading ? 'success' : (isSkipped ? 'neutral' : _s(sub, 'tone'));
    // Tapping the number (or the ✎) of a read row opens its edit sheet.
    final editable = row['edit'] is Map && onEdit != null && !isReading;

    return Semantics(
      identifier: 'reg_lic_row_$key',
      child: Container(
        constraints: BoxConstraints(minHeight: Ds.touch.minTarget + Ds.space.x12),
        padding: EdgeInsets.symmetric(
            horizontal: Ds.space.x16, vertical: Ds.space.x12),
        child: Row(children: [
          if (_s(_m(row['thumb']), 'kind') == 'none' && picked[key] == null)
            // Nothing on file yet: a quiet "+" tile where the photo will sit.
            InkWell(
              onTap: busy ? null : () => onUpload(row),
              borderRadius: Ds.r.rChip,
              child: Container(
                width: Ds.space.x48,
                height: Ds.space.x48,
                decoration: BoxDecoration(
                  color: Ds.c.bg,
                  borderRadius: Ds.r.rChip,
                  border: Border.all(color: Ds.c.divider),
                ),
                child: Icon(Icons.add, color: Ds.c.textSecondary),
              ),
            )
          else
            _Thumb(
              row: row,
              local: picked[key],
              url: thumbUrls[key] ?? '',
              onTap: canView ? () => onView(row) : null,
            ),
          Expanded(
            child: Semantics(
              identifier: 'reg_lic_text_$key',
              button: editable,
              child: InkWell(
                onTap: editable ? () => onEdit!(row) : null,
                borderRadius: Ds.r.rChip,
                child: ConstrainedBox(
                  constraints: BoxConstraints(minHeight: Ds.touch.minTarget),
                  child: Padding(
                    padding: EdgeInsets.symmetric(horizontal: Ds.space.x12),
                    // Two lines at most: the paper's name, then ONE line —
                    // the number, or the Mandatory/Optional tag (row.sub).
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Text(_s(row, 'label'),
                            style: Ds.t.bodyStrong,
                            maxLines: 1,
                            softWrap: false,
                            overflow: TextOverflow.ellipsis),
                        if (subText.isNotEmpty) ...[
                          SizedBox(height: Ds.space.x4),
                          Text(subText,
                              maxLines: 1,
                              softWrap: false,
                              overflow: TextOverflow.ellipsis,
                              style: Ds.t.caption.copyWith(
                                  color: licTone(subTone),
                                  fontWeight: subTone == 'neutral'
                                      ? FontWeight.w500
                                      : FontWeight.w600)),
                        ],
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
          if (showDontHave || isSkipped)
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
                      style: Ds.t.caption.copyWith(color: Ds.c.textSecondary)),
                ),
              ),
            ),
          _ActionCircle(
            action: {'icon': _s(circle, 'icon'), 'tone': _s(circle, 'tone')},
            done: false,
            filled: circle['filled'] == true,
            busy: busy || isReading,
            docKey: key,
            onTap: tap,
          ),
        ]),
      ),
    );
  }
}

/// CMD #2141 — the ONE card at the top of Documents: "Required papers ·
/// 2 of 3 done", a bar, and "Still needed: …" — or "Needs your attention ·
/// 1 paper" once a paper is rejected. The words, tone and fill are the
/// backend's `progress` block.
class _ProgressCard extends StatelessWidget {
  const _ProgressCard({required this.progress});

  final Map<String, dynamic> progress;

  @override
  Widget build(BuildContext context) {
    final tone = _s(progress, 'tone');
    final colour = tone == 'brand' ? Ds.c.brand : licTone(tone);
    final line = _s(progress, 'line');
    final fraction = (progress['fraction'] as num?)?.toDouble() ?? 0;
    return Semantics(
      identifier: 'reg_doc_progress',
      child: Container(
        padding: EdgeInsets.all(Ds.space.x16),
        decoration: BoxDecoration(
          color: Ds.c.surface,
          borderRadius: Ds.r.rCard,
          border: Border.all(
              color: tone == 'danger' ? Ds.c.danger : Ds.c.divider),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(children: [
              Expanded(
                  child: Text(_s(progress, 'title'), style: Ds.t.bodyStrong)),
              SizedBox(width: Ds.space.x8),
              Text(_s(progress, 'count_label'),
                  style: Ds.t.bodyStrong.copyWith(color: colour)),
            ]),
            if (progress['bar'] == true) ...[
              SizedBox(height: Ds.space.x12),
              ClipRRect(
                borderRadius: Ds.r.rChip,
                child: LinearProgressIndicator(
                  value: fraction.clamp(0, 1),
                  minHeight: Ds.space.x4,
                  color: Ds.c.brand,
                  backgroundColor: Ds.c.divider,
                ),
              ),
            ],
            if (line.isNotEmpty) ...[
              SizedBox(height: Ds.space.x8),
              Text(line,
                  style: Ds.t.caption.copyWith(
                      color: licTone(_s(progress, 'line_tone')),
                      fontWeight: _s(progress, 'line_tone') == 'success'
                          ? FontWeight.w600
                          : FontWeight.w400)),
            ],
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
    this.filled = false,
  });

  final Map<String, dynamic> action;
  final bool done;

  /// CMD #2141 — the backend's `circle.filled` (✓ on a green disc).
  final bool filled;
  final bool busy;
  final String docKey;
  final VoidCallback onTap;

  IconData get _icon => switch (_s(action, 'icon')) {
        'check' => Icons.check_rounded,
        'retry' => Icons.refresh_rounded,
        'edit' => Icons.edit_rounded,
        _ => Icons.arrow_upward_rounded,
      };

  @override
  Widget build(BuildContext context) {
    final tone = done ? 'success' : _s(action, 'tone');
    final colour = tone == 'brand' ? Ds.c.brand : licTone(tone);
    final filled = done || this.filled;
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

/// CMD #2135 — "Tap Edit → check what we read". The row's own `edit` block:
/// its title, its line, one box per field with the backend's "Read ✓" beside
/// a value that came off the photo, Retake photo and Looks right. Tapping the
/// photo opens the viewer. `onConfirm` saves and answers with the backend's
/// error sentence (null = saved), so a bad date keeps the sheet open.
class DocReadEditSheet extends StatefulWidget {
  const DocReadEditSheet({
    super.key,
    required this.edit,
    required this.thumb,
    required this.onConfirm,
    required this.onRetake,
    required this.onViewPhoto,
  });

  final Map<String, dynamic> edit;
  final Widget thumb;
  final Future<String?> Function(Map<String, String> values) onConfirm;
  final VoidCallback onRetake;
  final VoidCallback onViewPhoto;

  @override
  State<DocReadEditSheet> createState() => _DocReadEditSheetState();
}

class _DocReadEditSheetState extends State<DocReadEditSheet> {
  final Map<String, TextEditingController> _ctl = {};
  bool _saving = false;
  String _error = '';

  List<Map<String, dynamic>> get _fields => _list(widget.edit['fields']);

  @override
  void initState() {
    super.initState();
    for (final f in _fields) {
      _ctl[_s(f, 'key')] = TextEditingController(text: _s(f, 'value'));
    }
  }

  @override
  void dispose() {
    for (final c in _ctl.values) {
      c.dispose();
    }
    super.dispose();
  }

  /// The backend sends "Valid till" as `DD Mon YYYY`; the picker opens on it
  /// (or today) and writes back `YYYY-MM-DD`.
  Future<void> _pickDate(String key) async {
    final c = _ctl[key];
    if (c == null) return;
    final now = DateTime.now();
    final initial = parseDocDate(c.text) ?? now;
    final picked = await showDatePicker(
      context: context,
      initialDate: initial,
      firstDate: DateTime(now.year - 30),
      lastDate: DateTime(now.year + 30),
    );
    if (picked == null || !mounted) return;
    setState(() => c.text = '${picked.year.toString().padLeft(4, '0')}-'
        '${picked.month.toString().padLeft(2, '0')}-'
        '${picked.day.toString().padLeft(2, '0')}');
  }

  Future<void> _confirm() async {
    setState(() {
      _saving = true;
      _error = '';
    });
    final err = await widget.onConfirm({
      for (final e in _ctl.entries) e.key: e.value.text.trim(),
    });
    if (!mounted) return;
    if (err == null) {
      Navigator.of(context).pop(true);
      return;
    }
    setState(() {
      _saving = false;
      _error = err;
    });
  }

  @override
  Widget build(BuildContext context) {
    final e = widget.edit;
    return SafeArea(
      top: false,
      child: Padding(
        padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
        child: SingleChildScrollView(
          padding: EdgeInsets.fromLTRB(
              Ds.space.x16, Ds.space.x24, Ds.space.x16, Ds.space.x16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Semantics(
                  identifier: 'reg_doc_edit_photo',
                  button: true,
                  child: InkWell(onTap: widget.onViewPhoto, child: widget.thumb),
                ),
                SizedBox(width: Ds.space.x12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(_s(e, 'title'), style: Ds.t.title),
                      SizedBox(height: Ds.space.x4),
                      Text(_s(e, 'line'), style: Ds.t.bodySecondary),
                    ],
                  ),
                ),
              ]),
              SizedBox(height: Ds.space.x24),
              for (final f in _fields) ...[
                Row(children: [
                  Expanded(child: Text(_s(f, 'label'), style: Ds.t.caption)),
                  if (f['read'] == true)
                    Text(_s(f, 'read_label'),
                        style: Ds.t.caption.copyWith(
                            color: Ds.c.brand, fontWeight: FontWeight.w600)),
                ]),
                SizedBox(height: Ds.space.x4),
                Semantics(
                  identifier: 'reg_doc_edit_${_s(f, 'key')}',
                  textField: true,
                  child: f['date'] == true
                      // "Valid till" is picked, never typed: the picker hands
                      // the backend an ISO date, which _custreg_date reads.
                      ? TextField(
                          controller: _ctl[_s(f, 'key')],
                          style: Ds.t.body,
                          readOnly: true,
                          onTap: _saving ? null : () => _pickDate(_s(f, 'key')),
                          decoration: const InputDecoration(
                              suffixIcon: Icon(Icons.calendar_today_outlined)),
                        )
                      : TextField(
                          controller: _ctl[_s(f, 'key')],
                          style: Ds.t.body,
                          textCapitalization: _s(f, 'key') == 'number'
                              ? TextCapitalization.characters
                              : TextCapitalization.words,
                        ),
                ),
                SizedBox(height: Ds.space.x16),
              ],
              if (_error.isNotEmpty) ...[
                Text(_error, style: Ds.t.caption.copyWith(color: Ds.c.danger)),
                SizedBox(height: Ds.space.x12),
              ],
              Row(children: [
                Expanded(
                  child: Semantics(
                    identifier: 'reg_doc_edit_retake',
                    button: true,
                    child: SizedBox(
                      height: Ds.touch.minTarget,
                      child: OutlinedButton(
                        onPressed: _saving ? null : widget.onRetake,
                        child: Text(_s(e, 'retake_label'),
                            maxLines: 1, overflow: TextOverflow.ellipsis),
                      ),
                    ),
                  ),
                ),
                SizedBox(width: Ds.space.x12),
                Expanded(
                  child: Semantics(
                    identifier: 'reg_doc_edit_confirm',
                    button: true,
                    child: SizedBox(
                      height: Ds.touch.minTarget,
                      child: FilledButton(
                        onPressed: _saving ? null : _confirm,
                        child: Text(_s(e, 'confirm_label'),
                            maxLines: 1, overflow: TextOverflow.ellipsis),
                      ),
                    ),
                  ),
                ),
              ]),
            ],
          ),
        ),
      ),
    );
  }
}

/// The document tile the Edit sheet shows beside its title.
Widget docEditThumb(Map<String, dynamic> row, String url, PickedDoc? local) =>
    _Thumb(row: row, local: local, url: url, onTap: null);

/// Reads the two shapes a "Valid till" value arrives in — the backend's
/// `DD Mon YYYY` and the picker's own `YYYY-MM-DD` — or null.
DateTime? parseDocDate(String text) {
  final t = text.trim();
  final iso = DateTime.tryParse(t);
  if (iso != null) return iso;
  final m = RegExp(r'^(\d{1,2})\s+([A-Za-z]{3})[A-Za-z]*\s+(\d{4})$').firstMatch(t);
  if (m == null) return null;
  const months = ['jan', 'feb', 'mar', 'apr', 'may', 'jun',
                  'jul', 'aug', 'sep', 'oct', 'nov', 'dec'];
  final mo = months.indexOf(m.group(2)!.toLowerCase()) + 1;
  if (mo == 0) return null;
  return DateTime(int.parse(m.group(3)!), mo, int.parse(m.group(1)!));
}
