// CHANGE #465: canonical file-extension -> mime/kind helpers for the
// customer-bills feature, shared by the customer Bill tab and the admin
// Customer Orders card (was duplicated as orders_screen.dart's
// mimeFromFileName/isImageFileName and admin_customer_screen.dart's
// _mimeFromBillName).
String mimeFromBillName(String name) {
  final ext = name.contains('.') ? name.split('.').last.toLowerCase() : '';
  switch (ext) {
    case 'pdf':
      return 'application/pdf';
    case 'png':
      return 'image/png';
    case 'jpg':
    case 'jpeg':
      return 'image/jpeg';
    case 'webp':
      return 'image/webp';
    default:
      return 'application/octet-stream';
  }
}

bool isImageBillName(String name) {
  final ext = name.contains('.') ? name.split('.').last.toLowerCase() : '';
  return ext == 'png' || ext == 'jpg' || ext == 'jpeg' || ext == 'webp' || ext == 'gif';
}
