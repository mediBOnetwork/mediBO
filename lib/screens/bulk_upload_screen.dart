// ONE shared implementation for web + Android. All web-only tooling (file
// pick, canvas OCR pre-processing, downloads) now sits behind platform
// wrappers (file_pick_io / web_image_io / download_bytes), so the same screen
// compiles and runs identically on both platforms.
export 'bulk_upload_screen_web.dart';
