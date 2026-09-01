import 'package:flutter/material.dart';

import '../design_tokens.dart';
import '../services/ui_copy.dart';

/// CHANGE #459 · GAP 179 — a signed-out visit to an admin route printed the
/// driver's own exception, centred on the page:
///
///   PostgrestException(message: permission denied for function
///   feature_gaps_list, code: 42501, details: , hint: null)
///
/// The RPC was refusing correctly; the SCREEN was the bug. A refusal is an
/// answer, and every answer belongs to the backend — so this is the one error
/// surface, and it prints `ui_copy` for the driver's CODE. The driver message
/// is never rendered, in any state, for any code.
///
/// Deliberately Supabase-free: the code is read off the error by duck typing
/// (`(e as dynamic).code`), so this widget pumps on the Dart VM and can sit in
/// any file without dragging a `dart:*`-adjacent import into the widget tree.
class BackendError {
  /// The `ui_copy` prefix this error resolves to — `error.42501`, `error.generic`…
  final String keyPrefix;

  const BackendError(this.keyPrefix);

  /// The driver code, mapped to the copy family that explains it.
  factory BackendError.fromCode(String? code) {
    final c = (code ?? '').trim().toLowerCase();
    if (c == '42501') return const BackendError('error.42501');
    if (c == 'pgrst301' || c == '401') return const BackendError('error.pgrst301');
    return const BackendError('error.generic');
  }

  /// Reads the code off ANY thrown object without importing its package.
  /// A network failure carries no code, so it lands on its own family.
  factory BackendError.from(Object? e) {
    if (e == null) return const BackendError('error.generic');
    String? code;
    try {
      final dynamic d = e;
      final raw = d.code;
      if (raw is String) code = raw;
    } catch (_) {
      code = null;
    }
    if (code == null && _looksOffline(e)) return const BackendError('error.network');
    return BackendError.fromCode(code);
  }

  static bool _looksOffline(Object e) {
    final s = e.runtimeType.toString();
    return s.contains('SocketException') ||
        s.contains('ClientException') ||
        s.contains('TimeoutException');
  }

  String get title => c('$keyPrefix.title');
  String get body => c('$keyPrefix.body');
  String get actionLabel => c('$keyPrefix.action');

  /// A refusal the viewer cannot retry their way out of — the action signs in.
  bool get isRefusal => keyPrefix == 'error.42501' || keyPrefix == 'error.pgrst301';
}

/// The shared error state. Backend copy, one action, no driver text.
class BackendErrorView extends StatelessWidget {
  final BackendError error;

  /// Retry for a transient error; sign-in for a refusal. The screen supplies
  /// whichever it can — a null callback simply renders no button.
  final VoidCallback? onAction;

  const BackendErrorView({super.key, required this.error, this.onAction});

  @override
  Widget build(BuildContext context) {
    final label = error.actionLabel;
    return Center(
      child: Padding(
        padding: EdgeInsets.all(Ds.space.x24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              error.isRefusal ? Icons.lock_outline : Icons.cloud_off_outlined,
              color: Ds.c.textSecondary,
            ),
            SizedBox(height: Ds.space.x12),
            Text(error.title, style: Ds.t.subtitle, textAlign: TextAlign.center),
            SizedBox(height: Ds.space.x8),
            Text(error.body, style: Ds.t.caption, textAlign: TextAlign.center),
            if (onAction != null && label.isNotEmpty) ...[
              SizedBox(height: Ds.space.x24),
              SizedBox(
                height: Ds.touch.minTarget,
                child: FilledButton(onPressed: onAction, child: Text(label)),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
