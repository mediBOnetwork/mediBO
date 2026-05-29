import 'package:flutter/material.dart';
import '../theme.dart';

// ─── Shared constants ────────────────────────────────────────────────────────

const _kBusiness = 'Jai Mahakal Medical And Surgical';
const _kOwner    = 'Anshu Jaiswal (Proprietor)';
const _kGstin    = '22BXXPJ8518F1Z4';
const _kAddress  = 'P H No 19, Vill-Jaunda, R N M-Champaran, Tah-Gobra Nawapara, District-Raipur, Chhattisgarh - 493885';
const _kDl20b    = 'WLF20B2025CT000337';
const _kDl21b    = 'WLF21B2025CT000337';
const _kAuthority = 'Food & Drugs Administration Chhattisgarh, Raipur';
const _kEmail    = 'medibonetwork@gmail.com';
const _kPhone    = '9329252090';

// ─── Shared scaffold ─────────────────────────────────────────────────────────

class _LegalScaffold extends StatelessWidget {
  final String title;
  final List<Widget> children;
  const _LegalScaffold({required this.title, required this.children});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      appBar: AppBar(
        backgroundColor: Colors.white,
        foregroundColor: Brand.ink,
        elevation: 0,
        surfaceTintColor: Colors.white,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_ios_new, size: 18),
          onPressed: () => Navigator.of(context).pop(),
        ),
        title: Text(title,
            style: const TextStyle(
                fontWeight: FontWeight.w700, fontSize: 17, color: Brand.ink)),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(24, 24, 24, 56),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 680),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: children,
            ),
          ),
        ),
      ),
    );
  }
}

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
    return _LegalScaffold(
      title: 'Terms & Conditions',
      children: [
        _h('Terms & Conditions'),
        _p('Last updated: May 2025'),
        _numbered([
          '$_kBusiness ("we", "us") operates the mediBO B2B platform at medibo.in for wholesale supply of pharmaceutical and healthcare products to licensed businesses only.',
          'Eligibility: Buyers must be registered businesses holding a valid drug licence. We may verify your licence and GST before fulfilling orders.',
          'You are responsible for the security of your account credentials and for all activity under your account.',
          'Prices are listed in Indian Rupees (INR) and are exclusive of applicable taxes unless stated. We may revise prices and product availability without prior notice.',
          'You agree to use the platform only for lawful business purposes and in compliance with all applicable laws, including the Drugs and Cosmetics Act, 1940.',
          'We are not liable for indirect or consequential losses. Our total liability for any order is limited to the value of that order.',
          'These terms are governed by the laws of India; courts at Raipur, Chhattisgarh have exclusive jurisdiction.',
        ]),
      ],
    );
  }
}

// ─── Privacy Policy ───────────────────────────────────────────────────────────

class PrivacyScreen extends StatelessWidget {
  const PrivacyScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return _LegalScaffold(
      title: 'Privacy Policy',
      children: [
        _h('Privacy Policy'),
        _p('Last updated: May 2025'),
        _numbered([
          'We collect business KYC details (name, address, GSTIN, drug licence), contact information, and order/transaction data necessary to provide our services.',
          'We use this data to process orders, verify eligibility, comply with legal obligations, and communicate with you.',
          'We share data with payment partners (including Razorpay) to process payments, and with authorities where required by law.',
          'We retain transaction records as required under applicable law and apply reasonable security measures to protect your data.',
          'We do not store full card credentials. Payments are processed by our PCI-DSS compliant payment partner.',
          'For privacy queries or data requests, contact $_kEmail.',
        ]),
      ],
    );
  }
}

// ─── Refund & Return Policy ───────────────────────────────────────────────────

class RefundScreen extends StatelessWidget {
  const RefundScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return _LegalScaffold(
      title: 'Refund & Return Policy',
      children: [
        _h('Refund & Return Policy'),
        _p('Last updated: May 2025'),
        _numbered([
          'As a B2B pharmaceutical supplier, returns are accepted only for items that are damaged in transit, expired on delivery, or incorrectly supplied.',
          'Return requests must be raised within 2 business days of delivery with photographic proof, by emailing $_kEmail.',
          'Temperature-sensitive products, opened packs, and products without intact original packaging are non-returnable for safety and regulatory reasons.',
          'Approved refunds are processed to the original payment method within 7–10 business days of return approval.',
          'Order value, applicable taxes, and any non-recoverable charges are handled as per the order invoice.',
        ]),
      ],
    );
  }
}

// ─── Shipping & Delivery Policy ───────────────────────────────────────────────

class ShippingScreen extends StatelessWidget {
  const ShippingScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return _LegalScaffold(
      title: 'Shipping & Delivery Policy',
      children: [
        _h('Shipping & Delivery Policy'),
        _p('Last updated: May 2025'),
        _numbered([
          'Orders are dispatched within 1–2 business days of confirmation and payment, subject to stock and licence verification.',
          'Estimated delivery is 3–7 business days depending on destination.',
          'Temperature-sensitive items are shipped with appropriate cold-chain handling where applicable.',
          'Delivery is made to the registered business address of the licensed buyer. Risk passes on delivery.',
          'Delays due to courier, weather, or regulatory checks are beyond our control; we will keep you informed.',
        ]),
      ],
    );
  }
}

// ─── Cancellation Policy ──────────────────────────────────────────────────────

class CancellationScreen extends StatelessWidget {
  const CancellationScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return _LegalScaffold(
      title: 'Cancellation Policy',
      children: [
        _h('Cancellation Policy'),
        _p('Last updated: May 2025'),
        _numbered([
          'Orders may be cancelled free of charge any time before dispatch by emailing $_kEmail or via the dashboard.',
          'Once dispatched, an order cannot be cancelled and is governed by the Refund & Return Policy.',
          'Refunds for valid pre-dispatch cancellations are processed to the original payment method within 7–10 business days.',
        ]),
      ],
    );
  }
}
