// CHANGE #609 — the zone picker's RENDER half, and nothing else.
//
// Deliberately free of the AdminZoneScope singleton, of Supabase, and of
// RenderLog (which imports dart:html and so cannot load under `flutter test`).
// That is what lets the show / can_change / null-zone_id rules be pinned down
// against an inline payload with no network — see
// test/c609_zone_picker_test.dart.
//
// It renders a zone_picker() payload and reports the chosen option's zone_id
// VERBATIM. It decides nothing: not whether the control appears (show), not
// whether it is tappable (can_change), not what any entry is called
// (options[].label — including the All-zones entry, whose label is config).
import 'package:flutter/material.dart';

/// Pure render of a zone_picker() payload. Reports the chosen option's
/// `zone_id` VERBATIM — including null for the All-zones entry.
class ZonePickerView extends StatefulWidget {
  final Map<String, dynamic> payload;

  /// Receives the selected option's zone_id exactly as the payload carried it.
  /// null is a real value ("All zones"), never a missing one.
  final Future<void> Function(int? zoneId)? onSelect;

  const ZonePickerView({super.key, required this.payload, this.onSelect});

  @override
  State<ZonePickerView> createState() => _ZonePickerViewState();
}

class _ZonePickerViewState extends State<ZonePickerView> {
  final GlobalKey _anchorKey = GlobalKey();
  bool _busy = false;

  bool get _show => widget.payload['show'] == true;
  bool get _canChange => widget.payload['can_change'] == true;
  String get _title => widget.payload['title']?.toString() ?? '';
  String get _selectedLabel =>
      widget.payload['selected_label']?.toString() ?? '';

  List<Map<String, dynamic>> get _options {
    final o = widget.payload['options'];
    return o is List
        ? o
            .whereType<Map>()
            .map((e) => Map<String, dynamic>.from(e))
            .toList()
        : const <Map<String, dynamic>>[];
  }

  Future<void> _open() async {
    final options = _options;
    if (!_canChange || options.isEmpty || _busy) return;

    final box = _anchorKey.currentContext?.findRenderObject() as RenderBox?;
    final overlayBox =
        Overlay.of(context).context.findRenderObject() as RenderBox?;
    if (box == null || overlayBox == null) return;

    final origin = box.localToGlobal(Offset.zero, ancestor: overlayBox);
    final position = RelativeRect.fromLTRB(
      origin.dx,
      origin.dy + box.size.height + 4,
      overlayBox.size.width - origin.dx - box.size.width,
      0,
    );

    // The menu carries the whole option, never the bare zone_id: a null value
    // would be indistinguishable from the user dismissing the menu, and the
    // All-zones id IS null.
    final picked = await showMenu<Map<String, dynamic>>(
      context: context,
      position: position,
      items: [
        for (final o in options)
          PopupMenuItem<Map<String, dynamic>>(
            value: o,
            child: _MenuRow(
              label: (o['label'] as String?) ?? '',
              selected: o['selected'] == true,
            ),
          ),
      ],
    );

    if (!mounted || picked == null) return;
    if (picked['selected'] == true) return; // already current — no write

    // VERBATIM: null for the All-zones entry, never 0 / -1 / ''.
    final zoneId = (picked['zone_id'] as num?)?.toInt();

    setState(() => _busy = true);
    try {
      await widget.onSelect?.call(zoneId);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    // show:false -> render NOTHING. No placeholder, no disabled chip.
    if (!_show) return const SizedBox.shrink();

    final label = _selectedLabel;

    // can_change:false -> static text with `title` as its caption. No dropdown,
    // no tap target, no arrow.
    if (!_canChange) {
      if (label.isEmpty) return const SizedBox.shrink();
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
        decoration: BoxDecoration(
          color: const Color(0xFFF9FAFB),
          border: Border.all(color: const Color(0xFFE5E7EB)),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          const Icon(Icons.place_outlined, size: 14, color: Color(0xFF6B7280)),
          const SizedBox(width: 7),
          if (_title.isNotEmpty) ...[
            Text(_title,
                style:
                    const TextStyle(fontSize: 12, color: Color(0xFF9CA3AF))),
            const SizedBox(width: 6),
          ],
          Text(label,
              style: const TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: Color(0xFF374151))),
        ]),
      );
    }

    return InkWell(
      key: _anchorKey,
      onTap: _busy ? null : _open,
      borderRadius: BorderRadius.circular(10),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
        decoration: BoxDecoration(
          color: Colors.white,
          border: Border.all(color: const Color(0xFFE5E7EB)),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          const Icon(Icons.place_outlined, size: 14, color: Color(0xFF6B7280)),
          const SizedBox(width: 7),
          // No client-side fallback text: an empty backend label stays empty.
          if (label.isNotEmpty)
            Text(label,
                style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: Color(0xFF374151))),
          const SizedBox(width: 4),
          _busy
              ? const SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(
                      strokeWidth: 2, color: Color(0xFF6B7280)))
              : const Icon(Icons.arrow_drop_down,
                  size: 18, color: Color(0xFF6B7280)),
        ]),
      ),
    );
  }
}

class _MenuRow extends StatelessWidget {
  final String label;
  final bool selected;
  const _MenuRow({required this.label, required this.selected});

  @override
  Widget build(BuildContext context) {
    return Row(mainAxisSize: MainAxisSize.min, children: [
      SizedBox(
        width: 20,
        child: selected
            ? const Icon(Icons.check, size: 15, color: Color(0xFF1B7A43))
            : null,
      ),
      Text(
        label,
        style: TextStyle(
          fontSize: 13,
          fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
          color: selected ? const Color(0xFF1B7A43) : const Color(0xFF374151),
        ),
      ),
    ]);
  }
}
