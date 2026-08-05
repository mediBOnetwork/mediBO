// Native has no browser anchor-download path — QR save is unsupported here and
// the caller hides its button when kQrSaveSupported is false.
const bool kQrSaveSupported = false;

void saveQrPng(String b64, String filename) {}
