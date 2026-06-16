import 'dart:js_interop';

const _kGisClientId =
    '565577322247-9ls2ocm01sjilq2sb17r5afm6se9jfr4.apps.googleusercontent.com';

@JS('mediboGisSignIn')
external JSPromise<JSString?> _mediboGisSignIn(JSString clientId);

/// Shows the GIS modal and returns the Google ID token, or null if cancelled /
/// GIS failed to load.  Never throws — callers check for null.
Future<String?> gisGetIdToken() async {
  try {
    final result = await _mediboGisSignIn(_kGisClientId.toJS).toDart;
    return result?.toDart;
  } catch (_) {
    return null;
  }
}
