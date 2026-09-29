// CMD #2250 — the shared render pieces for the UPI payee / payment-alert
// screens. Every string these draw arrives in the payload; nothing here
// composes copy, formats money or decides a colour from a number. The only
// decision made in Dart is which token a backend TONE maps to.
import 'package:flutter/material.dart';

import '../../design_tokens.dart';

/// The backend's tone word → the token that paints it.
Color payToneColor(Object? tone) {
  switch ((tone ?? '').toString()) {
    case 'success':
      return Ds.c.success;
    case 'warning':
      return Ds.c.warning;
    case 'danger':
      return Ds.c.danger;
    case 'info':
      return Ds.c.info;
    case 'primary':
    case 'primary_outline':
      return Ds.c.brand;
    default:
      return Ds.c.textSecondary;
  }
}

Color payToneSoft(Object? tone) {
  switch ((tone ?? '').toString()) {
    case 'success':
      return Ds.c.successSoft;
    case 'warning':
      return Ds.c.warningSoft;
    case 'danger':
      return Ds.c.dangerSoft;
    case 'info':
      return Ds.c.infoSoft;
    case 'primary':
    case 'primary_outline':
      return Ds.c.brandSoft;
    default:
      return Ds.c.bg;
  }
}

/// A status chip. Label and tone are the backend's.
class PayChip extends StatelessWidget {
  final String label;
  final Object? tone;
  const PayChip(this.label, {super.key, this.tone});

  @override
  Widget build(BuildContext context) {
    if (label.trim().isEmpty) return const SizedBox.shrink();
    return Container(
      padding: EdgeInsets.symmetric(
          horizontal: Ds.space.x8, vertical: Ds.space.x4),
      decoration: BoxDecoration(
        color: payToneSoft(tone),
        borderRadius: Ds.r.rChip,
      ),
      child: Text(label,
          style: Ds.t.caption.copyWith(
              color: payToneColor(tone), fontWeight: FontWeight.w600)),
    );
  }
}

/// The one card shell every payment surface uses.
class PayCard extends StatelessWidget {
  final Widget child;
  final EdgeInsetsGeometry? padding;
  final Color? background;
  final Color? border;
  final VoidCallback? onTap;
  const PayCard({
    super.key,
    required this.child,
    this.padding,
    this.background,
    this.border,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final body = Container(
      width: double.infinity,
      padding: padding ?? EdgeInsets.all(Ds.space.x16),
      decoration: BoxDecoration(
        color: background ?? Ds.c.surface,
        borderRadius: Ds.r.rCard,
        border: Border.all(color: border ?? Ds.c.divider),
        boxShadow: Ds.elevation.e1,
      ),
      child: child,
    );
    if (onTap == null) return body;
    return InkWell(
      borderRadius: Ds.r.rCard,
      onTap: onTap,
      child: body,
    );
  }
}

/// A label → value line. Both sides are payload strings.
class PayKeyValue extends StatelessWidget {
  final String label;
  final String value;
  const PayKeyValue({super.key, required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    if (value.trim().isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: EdgeInsets.only(bottom: Ds.space.x12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: Ds.t.caption),
          SizedBox(height: Ds.space.x4),
          Text(value,
              style: Ds.t.body.copyWith(fontWeight: FontWeight.w600)),
        ],
      ),
    );
  }
}

/// A coloured banner: tone, title and body all arrive together.
class PayBanner extends StatelessWidget {
  final Map<String, dynamic> block;
  final Widget? trailing;
  const PayBanner(this.block, {super.key, this.trailing});

  @override
  Widget build(BuildContext context) {
    final tone = block['tone'];
    final title = (block['title'] ?? '').toString();
    final body = (block['body'] ?? '').toString();
    if (title.isEmpty && body.isEmpty) return const SizedBox.shrink();
    return Container(
      width: double.infinity,
      padding: EdgeInsets.all(Ds.space.x16),
      decoration: BoxDecoration(
        color: payToneSoft(tone),
        borderRadius: Ds.r.rCard,
        border: Border.all(color: payToneColor(tone).withValues(alpha: 0.35)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            (tone == 'success')
                ? Icons.check_circle_outline
                : Icons.error_outline,
            size: Ds.space.x24,
            color: payToneColor(tone),
          ),
          SizedBox(width: Ds.space.x12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (title.isNotEmpty)
                  Text(title,
                      style: Ds.t.body.copyWith(
                          fontWeight: FontWeight.w700,
                          color: payToneColor(tone))),
                if (body.isNotEmpty) ...[
                  SizedBox(height: Ds.space.x4),
                  Text(body, style: Ds.t.caption),
                ],
              ],
            ),
          ),
          ?trailing,
        ],
      ),
    );
  }
}

