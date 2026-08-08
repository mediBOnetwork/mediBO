// Platform-conditional dev/test injection hooks for the fulfillment agent
// self-test (?agentselftest=1). Web wires window CustomEvents; native is a
// no-op (no browser event bus, and this is test-only tooling).
export 'agent_selftest_hooks_stub.dart'
    if (dart.library.html) 'agent_selftest_hooks_web.dart';
