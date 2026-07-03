// CHANGE #338: shared 2-second hold-to-delete/re-add row wrapper for voice
// mention rows (Shop / Warehouse counted popup + Pack counted sheet).
//
// Uses Listener (raw pointer events), NOT GestureDetector.onLongPress — the
// platform long-press threshold is ~500 ms which is too short. The 2000 ms
// timer starts on pointer-down and is cancelled on pointer-up/cancel or if
// the pointer moves more than ~24 px (scroll intent).
//
// frozen=true → row is dimmed with a lock glyph and the hold is disabled
// (post-confirm shop/warehouse rows, packed pack items).
import 'dart:async';
import 'package:flutter/material.dart';

class MentionHoldRow extends StatefulWidget {
  final Widget child;
  final VoidCallback? onHoldComplete; // null = hold disabled
  final bool frozen; // if true: show lock glyph, dim child, disable hold

  const MentionHoldRow({
    super.key,
    required this.child,
    this.onHoldComplete,
    this.frozen = false,
  });

  @override
  State<MentionHoldRow> createState() => _MentionHoldRowState();
}

class _MentionHoldRowState extends State<MentionHoldRow> {
  Timer? _timer;
  bool _holding = false;
  Offset? _startPos;

  void _start(Offset pos) {
    if (widget.frozen || widget.onHoldComplete == null) return;
    _startPos = pos;
    setState(() => _holding = true);
    _timer = Timer(const Duration(milliseconds: 2000), () {
      _timer = null;
      if (!mounted) return;
      setState(() => _holding = false);
      widget.onHoldComplete!();
    });
  }

  void _cancel() {
    _timer?.cancel();
    _timer = null;
    _startPos = null;
    if (_holding && mounted) setState(() => _holding = false);
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Listener(
      behavior: HitTestBehavior.opaque,
      onPointerDown: (e) => _start(e.position),
      onPointerUp: (_) => _cancel(),
      onPointerCancel: (_) => _cancel(),
      onPointerMove: (e) {
        if (_startPos != null && (e.position - _startPos!).distance > 24) {
          _cancel();
        }
      },
      child: Stack(
        alignment: Alignment.centerRight,
        children: [
          widget.frozen
              ? Opacity(opacity: 0.45, child: widget.child)
              : widget.child,
          if (widget.frozen)
            const Padding(
              padding: EdgeInsets.only(right: 8),
              child: Icon(Icons.lock_rounded, size: 14, color: Color(0xFF9CA3AF)),
            )
          else if (_holding)
            const Padding(
              padding: EdgeInsets.only(right: 8),
              child: SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: Color(0xFF1B7A43),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

// #338 §2.3: row background by mention status ('deleted' | 'readded' | other).
BoxDecoration? mentionRowDecoration(String? status) {
  switch (status) {
    case 'deleted':
      return BoxDecoration(
        color: const Color(0xFFFEE2E2), // light red
        borderRadius: BorderRadius.circular(8),
        boxShadow: [
          BoxShadow(color: Colors.red.withValues(alpha: 0.08), blurRadius: 4),
        ],
      );
    case 'readded':
      return BoxDecoration(
        color: const Color(0xFFFEF3C7), // light amber
        borderRadius: BorderRadius.circular(8),
      );
    default:
      return null;
  }
}
