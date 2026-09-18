// CMD #2065 — Android/iOS have no service worker and no installed-PWA shell,
// so both questions have one honest answer. Returning 'none' (rather than
// 'unknown') is deliberate: the native build must never raise the PWA bar.
Future<String> waitingWorkerState() async => 'none';

Future<bool> isStandalonePwa() async => false;

Future<void> applyWaitingWorker() async {}
