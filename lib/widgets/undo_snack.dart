import 'package:flutter/material.dart';
import '../design_tokens.dart';

/// CHANGE #1017 (5) — an undo snackbar instead of a confirm dialog.
///
/// The action already happened; the bar offers to take it back for a moment.
/// Labels are the backend's (`copy.undo`); the message is whatever the RPC
/// returned. `onUndo` is the caller's compensating call — this file decides
/// nothing about what undo means.
void showUndoSnack(
  BuildContext context, {
  required String message,
  required String undoLabel,
  required Future<void> Function() onUndo,
}) {
  if (message.isEmpty) return;
  final m = ScaffoldMessenger.maybeOf(context);
  if (m == null) return;
  m.hideCurrentSnackBar();
  m.showSnackBar(SnackBar(
    content: Text(message),
    duration: Duration(milliseconds: Ds.motion.sheetMs * 16),
    behavior: SnackBarBehavior.floating,
    action: undoLabel.isEmpty
        ? null
        : SnackBarAction(label: undoLabel, textColor: Ds.c.brand, onPressed: () { onUndo(); }),
  ));
}
