// Native no-op agent self-test hooks — mirrors agent_selftest_hooks_web.dart.
// This is browser-only dev tooling; on Android there is nothing to inject.
bool agentSelfTestActive() => false;

String agentSelfTestSearch() => '';

void registerAgentTestHooks({
  required void Function(String detail) onResponse,
  required void Function() onConfirm,
  required void Function(String detail) onSupplier,
}) {}
