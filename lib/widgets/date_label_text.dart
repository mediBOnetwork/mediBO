// CHANGE #546 — renders a backend-formatted date string and nothing else.
//
// This is the ONLY widget in mediBO that puts a date on screen. It holds a raw
// timestamp (exactly as the row carried it) plus a style token, asks
// DateLabels for the backend's string, and prints it verbatim. There is no
// formatting, no timezone math and no fallback copy in this file by design —
// while the label is in flight it renders [placeholder] (an em dash by default).
import 'package:flutter/material.dart';

import '../services/date_labels.dart';

class DateLabelText extends StatefulWidget {
  /// Raw DB timestamp, verbatim (e.g. orders.created_at).
  final String? ts;

  /// A DateStyle token — the format itself is owned by ist_fmt() in Postgres.
  final String style;

  final TextStyle? textStyle;
  final String placeholder;
  final TextAlign? textAlign;
  final int? maxLines;
  final TextOverflow? overflow;

  /// Optional wrapper, e.g. to prefix static copy: (s) => 'Paid $s'.
  /// Only ever receives the backend's own string.
  final String Function(String label)? transform;

  const DateLabelText({
    super.key,
    required this.ts,
    required this.style,
    this.textStyle,
    this.placeholder = '—',
    this.textAlign,
    this.maxLines,
    this.overflow,
    this.transform,
  });

  @override
  State<DateLabelText> createState() => _DateLabelTextState();
}

class _DateLabelTextState extends State<DateLabelText> {
  @override
  void initState() {
    super.initState();
    DateLabels.instance.addListener(_onLabels);
  }

  @override
  void dispose() {
    DateLabels.instance.removeListener(_onLabels);
    super.dispose();
  }

  void _onLabels() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final label = DateLabels.instance.label(widget.ts, widget.style);
    final text = label == null
        ? widget.placeholder
        : (widget.transform?.call(label) ?? label);
    return Text(
      text,
      style: widget.textStyle,
      textAlign: widget.textAlign,
      maxLines: widget.maxLines,
      overflow: widget.overflow,
    );
  }
}
