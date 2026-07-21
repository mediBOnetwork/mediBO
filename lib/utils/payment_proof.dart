// CHANGE #474 — shared storage-bucket resolver for payment proof screenshots.
// Proofs live in one of two private buckets: WhatsApp/cash proofs land in
// 'whatsapp-media', customer-app uploads land in 'payment-proofs'. Callers
// that already know the bucket (customer_order_payment_panel supplies it)
// should pass it straight through; callers whose RPC omits it
// (admin_order_payment_view) get it derived from the path prefix.
String resolvePaymentProofBucket(String? explicitBucket, String path) {
  final b = explicitBucket?.trim();
  if (b != null && b.isNotEmpty) return b;
  return (path.startsWith('whatsapp/') || path.startsWith('cash_payments/'))
      ? 'whatsapp-media'
      : 'payment-proofs';
}
