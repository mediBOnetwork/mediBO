// Native: there is no object URL. Returning null is the honest answer and the
// caller shows the backend's "no preview" copy rather than launching an
// external viewer.
String? createObjectUrl(List<int> bytes, String mimeType) => null;

void revokeObjectUrl(String url) {}
