// Platform-conditional entry to the live Speech-to-Text stream + PCM mic.
// dart.library.io is present on Android/desktop and ABSENT on web, so the web
// build compiles the stub (which never runs — the live path is Android-gated)
// and never pulls grpc/dart:io into the dart2js bundle.
export 'speech_native_stub.dart'
    if (dart.library.io) 'speech_native_io.dart';
