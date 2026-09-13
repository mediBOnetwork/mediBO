// CMD #1947 — the staff header's date·zone chip, RENDER half only.
//
// Deliberately free of Supabase, of the scope singletons and of RenderLog
// (which imports dart:html and cannot load under `flutter test`), exactly like
// zone_picker_view.dart. That is what lets the chip's rules be pinned against
// an inline admin_scope_chip() payload with no network — see
// test/protected/scope_chip_test.dart.
//
// It renders an admin_scope_chip() payload and reports taps. It decides
// NOTHING: not whether the chip appears (show), not what it says (label /
// compact_label), not the sheet's headings (sheet.*), not what a zone row is
// called (zone.options[].label, including the All-zones entry whose label is
// config). The one thing computed here is layout — truncation, so the chip
// gives way before the centred logo ever does.
import 'package:flutter/material.dart';

import '../design_tokens.dart';

/// Pure render of the header chip. `compact` is the web's <1000px form: the
/// calendar icon plus `compact_label` (the zone code) and nothing else.
class ScopeChipView extends StatelessWidget {
  final Map<String, dynamic> payload;
  final bool compact;
  final double? maxWidth;
  final VoidCallback? onTap;

  const ScopeChipView({
    super.key,
    required this.payload,
    this.compact = false,
    this.maxWidth,
    this.onTap,
  });

  bool get _show => payload['show'] == true;

  /// The chip's text, verbatim. Nothing is assembled here — the backend sent
  /// "12 Sep · Raipur" and "ALL" already joined.
  String get _text => compact
      ? (payload['compact_label']?.toString() ?? '')
      : (payload['label']?.toString() ?? '');

  @override
  Widget build(BuildContext context) {
    // show:false -> render NOTHING. No placeholder, no disabled chip.
    if (!_show) return const SizedBox.shrink();
    final text = _text;
    if (text.isEmpty) return const SizedBox.shrink();

    final chip = Container(
      constraints: BoxConstraints(minHeight: Ds.touch.minTarget),
      padding: EdgeInsets.symmetric(horizontal: Ds.space.x12),
      decoration: BoxDecoration(
        color: Ds.c.brandSoft,
        borderRadius: Ds.r.rChip,
        border: Border.all(color: Ds.c.divider),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.calendar_today_outlined,
              size: Ds.t.captionSize, color: Ds.c.brand),
          SizedBox(width: Ds.space.x8),
          // Flexible + ellipsis is the whole responsive story: the chip
          // truncates ("12 Sep · Rai…") long before the header's centred logo
          // can be pushed off centre.
          Flexible(
            child: Text(
              text,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              softWrap: false,
              style: Ds.t.caption.copyWith(
                  color: Ds.c.text, fontWeight: FontWeight.w600),
            ),
          ),
        ],
      ),
    );

    // The cap lives on the OUTSIDE, so the whole tap target — ink included —
    // stays inside what the header allowed it. A chip whose ink spilled past
    // its own border would overlap the centred logo it was capped to protect.
    return ConstrainedBox(
      constraints: BoxConstraints(maxWidth: maxWidth ?? double.infinity),
      child: Tooltip(
        message: payload['tooltip']?.toString() ?? '',
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: onTap,
            borderRadius: Ds.r.rChip,
            child: chip,
          ),
        ),
      ),
    );
  }
}

/// The sheet's zone half: the zone_picker() payload as a tappable list.
///
/// Reports the chosen option's `zone_id` VERBATIM — including null for the
/// All-zones entry, which is a real value and never a missing one. can_change
/// false (a zone-locked partner) renders the selected label as static text.
class ScopeZoneList extends StatelessWidget {
  final Map<String, dynamic> zone;
  final ValueChanged<int?>? onSelect;

  const ScopeZoneList({super.key, required this.zone, this.onSelect});

  List<Map<String, dynamic>> get _options {
    final o = zone['options'];
    return o is List
        ? o.whereType<Map>().map((e) => Map<String, dynamic>.from(e)).toList()
        : const <Map<String, dynamic>>[];
  }

