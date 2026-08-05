// Platform-conditional full-page reload: web reloads the browser to pick up a
// new build; native has no page to reload (the APK updates out of band).
export 'page_reload_stub.dart'
    if (dart.library.html) 'page_reload_web.dart';
