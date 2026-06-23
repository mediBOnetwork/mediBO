import 'package:flutter/material.dart';
import '../utils/render_log.dart';
import 'dispute_state.dart';

// Shared card widget used by admin, supplier portal, and public link page.
// The caller decides context by wiring (or not) the relevant callbacks.
// Admin context:   wire onResolve / onAgreeSupplier / onReSource / onCopyLink
// Supplier context: wire onRespondMissing / onRespondSupplied / onRespondCorrect / onRespondOos
// readOnly:        pass readOnly=true to suppress all action rows

class DisputeCard extends StatelessWidget {
  final Map<String, dynamic> dispute;
  final bool isProcessing;

  // Admin actions
  final VoidCallback? onCopyLink;
  final VoidCallback? onResolve;
  final VoidCallback? onAgreeSupplier;
  final VoidCallback? onReSource;

  // Supplier / link-page actions (pass non-null only when the supplier can respond)
  final VoidCallback? onRespondMissing;
  final VoidCallback? onRespondSupplied;
  final VoidCallback? onRespondCorrect;
  final VoidCallback? onRespondOos;

  final bool readOnly;

  const DisputeCard({
    super.key,
    required this.dispute,
    this.isProcessing = false,
    this.onCopyLink,
    this.onResolve,
    this.onAgreeSupplier,
    this.onReSource,
    this.onRespondMissing,
    this.onRespondSupplied,
    this.onRespondCorrect,
    this.onRespondOos,
    this.readOnly = false,
  });

  static const _kText    = Color(0xFF111827);
  static const _kSub     = Color(0xFF6B7280);
  static const _kBorder  = Color(0xFFE5E7EB);
  static const _kGreen   = Color(0xFF1B7A43);

