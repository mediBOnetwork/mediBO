// Platform-conditional file/photo picking that returns bytes+name.
//   Web    → dart:html file input (preserves accept list + camera capture).
//   Native → file_picker (import) / image_picker camera (photo).
// Returns null when the user cancels.
export 'file_pick_io_stub.dart' if (dart.library.html) 'file_pick_io_web.dart';