  @override
  Widget build(BuildContext context) {
    final canChange = zone['can_change'] == true;
    final options = _options;
    final selectedLabel = zone['selected_label']?.toString() ?? '';

    if (!canChange || options.isEmpty) {
      if (selectedLabel.isEmpty) return const SizedBox.shrink();
      return Padding(
        padding: EdgeInsets.symmetric(vertical: Ds.space.x12),
        child: Row(children: [
          Icon(Icons.place_outlined,
              size: Ds.t.bodySize, color: Ds.c.textSecondary),
          SizedBox(width: Ds.space.x8),
          Expanded(child: Text(selectedLabel, style: Ds.t.body)),
        ]),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final o in options)
          InkWell(
            onTap: () => onSelect?.call((o['zone_id'] as num?)?.toInt()),
            child: Container(
              constraints: BoxConstraints(minHeight: Ds.touch.minTarget),
              padding: EdgeInsets.symmetric(horizontal: Ds.space.x4),
              child: Row(children: [
                SizedBox(
                  width: Ds.space.x24,
                  child: o['selected'] == true
                      ? Icon(Icons.check,
                          size: Ds.t.bodySize, color: Ds.c.brand)
                      : null,
                ),
                Expanded(
                  child: Text(
                    o['label']?.toString() ?? '',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: o['selected'] == true
                        ? Ds.t.body.copyWith(
                            color: Ds.c.brand, fontWeight: FontWeight.w700)
                        : Ds.t.body,
                  ),
                ),
              ]),
            ),
          ),
      ],
    );
  }
}

/// The sheet's chrome: grab handle, backend title, and the two sections whose
/// headings are the payload's own `sheet.date_title` / `sheet.zone_title`.
class ScopeSheetView extends StatelessWidget {
  final Map<String, dynamic> payload;
  final Widget dateChild;
  final Widget zoneChild;
  final VoidCallback? onDone;

  const ScopeSheetView({
    super.key,
    required this.payload,
    required this.dateChild,
    required this.zoneChild,
    this.onDone,
  });

  Map<String, dynamic> get _sheet {
    final s = payload['sheet'];
    return s is Map ? Map<String, dynamic>.from(s) : const {};
  }

  bool get _hasZone => (payload['zone'] is Map) &&
      ((payload['zone'] as Map)['show'] == true ||
          ((payload['zone'] as Map)['selected_label']?.toString() ?? '')
              .isNotEmpty);

  @override
  Widget build(BuildContext context) {
    final sheet = _sheet;
    final title = sheet['title']?.toString() ?? '';
    final dateTitle = sheet['date_title']?.toString() ?? '';
    final zoneTitle = sheet['zone_title']?.toString() ?? '';
    final doneLabel = sheet['done_label']?.toString() ?? '';

    return SafeArea(
      top: false,
      child: Padding(
        padding: EdgeInsets.fromLTRB(
            Ds.space.x16, Ds.space.x8, Ds.space.x16, Ds.space.x16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(
              child: Container(
                width: Ds.space.x48,
                height: Ds.space.x4,
                decoration: BoxDecoration(
                  color: Ds.c.divider,
                  borderRadius: Ds.r.rChip,
                ),
              ),
            ),
            SizedBox(height: Ds.space.x16),
            if (title.isNotEmpty) Text(title, style: Ds.t.title),
            SizedBox(height: Ds.space.x16),
            if (dateTitle.isNotEmpty)
              Text(dateTitle, style: Ds.t.caption),
            SizedBox(height: Ds.space.x8),
            dateChild,
            if (_hasZone) ...[
              SizedBox(height: Ds.space.x24),
              if (zoneTitle.isNotEmpty)
                Text(zoneTitle, style: Ds.t.caption),
              SizedBox(height: Ds.space.x8),
              zoneChild,
            ],
            SizedBox(height: Ds.space.x24),
            if (doneLabel.isNotEmpty)
              SizedBox(
                width: double.infinity,
                height: Ds.touch.minTarget,
                child: FilledButton(
                  onPressed: onDone,
                  style: FilledButton.styleFrom(
                    backgroundColor: Ds.c.brand,
                    shape: RoundedRectangleBorder(
                        borderRadius: Ds.r.rButton),
                  ),
                  child: Text(doneLabel),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
