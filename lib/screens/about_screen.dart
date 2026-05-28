import 'package:flutter/material.dart';
import '../theme.dart';

class AboutScreen extends StatelessWidget {
  const AboutScreen({super.key});

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
        title: const Text(
          'About Us',
          style: TextStyle(fontWeight: FontWeight.w700, fontSize: 17, color: Brand.ink),
        ),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(24, 24, 24, 48),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 640),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Header
              Row(
                children: const [
                  Icon(Icons.local_pharmacy, color: Brand.green, size: 36),
                  SizedBox(width: 12),
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('mediBO',
                          style: TextStyle(
                              fontSize: 28,
                              fontWeight: FontWeight.w800,
                              color: Brand.ink,
                              letterSpacing: -0.5)),
                      Text('B2B Pharmacy Platform',
                          style: TextStyle(fontSize: 14, color: Brand.inkMuted)),
                    ],
                  ),
                ],
              ),
              const SizedBox(height: 28),
              const Divider(),
              const SizedBox(height: 24),

              _heading('About Us'),
              const SizedBox(height: 10),
              const Text(
                'mediBO is a B2B pharmacy platform connecting distributors with '
                'pharmacies and clinics across India. We provide genuine medicines '
                'and wellness products with express delivery and competitive B2B pricing.',
                style: TextStyle(fontSize: 15, height: 1.65, color: Brand.ink),
              ),
              const SizedBox(height: 28),

              _heading('Our Mission'),
              const SizedBox(height: 10),
              const Text(
                'To simplify pharmaceutical procurement for pharmacies and clinics '
                'by providing a reliable, transparent and efficient B2B ordering platform.',
                style: TextStyle(fontSize: 15, height: 1.65, color: Brand.ink),
              ),
              const SizedBox(height: 28),

              _heading('Company Details'),
              const SizedBox(height: 12),
              _InfoCard(items: const [
                _InfoRow(Icons.calendar_today_outlined, 'Founded', '2025'),
                _InfoRow(Icons.location_on_outlined, 'Location', 'India'),
                _InfoRow(Icons.storefront_outlined, 'Type', 'B2B Pharmaceutical Platform'),
              ]),
              const SizedBox(height: 28),

              _heading('Contact Details'),
              const SizedBox(height: 12),
              _InfoCard(items: const [
                _InfoRow(Icons.phone_outlined, 'Phone', '9329252090'),
                _InfoRow(Icons.email_outlined, 'Email', 'medibonetwork@gmail.com'),
              ]),
              const SizedBox(height: 28),

              _heading('Drug Licenses'),
              const SizedBox(height: 12),
              _InfoCard(items: const [
                _InfoRow(Icons.verified_outlined, 'License 20B', 'WLF20B2025CT000337'),
                _InfoRow(Icons.verified_outlined, 'License 21B', 'WLF21B2025CT000337'),
              ]),
            ],
          ),
        ),
      ),
    );
  }

  static Widget _heading(String text) => Text(
        text,
        style: const TextStyle(
            fontSize: 18, fontWeight: FontWeight.w800, color: Brand.ink),
      );
}

class _InfoCard extends StatelessWidget {
  final List<_InfoRow> items;
  const _InfoCard({required this.items});

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        border: Border.all(color: Brand.border),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        children: List.generate(items.length, (i) {
          final last = i == items.length - 1;
          return Column(
            children: [
              Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                child: Row(
                  children: [
                    Icon(items[i].icon, size: 18, color: Brand.green),
                    const SizedBox(width: 12),
                    Text(items[i].label,
                        style: const TextStyle(
                            fontSize: 13, color: Brand.inkMuted)),
                    const Spacer(),
                    Flexible(
                      child: Text(items[i].value,
                          textAlign: TextAlign.right,
                          style: const TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                              color: Brand.ink)),
                    ),
                  ],
                ),
              ),
              if (!last) const Divider(height: 1, indent: 46),
            ],
          );
        }),
      ),
    );
  }
}

class _InfoRow {
  final IconData icon;
  final String label;
  final String value;
  const _InfoRow(this.icon, this.label, this.value);
}
