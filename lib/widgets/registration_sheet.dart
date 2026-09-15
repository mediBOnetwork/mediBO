// CMD #2059 — the registration form as a bottom sheet over the cart.
//
// Ordering is the ONLY thing an unregistered account cannot do. Tapping Place
// order therefore does not send anyone away from their basket: the form opens
// over it, and submitting closes it again with the cart still underneath.
//
// Which blocker answers with this sheet is the backend's call, not this file's:
// `my_session().order_gate.action_kind` is 'registration_sheet' for exactly the
// unregistered case. Every string here — the title, the line under it, the
// close label, the confirmation — comes from
// `customer_registration_payload().sheet`.
import 'package:flutter/material.dart';

import '../design_tokens.dart';
import '../screens/auth/one_registration_screen.dart';
import '../services/registration_payload.dart';
import '../utils/render_log.dart';
import 'customer_surface_widgets.dart';

/// Opens the sheet. Returns true when the details were saved.
Future<bool> showRegistrationSheet(BuildContext context) async {
  await RegistrationSurface.restore();
  unawaitedRefresh();
  if (!context.mounted) return false;

  final sheet = RegistrationSurface.sheet;
  RenderLog.write('c2059_reg_sheet', 1);

  final saved = await showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    backgroundColor: Ds.c.surface,
    shape: RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(Ds.r.sheet)),
    ),
    builder: (ctx) => FractionallySizedBox(
      heightFactor: 0.94,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _SheetHead(
            title: (sheet['title'] ?? '').toString(),
            line: (sheet['line'] ?? '').toString(),
            closeLabel: (sheet['close_label'] ?? '').toString(),
            onClose: () => Navigator.of(ctx).pop(false),
          ),
          // CMD #2061 — the cart sheet is the SAME form as /complete-registration,
          // documents included. Three doors, one screen: a shop that registers
          // from its basket is asked for its papers in the same breath, and a
          // paper it does not have is a skip, not a second trip.
          Expanded(
            child: OneRegistrationScreen(
              embedded: true,
              // Saved from the cart: the basket is what they came back for,
              // so the sheet closes onto it.
              onSaved: () {
                RegistrationSurface.submitted();
                Navigator.of(ctx).pop(true);
              },
            ),
          ),
        ],
      ),
    ),
  );
  return saved == true;
}

/// Refresh the surface behind the sheet without making the open wait on it.
void unawaitedRefresh() {
  RegistrationSurface.refresh().ignore();
}

class _SheetHead extends StatelessWidget {
  const _SheetHead({
    required this.title,
    required this.line,
    required this.closeLabel,
    required this.onClose,
  });

  final String title;
  final String line;
  final String closeLabel;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final steps = RegistrationSurface.steps;
    return Padding(
      padding: EdgeInsets.fromLTRB(
          Ds.space.x16, Ds.space.x12, Ds.space.x16, Ds.space.x8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (title.isNotEmpty) Text(title, style: Ds.t.subtitle),
                    if (line.isNotEmpty) ...[
                      SizedBox(height: Ds.space.x4),
                      Text(line, style: Ds.t.caption),
                    ],
                  ],
                ),
              ),
              SizedBox(width: Ds.space.x8),
              SizedBox(
                height: Ds.touch.minTarget,
                child: TextButton(
                  onPressed: onClose,
                  child: Text(closeLabel),
                ),
              ),
            ],
          ),
          if (steps.isNotEmpty) ...[
            SizedBox(height: Ds.space.x12),
            RegistrationStepStrip(step: RegistrationSurface.step, steps: steps),
          ],
        ],
      ),
    );
  }
}
