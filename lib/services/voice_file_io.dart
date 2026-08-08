// Platform-conditional recording-file glue for VoiceReceiveService.
//   Web    → `record` returns an in-memory blob URL: path is '' and the bytes
//            are fetched over http from the blob URL.
//   Native → `record` writes to a real file: we must hand it a writable temp
//            path and read the bytes back with dart:io (http.get can't read a
//            filesystem path — that empty-path/http.get combo crashed Android).
export 'voice_file_io_stub.dart' if (dart.library.html) 'voice_file_io_web.dart';
