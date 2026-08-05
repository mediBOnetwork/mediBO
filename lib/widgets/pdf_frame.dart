// Platform-conditional PDF frame: web renders the PDF in a browser <iframe>;
// native renders a tappable icon that opens the PDF url externally.
export 'pdf_frame_stub.dart'
    if (dart.library.html) 'pdf_frame_web.dart';
