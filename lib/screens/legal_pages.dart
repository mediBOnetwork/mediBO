import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../theme.dart';
import '../widgets/policy_page_layout.dart';

// CHANGE #619 — the partner identity constants that used to live here
// (business name, owner, GSTIN, address, both drug licences, issuing
// authority, phone) are gone. Partner details appear on About and nowhere
// else. Everything these pages say about who operates mediBO now comes from
// platform_public_identity(), which carries no partner data at all.

// ─── Body helpers ─────────────────────────────────────────────────────────────

Widget _h(String text) => Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Text(text,
          style: const TextStyle(
              fontSize: 18, fontWeight: FontWeight.w800, color: Brand.ink)),
    );

Widget _p(String text) => Padding(
      padding: const EdgeInsets.only(bottom: 20),
      child: Text(text,
          style: const TextStyle(
              fontSize: 14, height: 1.7, color: Brand.ink)),
    );

Widget _numbered(List<String> items) => Padding(
      padding: const EdgeInsets.only(bottom: 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (int i = 0; i < items.length; i++)
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('${i + 1}. ',
                      style: const TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w700,
                          color: Brand.green)),
                  Expanded(
                    child: Text(items[i],
                        style: const TextStyle(
                            fontSize: 14, height: 1.65, color: Brand.ink)),
                  ),
                ],
              ),
            ),
        ],
      ),
    );

/// CHANGE #619 — fetches `platform_public_identity()` once and hands the
/// payload to [build], which returns the numbered clauses. The RPC is
/// anon-readable so the logged-out policy pages render.
class PlatformCopy extends StatefulWidget {
  final List<String> Function(Map<String, dynamic> payload) build;
  const PlatformCopy(this.build, {super.key});

  @override
  State<PlatformCopy> createState() => _PlatformCopyState();
}

class _PlatformCopyState extends State<PlatformCopy> {
  Map<String, dynamic>? _data;
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _failed = false);
    try {
      final raw =
          await Supabase.instance.client.rpc('platform_public_identity');
      if (!mounted) return;
      setState(() => _data = Map<String, dynamic>.from(raw as Map));
    } catch (e) {
      if (!mounted) return;
      setState(() => _failed = true);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_failed) {
      // No payload means no copy to show — icon-only retry keeps this page
      // free of client-side strings on the failure path.
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 32),
        child: Center(
          child: IconButton(
            onPressed: _load,
            icon: const Icon(Icons.refresh, size: 26, color: Brand.green),
          ),
        ),
      );
    }
    final d = _data;
    if (d == null) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 32),
        child: Center(
          child: CircularProgressIndicator(color: Brand.green, strokeWidth: 3),
        ),
      );
    }
    return _numbered(widget.build(d));
  }
}

/// Reads a string field, never null.
String platformField(Map<String, dynamic> p, String key) {
  final v = p[key];
  return v is String ? v : '';
}

Widget _infoRow(IconData icon, String label, String value) => Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 16, color: Brand.green),
          const SizedBox(width: 10),
          Expanded(
            child: RichText(
              text: TextSpan(
                style: const TextStyle(
                    fontSize: 14, height: 1.6, color: Brand.ink),
                children: [
                  TextSpan(
                      text: '$label: ',
                      style: const TextStyle(fontWeight: FontWeight.w600)),
                  TextSpan(text: value),
                ],
              ),
            ),
          ),
        ],
      ),
    );

// ─── Terms & Conditions ───────────────────────────────────────────────────────

class TermsScreen extends StatelessWidget {
  const TermsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return PolicyPageLayout(
      title: 'Terms & Conditions',
      lastUpdated: 'Last updated: May 2025',
      child: PlatformCopy((p) => [
        platformField(p, 'terms_intro'),
        'Eligibility: Buyers must be registered businesses holding a valid drug licence. We may verify your licence and GST before fulfilling orders.',
        'You are responsible for the security of your account credentials and for all activity under your account.',
        'Prices are listed in Indian Rupees (INR) and are exclusive of applicable taxes unless stated. We may revise prices and product availability without prior notice.',
        'You agree to use the platform only for lawful business purposes and in compliance with all applicable laws, including the Drugs and Cosmetics Act, 1940.',
        'We are not liable for indirect or consequential losses. Our total liability for any order is limited to the value of that order.',
        'These terms are governed by the laws of India; courts at Raipur, Chhattisgarh have exclusive jurisdiction.',
      ]),
    );
  }
}

// ─── Privacy Policy ───────────────────────────────────────────────────────────

class PrivacyScreen extends StatelessWidget {
  const PrivacyScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return PolicyPageLayout(
      title: 'Privacy Policy',
      lastUpdated: 'Last updated: May 2025',
      child: PlatformCopy((p) => [
        'We collect business KYC details (name, address, GSTIN, drug licence), contact information, and order/transaction data necessary to provide our services.',
        'We use this data to process orders, verify eligibility, comply with legal obligations, and communicate with you.',
        'We share data with payment partners to process payments, and with authorities where required by law.',
        'We retain transaction records as required under applicable law and apply reasonable security measures to protect your data.',
        'We do not store full card credentials. Payments are processed by our PCI-DSS compliant payment partner.',
        'For privacy queries or data requests, contact ${platformField(p, 'email')}.',
      ]),
    );
  }
}

// ─── Refund & Return Policy ───────────────────────────────────────────────────

class RefundScreen extends StatelessWidget {
  const RefundScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return PolicyPageLayout(
      title: 'Refund & Return Policy',
      lastUpdated: 'Last updated: May 2025',
      child: PlatformCopy((p) => [
        'As a B2B pharmaceutical supplier, returns are accepted only for items that are damaged in transit, expired on delivery, or incorrectly supplied.',
        'Return requests must be raised within 2 business days of delivery with photographic proof, by emailing ${platformField(p, 'email')}.',
        'Temperature-sensitive products, opened packs, and products without intact original packaging are non-returnable for safety and regulatory reasons.',
        'Approved refunds are processed to the original payment method within 7–10 business days of return approval.',
        'Order value, applicable taxes, and any non-recoverable charges are handled as per the order invoice.',
      ]),
    );
  }
}

// ─── Shipping & Delivery Policy ───────────────────────────────────────────────

class ShippingScreen extends StatelessWidget {
  const ShippingScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return PolicyPageLayout(
      title: 'Shipping & Delivery Policy',
      lastUpdated: 'Last updated: May 2025',
      child: _numbered([
        'Orders are dispatched within 1–2 business days of confirmation and payment, subject to stock and licence verification.',
        'Estimated delivery is 3–7 business days depending on destination.',
        'Temperature-sensitive items are shipped with appropriate cold-chain handling where applicable.',
        'Delivery is made to the registered business address of the licensed buyer. Risk passes on delivery.',
        'Delays due to courier, weather, or regulatory checks are beyond our control; we will keep you informed.',
      ]),
    );
  }
}

// ─── Cancellation Policy ──────────────────────────────────────────────────────

class CancellationScreen extends StatelessWidget {
  const CancellationScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return PolicyPageLayout(
      title: 'Cancellation Policy',
      lastUpdated: 'Last updated: May 2025',
      child: PlatformCopy((p) => [
        'Orders may be cancelled free of charge any time before dispatch by emailing ${platformField(p, 'email')} or via the dashboard.',
        'Once dispatched, an order cannot be cancelled and is governed by the Refund & Return Policy.',
        'Refunds for valid pre-dispatch cancellations are processed to the original payment method within 7–10 business days.',
      ]),
    );
  }
}