/// A full-width primary button. Height comes from the touch token, so it can
/// never fall under the minimum tap target.
class PayPrimaryButton extends StatelessWidget {
  final String label;
  final VoidCallback? onPressed;
  final bool outlined;
  final bool busy;
  const PayPrimaryButton({
    super.key,
    required this.label,
    this.onPressed,
    this.outlined = false,
    this.busy = false,
  });

  @override
  Widget build(BuildContext context) {
    final child = busy
        ? SizedBox(
            height: Ds.space.x16,
            width: Ds.space.x16,
            child: CircularProgressIndicator(
                strokeWidth: 2,
                color: outlined ? Ds.c.brand : Ds.c.surface))
        : Text(label,
            textAlign: TextAlign.center,
            style: Ds.t.body.copyWith(
                fontWeight: FontWeight.w700,
                color: outlined ? Ds.c.brand : Ds.c.surface));
    return SizedBox(
      width: double.infinity,
      height: Ds.touch.minTarget,
      child: outlined
          ? OutlinedButton(
              onPressed: busy ? null : onPressed,
              style: OutlinedButton.styleFrom(
                side: BorderSide(color: Ds.c.brand),
                shape: RoundedRectangleBorder(borderRadius: Ds.r.rButton),
              ),
              child: child)
          : FilledButton(
              onPressed: busy ? null : onPressed,
              style: FilledButton.styleFrom(
                backgroundColor: Ds.c.brand,
                shape: RoundedRectangleBorder(borderRadius: Ds.r.rButton),
              ),
              child: child),
    );
  }
}

/// A section caption ("WHERE CUSTOMERS PAY", "APPS WE READ", …).
class PaySectionLabel extends StatelessWidget {
  final String label;
  const PaySectionLabel(this.label, {super.key});

  @override
  Widget build(BuildContext context) {
    if (label.trim().isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: EdgeInsets.only(bottom: Ds.space.x8),
      child: Text(label,
          style: Ds.t.caption.copyWith(
              fontWeight: FontWeight.w700, letterSpacing: 0.6)),
    );
  }
}

/// The skeleton the screens show while their one RPC is in flight.
class PaySkeleton extends StatelessWidget {
  final int lines;
  const PaySkeleton({super.key, this.lines = 3});

  @override
  Widget build(BuildContext context) {
    return Column(
      children: List<Widget>.generate(
        lines,
        (_) => Padding(
          padding: EdgeInsets.only(bottom: Ds.space.x12),
          child: Container(
            height: Ds.space.x48 + Ds.space.x16,
            decoration: BoxDecoration(
              color: Ds.c.bg,
              borderRadius: Ds.r.rCard,
            ),
          ),
        ),
      ),
    );
  }
}

/// The empty state: one line of backend guidance under a backend title.
class PayEmpty extends StatelessWidget {
  final String label;
  final String hint;
  const PayEmpty({super.key, required this.label, this.hint = ''});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.symmetric(vertical: Ds.space.x32),
      child: Column(
        children: [
          Text(label,
              textAlign: TextAlign.center,
              style: Ds.t.body.copyWith(fontWeight: FontWeight.w600)),
          if (hint.trim().isNotEmpty) ...[
            SizedBox(height: Ds.space.x8),
            Text(hint, textAlign: TextAlign.center, style: Ds.t.caption),
          ],
        ],
      ),
    );
  }
}

/// The error state: the backend's own message, and Retry.
class PayError extends StatelessWidget {
  final String message;
  final String retryLabel;
  final VoidCallback onRetry;
  const PayError({
    super.key,
    required this.message,
    required this.retryLabel,
    required this.onRetry,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.symmetric(vertical: Ds.space.x32),
      child: Column(
        children: [
          Text(message, textAlign: TextAlign.center, style: Ds.t.body),
          SizedBox(height: Ds.space.x16),
          PayPrimaryButton(
              label: retryLabel, outlined: true, onPressed: onRetry),
        ],
      ),
    );
  }
}

List<Map<String, dynamic>> payRows(Object? raw) => (raw is List)
    ? raw.whereType<Map>().map((e) => Map<String, dynamic>.from(e)).toList()
    : const <Map<String, dynamic>>[];

String payStr(Map<String, dynamic> m, String k) => (m[k] ?? '').toString();
