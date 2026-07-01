import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../utils/render_log.dart';

// CHANGE #307: shared code-field widget used by both customer and supplier forms.
enum CodeStatus { idle, invalid, checking, available, taken }

/// Text field with format validation (^[A-Z]{3}[0-9]{3}$) and async
/// uniqueness check via [isTaken].  Used for both Customer Code and
/// Supplier Code fields.
class CodeField extends StatefulWidget {
  final TextEditingController controller;
  final String label;
  final String hint;

  /// Returns true if the code is already taken by another record.
  final Future<bool> Function(String code) isTaken;

  /// Edit mode: skip availability check when the typed value matches
  /// the existing code for this record.
  final String? originalCode;

  final bool requiredField;
  final void Function(CodeStatus) onStatusChanged;

  const CodeField({
    super.key,
    required this.controller,
    required this.label,
    required this.hint,
    required this.isTaken,
    required this.onStatusChanged,
    this.originalCode,
    this.requiredField = true,
  });

  @override
  State<CodeField> createState() => _CodeFieldState();
}

class _CodeFieldState extends State<CodeField> {
  CodeStatus _status = CodeStatus.idle;
  Timer? _debounce;

  static final _kFmt = RegExp(r'^[A-Z]{3}[0-9]{3}$');

  @override
  void initState() {
    super.initState();
    try { RenderLog.write('c307_shared_widget', 'rendered'); } catch (_) {}
  }

  @override
  void dispose() {
    _debounce?.cancel();
    super.dispose();
  }

  void _onChanged(String v) {
    final raw = v.trim().toUpperCase();
    try { RenderLog.write('c307_supplier_code_field', 'len=${raw.length}'); } catch (_) {}
    if (raw.isEmpty) {
      _debounce?.cancel();
      _set(CodeStatus.idle);
      return;
    }
    if (!_kFmt.hasMatch(raw)) {
      _debounce?.cancel();
      _set(CodeStatus.invalid);
      return;
    }
    try { RenderLog.write('c307_format_ok', 'code=$raw'); } catch (_) {}
    if (widget.originalCode != null &&
        raw == widget.originalCode!.trim().toUpperCase()) {
      _debounce?.cancel();
      _set(CodeStatus.available);
      return;
    }
    _set(CodeStatus.checking);
    _debounce?.cancel();
    _debounce = Timer(
        const Duration(milliseconds: 350), () => _checkAvailability(raw));
  }

  Future<void> _checkAvailability(String code) async {
    try {
      try { RenderLog.write('c307_avail_check', 'code=$code'); } catch (_) {}
      final taken = await widget.isTaken(code);
      if (!mounted) return;
      _set(taken ? CodeStatus.taken : CodeStatus.available);
    } catch (_) {
      if (mounted) _set(CodeStatus.idle);
    }
  }

  void _set(CodeStatus s) {
    setState(() => _status = s);
    widget.onStatusChanged(s);
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        TextFormField(
          controller: widget.controller,
          maxLength: 6,
          textCapitalization: TextCapitalization.characters,
          inputFormatters: [
            LengthLimitingTextInputFormatter(6),
            TextInputFormatter.withFunction(
              (_, nv) => nv.copyWith(text: nv.text.toUpperCase()),
            ),
          ],
          onChanged: _onChanged,
          decoration: InputDecoration(
            labelText:
                widget.requiredField ? '${widget.label} *' : widget.label,
            hintText: widget.hint,
            counterText: '',
            border:
                OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(10),
              borderSide: const BorderSide(color: Color(0xFFD1D5DB)),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(10),
              borderSide: const BorderSide(color: Color(0xFF1B7A43)),
            ),
            isDense: true,
            contentPadding:
                const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          ),
          validator: widget.requiredField
              ? (v) {
                  if (v == null || v.trim().isEmpty) return 'Required';
                  if (!_kFmt.hasMatch(v.trim().toUpperCase())) {
                    return '3 letters + 3 digits (e.g. ABC123)';
                  }
                  return null;
                }
              : null,
        ),
        _statusWidget(),
      ],
    );
  }

  Widget _statusWidget() {
    switch (_status) {
      case CodeStatus.idle:
        return const SizedBox.shrink();
      case CodeStatus.invalid:
        return _row(Icons.error_outline, const Color(0xFFDC2626),
            '3 letters + 3 digits, e.g. ABC123');
      case CodeStatus.checking:
        return const Padding(
          padding: EdgeInsets.only(top: 6),
          child: Row(children: [
            SizedBox(
                width: 14,
                height: 14,
                child: CircularProgressIndicator(strokeWidth: 2)),
            SizedBox(width: 6),
            Text('Checking…',
                style: TextStyle(fontSize: 12, color: Color(0xFF6B7280))),
          ]),
        );
      case CodeStatus.available:
        return _row(
            Icons.check_circle_outline, const Color(0xFF16A34A), 'Available ✓');
      case CodeStatus.taken:
        return _row(Icons.cancel_outlined, const Color(0xFFDC2626),
            'Already in use — choose another');
    }
  }

  Widget _row(IconData icon, Color color, String text) => Padding(
        padding: const EdgeInsets.only(top: 6),
        child: Row(children: [
          Icon(icon, size: 14, color: color),
          const SizedBox(width: 4),
          Flexible(
              child:
                  Text(text, style: TextStyle(fontSize: 12, color: color))),
        ]),
      );
}
