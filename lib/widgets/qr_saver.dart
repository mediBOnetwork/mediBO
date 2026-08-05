// Platform-conditional QR-code save. Web triggers a browser download of the
// PNG via an anchor element; native has no such download path, so saving is
// unsupported and the caller hides the control.
export 'qr_saver_stub.dart'
    if (dart.library.html) 'qr_saver_web.dart';
