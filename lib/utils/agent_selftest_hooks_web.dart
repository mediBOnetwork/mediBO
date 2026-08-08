// Web agent self-test hooks — verbatim behaviour from the original fulfillment
// code (window.location / localStorage flag + window CustomEvent listeners).
// ignore_for_file: avoid_web_libraries_in_flutter, deprecated_member_use
import 'dart:html' as html;

bool agentSelfTestActive() {
  try {
    final search = html.window.location.search ?? '';
    final href = html.window.location.href ?? '';
    final ls = html.window.localStorage['medibo_agentselftest'] ?? '';
    return search.contains('agentselftest=1') ||
        href.contains('agentselftest=1') ||
        ls == '1';
  } catch (_) {
    return false;
  }
}

String agentSelfTestSearch() {
  try {
    return html.window.location.search ?? '';
  } catch (_) {
    return '';
  }
}

String _detail(html.Event e) {
  final d = (e as html.CustomEvent).detail;
  return d is String ? d : (d?.toString() ?? '');
}

void registerAgentTestHooks({
  required void Function(String detail) onResponse,
  required void Function() onConfirm,
  required void Function(String detail) onSupplier,
}) {
  html.window.addEventListener(
      'medibo_injectAgentResponse', (e) => onResponse(_detail(e)));
  html.window.addEventListener(
      'medibo_injectAgentConfirm', (_) => onConfirm());
  html.window.addEventListener(
      'medibo_injectAgentSupplier', (e) => onSupplier(_detail(e)));
}
