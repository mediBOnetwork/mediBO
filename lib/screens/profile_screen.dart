import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../user_state.dart';

class ProfileScreen extends StatelessWidget {
  const ProfileScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final auth = UserState.of(context);
    final profile = auth.profile;
    final email =
        Supabase.instance.client.auth.currentUser?.email ?? '';

    return Scaffold(
      backgroundColor: const Color(0xFFF9FAFB),
      appBar: AppBar(
        backgroundColor: Colors.white,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_ios_new,
              size: 20, color: Color(0xFF1B5E20)),
          onPressed: () => Navigator.of(context).pop(),
        ),
        title: const Text(
          'My Profile',
          style: TextStyle(
            fontSize: 18,
            fontWeight: FontWeight.w800,
            color: Color(0xFF111827),
          ),
        ),
        centerTitle: false,
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(1),
          child: Container(height: 1, color: const Color(0xFFE5E7EB)),
        ),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.symmetric(horizontal: 0, vertical: 0),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 600),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // Avatar + pharmacy name header
                Container(
                  color: Colors.white,
                  padding: const EdgeInsets.fromLTRB(24, 28, 24, 24),
                  child: Column(
                    children: [
                      Container(
                        width: 72,
                        height: 72,
                        decoration: const BoxDecoration(
                          color: Color(0xFF1B5E20),
                          shape: BoxShape.circle,
                        ),
                        child: const Icon(Icons.storefront,
                            color: Colors.white, size: 36),
                      ),
                      const SizedBox(height: 14),
                      Text(
                        profile?.displayName ?? 'My Pharmacy',
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                          fontSize: 20,
                          fontWeight: FontWeight.w800,
                          color: Color(0xFF111827),
                        ),
                      ),
                      if (profile?.ownerName.isNotEmpty == true) ...[
                        const SizedBox(height: 4),
                        Text(
                          profile!.ownerName,
                          textAlign: TextAlign.center,
                          style: const TextStyle(
                            fontSize: 14,
                            color: Color(0xFF6B7280),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),

                // "Contact support" notice
                Container(
                  margin: const EdgeInsets.fromLTRB(16, 16, 16, 4),
                  padding: const EdgeInsets.symmetric(
                      horizontal: 14, vertical: 10),
                  decoration: BoxDecoration(
                    color: const Color(0xFFFFFBEB),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: const Color(0xFFFCD34D)),
                  ),
                  child: const Row(
                    children: [
                      Icon(Icons.info_outline,
                          size: 16, color: Color(0xFFD97706)),
                      SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          'To update your details, contact support.',
                          style: TextStyle(
                            fontSize: 12,
                            color: Color(0xFF92400E),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),

                // Profile fields card
                Container(
                  margin: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: const Color(0xFFE5E7EB)),
                  ),
                  child: Column(
                    children: [
                      _InfoRow(
                        label: 'Owner Name',
                        value: profile?.ownerName,
                        icon: Icons.person_outline,
                      ),
                      _InfoRow(
                        label: 'Pharmacy / Clinic Name',
                        value: profile?.pharmacyName,
                        icon: Icons.storefront_outlined,
                      ),
                      _InfoRow(
                        label: 'Phone Number',
                        value: profile?.phone,
                        icon: Icons.phone_outlined,
                      ),
                      _InfoRow(
                        label: 'Email',
                        value: email.isNotEmpty ? email : null,
                        icon: Icons.email_outlined,
                      ),
                      _InfoRow(
                        label: 'GSTIN',
                        value: profile?.gstin,
                        icon: Icons.receipt_long_outlined,
                      ),
                      _InfoRow(
                        label: 'Drug License Number',
                        value: profile?.drugLicense,
                        icon: Icons.verified_outlined,
                      ),
                      _InfoRow(
                        label: 'Full Address',
                        value: profile?.address,
                        icon: Icons.location_on_outlined,
                      ),
                      _InfoRow(
                        label: 'City',
                        value: profile?.city,
                        icon: Icons.location_city_outlined,
                      ),
                      _InfoRow(
                        label: 'Pincode',
                        value: profile?.pincode,
                        icon: Icons.pin_drop_outlined,
                        isLast: true,
                      ),
                    ],
                  ),
                ),

                // Logout button
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 24, 16, 40),
                  child: OutlinedButton.icon(
                    onPressed: () async {
                      await UserState.read(context).signOut();
                      if (context.mounted) {
                        Navigator.of(context).popUntil((r) => r.isFirst);
                      }
                    },
                    icon: const Icon(Icons.logout,
                        size: 18, color: Color(0xFFDC2626)),
                    label: const Text('Logout'),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: const Color(0xFFDC2626),
                      side: const BorderSide(
                          color: Color(0xFFDC2626), width: 1.5),
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(10)),
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      textStyle: const TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _InfoRow extends StatelessWidget {
  final String label;
  final String? value;
  final IconData icon;
  final bool isLast;

  const _InfoRow({
    required this.label,
    required this.value,
    required this.icon,
    this.isLast = false,
  });

  @override
  Widget build(BuildContext context) {
    final display =
        (value != null && value!.isNotEmpty) ? value! : '—';

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(icon, size: 18, color: const Color(0xFF9CA3AF)),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      label,
                      style: const TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w500,
                        color: Color(0xFF9CA3AF),
                        letterSpacing: 0.3,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      display,
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        color: display == '—'
                            ? const Color(0xFFD1D5DB)
                            : const Color(0xFF111827),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        if (!isLast)
          const Divider(height: 1, indent: 46, color: Color(0xFFF3F4F6)),
      ],
    );
  }
}