  @override
  Widget build(BuildContext context) {
    final view        = DisputeView.of(dispute);
    final kind        = dispute['kind']?.toString() ?? 'short';
    final isWrong     = kind == 'wrong_item';
    final product     = dispute['product_name']?.toString() ?? '—';
    final wrongProd   = dispute['wrong_product_name']?.toString();
    final supplier    = dispute['supplier']?.toString() ?? '';
    final mode        = dispute['mode']?.toString() ?? '';
    final ordered     = (dispute['ordered'] as num?)?.toInt() ?? 0;
    final received    = (dispute['received'] as num?)?.toInt() ?? 0;
    final short       = (dispute['short'] as num?)?.toInt() ?? 0;
    final disputeId   = dispute['dispute_id']?.toString() ?? '';

    RenderLog.write('c178_card',
        'dispute_id=$disputeId;state=${view.state.name};label=${view.label}');

    final actions = _buildActions(view, kind);

    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.06),
            blurRadius: 8,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          // Line 1: product name + kind tag
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Expanded(
              child: Text(
                product,
                style: const TextStyle(
                    fontSize: 16, fontWeight: FontWeight.w600, color: _kText),
              ),
            ),
            const SizedBox(width: 8),
            _kindTag(isWrong),
          ]),

          // Line 2: supplier · mode (optional)
          if (supplier.isNotEmpty || mode.isNotEmpty) ...[
            const SizedBox(height: 4),
            Text(
              [if (supplier.isNotEmpty) supplier, if (mode.isNotEmpty) mode].join(' · '),
              style: const TextStyle(fontSize: 12, color: _kSub),
            ),
          ],

          // Line 3: status row (dot + bold label)
          const SizedBox(height: 10),
          _statusRow(view),

          // Line 4: subline
          const SizedBox(height: 4),
          Text(view.subline,
              style: const TextStyle(fontSize: 13, color: _kSub)),

          // Line 5: number strip or wrong-item two lines
          const SizedBox(height: 10),
          if (isWrong) ...[
            Text('Ordered: $product',
                style: const TextStyle(fontSize: 12, color: _kSub)),
            const SizedBox(height: 2),
            Text(
              'Sent: ${(wrongProd != null && wrongProd.isNotEmpty) ? wrongProd : '—'}',
              style: const TextStyle(fontSize: 12, color: _kText),
            ),
          ] else
            Text(
              'Ordered $ordered   Received $received   Short $short',
              style: const TextStyle(fontSize: 12, color: _kSub),
            ),

          // Line 6: actions
          ...actions,
        ]),
      ),
    );
  }

  Widget _kindTag(bool isWrong) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
    decoration: BoxDecoration(
      color: isWrong ? const Color(0xFFEEF2FF) : const Color(0xFFF1F5F9),
      borderRadius: BorderRadius.circular(4),
    ),
    child: Text(
      isWrong ? 'Wrong item' : 'Short',
      style: TextStyle(
        fontSize: 11,
        fontWeight: FontWeight.w600,
        color: isWrong ? const Color(0xFF4338CA) : const Color(0xFF475569),
      ),
    ),
  );

  Widget _statusRow(DisputeView view) {
    final isResolved = view.state == DisputeState.resolved;
    return Row(children: [
      if (isResolved)
        const Icon(Icons.check_circle_rounded, size: 14, color: Color(0xFF6B7280))
      else
        Container(
          width: 10, height: 10,
          decoration: BoxDecoration(color: view.dot, shape: BoxShape.circle),
        ),
      const SizedBox(width: 6),
      Text(
        view.label,
        style: TextStyle(
            fontSize: 14, fontWeight: FontWeight.w700, color: view.dot),
      ),
    ]);
  }

  List<Widget> _buildActions(DisputeView view, String kind) {
    if (readOnly) {
      if (view.state == DisputeState.resolved) return [];
      return [const SizedBox(height: 8), _stateChip(view)];
    }

    // Admin context
    if (onResolve != null || onAgreeSupplier != null || onReSource != null) {
      return _adminActions(view);
    }

    // Supplier / link-page context
    if (onRespondMissing != null || onRespondSupplied != null ||
        onRespondCorrect != null || onRespondOos != null) {
      return _supplierActions(view, kind);
    }

    // No callbacks wired → read-only chip for non-resolved
    if (view.state != DisputeState.resolved) {
      return [const SizedBox(height: 8), _stateChip(view)];
    }
    return [];
  }

  List<Widget> _adminActions(DisputeView view) {
    switch (view.state) {
      case DisputeState.needsYou:
        return [
          const SizedBox(height: 12),
          const Divider(height: 1, color: _kBorder),
          const SizedBox(height: 10),
          Row(children: [
            Expanded(
              child: OutlinedButton(
                onPressed: isProcessing ? null : onAgreeSupplier,
                style: OutlinedButton.styleFrom(
                  foregroundColor: _kText,
                  side: const BorderSide(color: _kBorder),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(8)),
                  padding: const EdgeInsets.symmetric(vertical: 10),
                ),
                child: const Text('Agree supplier',
                    style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: FilledButton(
                onPressed: isProcessing ? null : onReSource,
                style: FilledButton.styleFrom(
                  backgroundColor: _kGreen,
                  disabledBackgroundColor:
                      _kGreen.withValues(alpha: 0.4),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(8)),
                  padding: const EdgeInsets.symmetric(vertical: 10),
                ),
                child: isProcessing
                    ? const SizedBox(
                        width: 14, height: 14,
                        child: CircularProgressIndicator(
                            color: Colors.white, strokeWidth: 2))
                    : const Text('Re-source',
                        style: TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                            color: Colors.white)),
              ),
            ),
          ]),
        ];

      case DisputeState.waiting:
        return [
          const SizedBox(height: 12),
          const Divider(height: 1, color: _kBorder),
          const SizedBox(height: 10),
          Row(children: [
            if (onCopyLink != null) ...[
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: onCopyLink,
                  style: OutlinedButton.styleFrom(
                    foregroundColor: const Color(0xFF6D5BD0),
                    side: const BorderSide(color: Color(0xFFDDD6FE)),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(8)),
                    padding: const EdgeInsets.symmetric(vertical: 10),
                  ),
                  icon: const Icon(Icons.copy_rounded, size: 14),
                  label: const Text('Copy link',
                      style: TextStyle(
                          fontSize: 13, fontWeight: FontWeight.w600)),
                ),
              ),
              const SizedBox(width: 8),
            ],
            Expanded(
              child: FilledButton(
                onPressed: isProcessing ? null : onResolve,
                style: FilledButton.styleFrom(
                  backgroundColor: _kGreen,
                  disabledBackgroundColor:
                      _kGreen.withValues(alpha: 0.4),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(8)),
                  padding: const EdgeInsets.symmetric(vertical: 10),
                ),
                child: isProcessing
                    ? const SizedBox(
                        width: 14, height: 14,
                        child: CircularProgressIndicator(
                            color: Colors.white, strokeWidth: 2))
                    : const Text('Resolve',
                        style: TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                            color: Colors.white)),
              ),
            ),
          ]),
        ];

      case DisputeState.resourcing:
      case DisputeState.exchange:
        return [
          const SizedBox(height: 12),
          const Divider(height: 1, color: _kBorder),
          const SizedBox(height: 10),
          SizedBox(
            width: double.infinity,
            child: FilledButton(
              onPressed: isProcessing ? null : onResolve,
              style: FilledButton.styleFrom(
                backgroundColor: _kGreen,
                disabledBackgroundColor: _kGreen.withValues(alpha: 0.4),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(8)),
                padding: const EdgeInsets.symmetric(vertical: 10),
              ),
              child: isProcessing
                  ? const SizedBox(
                      width: 14, height: 14,
                      child: CircularProgressIndicator(
                          color: Colors.white, strokeWidth: 2))
                  : const Text('Resolve',
                      style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          color: Colors.white)),
            ),
          ),
        ];

      case DisputeState.resolved:
        return [];
    }
  }

  List<Widget> _supplierActions(DisputeView view, String kind) {
    if (view.state == DisputeState.waiting) {
      if (kind == 'wrong_item') {
        return [
          const SizedBox(height: 12),
          const Divider(height: 1, color: _kBorder),
          const SizedBox(height: 10),
          SizedBox(
            width: double.infinity,
            child: FilledButton(
              onPressed: isProcessing ? null : onRespondCorrect,
              style: FilledButton.styleFrom(
                backgroundColor: _kGreen,
                disabledBackgroundColor: _kGreen.withValues(alpha: 0.4),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(8)),
                padding: const EdgeInsets.symmetric(vertical: 12),
              ),
              child: isProcessing
                  ? const SizedBox(
                      width: 14, height: 14,
                      child: CircularProgressIndicator(
                          color: Colors.white, strokeWidth: 2))
                  : const Text('Yes, sending the correct item',
                      style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w700,
                          color: Colors.white)),
            ),
          ),
          const SizedBox(height: 8),
          SizedBox(
            width: double.infinity,
            child: OutlinedButton(
              onPressed: isProcessing ? null : onRespondOos,
              style: OutlinedButton.styleFrom(
                foregroundColor: _kText,
                side: const BorderSide(color: _kBorder),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(8)),
                padding: const EdgeInsets.symmetric(vertical: 12),
              ),
              child: const Text('Out of stock',
                  style:
                      TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
            ),
          ),
        ];
      } else {
        return [
          const SizedBox(height: 12),
          const Divider(height: 1, color: _kBorder),
          const SizedBox(height: 10),
          SizedBox(
            width: double.infinity,
            child: FilledButton(
              onPressed: isProcessing ? null : onRespondMissing,
              style: FilledButton.styleFrom(
                backgroundColor: const Color(0xFFD97706),
                disabledBackgroundColor: const Color(0xFFFDE68A),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(8)),
                padding: const EdgeInsets.symmetric(vertical: 12),
              ),
              child: isProcessing
                  ? const SizedBox(
                      width: 14, height: 14,
                      child: CircularProgressIndicator(
                          color: Colors.white, strokeWidth: 2))
                  : const Text('Yes, it was short / missing',
                      style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w700,
                          color: Colors.white)),
            ),
          ),
          const SizedBox(height: 8),
          SizedBox(
            width: double.infinity,
            child: OutlinedButton(
              onPressed: isProcessing ? null : onRespondSupplied,
              style: OutlinedButton.styleFrom(
                foregroundColor: _kText,
                side: const BorderSide(color: _kBorder),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(8)),
                padding: const EdgeInsets.symmetric(vertical: 12),
              ),
              child: const Text('No, I supplied it',
                  style:
                      TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
            ),
          ),
        ];
      }
    }
    // Non-waiting in supplier context: show state chip
    return [const SizedBox(height: 8), _stateChip(view)];
  }

  Widget _stateChip(DisputeView view) {
    final isResolved = view.state == DisputeState.resolved;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: isResolved
            ? const Color(0xFFF3F4F6)
            : view.dot.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(
        view.label,
        style: TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w600,
          color: isResolved ? _kSub : view.dot,
        ),
      ),
    );
  }
}
