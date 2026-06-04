import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../user_state.dart';
import 'auth/business_details_screen.dart';

class ProfileScreen extends StatelessWidget {
  const ProfileScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final auth = UserState.of(context);
    final profile = auth.profile;
    final authUser = Supabase.instance.client.auth.currentUser;
    final authEmail = authUser?.email ?? '';
    final isRegistered = auth.isRegistered;

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
                        profile?.displayName ?? 'My Account',
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                          fontSize: 20,
                          fontWeight: FontWeight.w800,
                          color: Color(0xFF111827),
                        ),
                      ),
                      if ((profile?.customerName ?? '').isNotEmpty) ...[
                        const SizedBox(height: 4),
                        Text(
                          profile!.customerName,
                          textAlign: TextAlign.center,
                          style: const TextStyle(
                            fontSize: 14,
                            color: Color(0xFF6B7280),
                          ),
                        ),
                      ],
                      const SizedBox(height: 14),
                      _AccountStatusBadge(
                        isRegistered: isRegistered,
                        isApproved: profile?.isApproved ?? false,
                        status: profile?.status ?? 'pending',
                      ),
                    ],
                  ),
                ),

                // Unregistered: complete registration CTA
                if (!isRegistered) ...[
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
                    child: Container(
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        color: const Color(0xFFF0FDF4),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: const Color(0xFFBBF7D0)),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          const Row(
                            children: [
                              Icon(Icons.info_outline,
                                  size: 18, color: Color(0xFF15803D)),
                              SizedBox(width: 8),
                              Expanded(
                                child: Text(
                                  'Registration required to place orders',
                                  style: TextStyle(
                                    fontSize: 13,
                                    fontWeight: FontWeight.w600,
                                    color: Color(0xFF15803D),
                                  ),
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 10),
                          SizedBox(
                            height: 44,
                            child: FilledButton(
                              onPressed: () {
                                final user = authUser;
                                if (user == null) return;
                                Navigator.of(context).push(
                                  MaterialPageRoute(
                                    builder: (_) => BusinessDetailsScreen(
                                      userId: user.id,
                                      phone: user.phone ?? '',
                                      email: user.email ?? '',
                                    ),
                                  ),
                                );
                              },
                              style: FilledButton.styleFrom(
                                backgroundColor: const Color(0xFF1B5E20),
                                shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(8)),
                                elevation: 0,
                              ),
                              child: const Text(
                                'Complete Registration',
                                style: TextStyle(
                                    fontWeight: FontWeight.w700, fontSize: 14),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],

                // Pending: approval notice
                if (isRegistered && !(profile?.isApproved ?? false)) ...[
                  Container(
                    margin: const EdgeInsets.fromLTRB(16, 16, 16, 0),
                    padding: const EdgeInsets.symmetric(
                        horizontal: 14, vertical: 10),
                    decoration: BoxDecoration(
                      color: const Color(0xFFFFFBEB),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: const Color(0xFFFCD34D)),
                    ),
                    child: const Row(
                      children: [
                        Icon(Icons.access_time,
                            size: 16, color: Color(0xFFD97706)),
                        SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            'Your account is pending admin approval. You will be able to place orders once approved.',
                            style: TextStyle(
                              fontSize: 12,
                              color: Color(0xFF92400E),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],

                // Suspended: account blocked notice
                if (isRegistered &&
                    (profile?.isApproved ?? false) &&
                    profile?.status == 'suspended') ...[
                  Container(
                    margin: const EdgeInsets.fromLTRB(16, 16, 16, 0),
                    padding: const EdgeInsets.symmetric(
                        horizontal: 14, vertical: 10),
                    decoration: BoxDecoration(
                      color: const Color(0xFFFFF1F2),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: const Color(0xFFFCA5A5)),
                    ),
                    child: const Row(
                      children: [
                        Icon(Icons.block, size: 16, color: Color(0xFFDC2626)),
                        SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            'Your account has been suspended. You cannot place orders. Contact support to reactivate.',
                            style: TextStyle(
                              fontSize: 12,
                              color: Color(0xFF991B1B),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],

                // Registered: profile fields
                if (isRegistered) ...[
                  Container(
                    margin: const EdgeInsets.fromLTRB(16, 16, 16, 4),
                    padding: const EdgeInsets.symmetric(
                        horizontal: 14, vertical: 10),
                    decoration: BoxDecoration(
                      color: const Color(0xFFF9FAFB),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: const Color(0xFFE5E7EB)),
                    ),
                    child: const Row(
                      children: [
                        Icon(Icons.info_outline,
                            size: 16, color: Color(0xFF9CA3AF)),
                        SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            'To update your details, contact support.',
                            style: TextStyle(
                              fontSize: 12,
                              color: Color(0xFF6B7280),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),

                  // Business details
                  _SectionCard(
                    icon: Icons.storefront_outlined,
                    title: 'Business Details',
                    children: [
                      _InfoRow(
                        label: 'Customer / Contact Name',
                        value: profile?.customerName,
                        icon: Icons.person_outline,
                      ),
                      _InfoRow(
                        label: 'Pharmacy / Clinic Name',
                        value: profile?.pharmacyName,
                        icon: Icons.storefront_outlined,
                      ),
                      _InfoRow(
                        label: 'Store Type',
                        value: profile?.storeType,
                        icon: Icons.category_outlined,
                      ),
                      _InfoRow(
                        label: 'Delivery Range',
                        value: profile?.rangeZone,
                        icon: Icons.local_shipping_outlined,
                        isLast: true,
                      ),
                    ],
                  ),

                  // Address
                  _SectionCard(
                    icon: Icons.location_on_outlined,
                    title: 'Address',
                    children: [
                      _InfoRow(
                        label: 'Local Address',
                        value: profile?.addressLocal,
                        icon: Icons.home_outlined,
                      ),
                      _InfoRow(
                        label: 'City',
                        value: profile?.city,
                        icon: Icons.location_city_outlined,
                      ),
                      _InfoRow(
                        label: 'State',
                        value: profile?.state,
                        icon: Icons.map_outlined,
                      ),
                      _InfoRow(
                        label: 'Pincode',
                        value: profile?.pincode,
                        icon: Icons.pin_drop_outlined,
                      ),
                      _InfoRow(
                        label: 'Store Location Link',
                        value: profile?.storeLocationLink,
                        icon: Icons.link_outlined,
                        isLast: true,
                      ),
                    ],
                  ),

                  // Contact
                  _SectionCard(
                    icon: Icons.phone_outlined,
                    title: 'Contact',
                    children: [
                      _InfoRow(
                        label: 'WhatsApp Number',
                        value: profile?.whatsappNo,
                        icon: Icons.phone_outlined,
                      ),
                      _InfoRow(
                        label: 'Other Contact',
                        value: profile?.otherContactNo,
                        icon: Icons.phone_callback_outlined,
                      ),
                      _InfoRow(
                        label: 'Email',
                        value: (profile?.email.isNotEmpty == true)
                            ? profile!.email
                            : (authEmail.isNotEmpty ? authEmail : null),
                        icon: Icons.email_outlined,
                        isLast: true,
                      ),
                    ],
                  ),

                  // Drug Licenses
                  _SectionCard(
                    icon: Icons.verified_outlined,
                    title: 'Drug Licenses',
                    children: [
                      _InfoRow(
                        label: 'DL 20B',
                        value: profile?.dl20b,
                        icon: Icons.receipt_long_outlined,
                      ),
                      _InfoRow(
                        label: 'DL 21B',
                        value: profile?.dl21b,
                        icon: Icons.receipt_outlined,
                      ),
                      _InfoRow(
                        label: 'GST Number',
                        value: profile?.gstNo,
                        icon: Icons.account_balance_outlined,
                        isLast: true,
                      ),
                    ],
                  ),

                  // Account Setup
                  _SectionCard(
                    icon: Icons.manage_accounts_outlined,
                    title: 'Account Setup',
                    children: [
                      _InfoRow(
                        label: 'Payment Term',
                        value: profile?.paymentTerm,
                        icon: Icons.payments_outlined,
                      ),
                      _InfoRow(
                        label: 'Customer Code',
                        value: profile?.customerCode,
                        icon: Icons.tag_outlined,
                        isLast: true,
                      ),
                    ],
                  ),
                ],

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

// ── Account status badge ──────────────────────────────────────────────────────

class _AccountStatusBadge extends StatelessWidget {
  final bool isRegistered;
  final bool isApproved;
  final String status;

  const _AccountStatusBadge({
    required this.isRegistered,
    required this.isApproved,
    required this.status,
  });

  @override
  Widget build(BuildContext context) {
    final Color bg;
    final Color fg;
    final IconData icon;
    final String label;

    if (!isRegistered) {
      bg = const Color(0xFFF3F4F6);
      fg = const Color(0xFF6B7280);
      icon = Icons.person_off_outlined;
      label = 'Not Registered';
    } else if (isApproved && status == 'suspended') {
      bg = const Color(0xFFFFE4E6);
      fg = const Color(0xFFDC2626);
      icon = Icons.block;
      label = 'Suspended';
    } else if (isApproved) {
      bg = const Color(0xFFDCFCE7);
      fg = const Color(0xFF15803D);
      icon = Icons.verified_outlined;
      label = 'Approved';
    } else {
      bg = const Color(0xFFFEF3C7);
      fg = const Color(0xFFD97706);
      icon = Icons.access_time;
      label = 'Pending Approval';
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: fg),
          const SizedBox(width: 6),
          Text(
            label,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w700,
              color: fg,
            ),
          ),
        ],
      ),
    );
  }
}

// ── Section card ──────────────────────────────────────────────────────────────

class _SectionCard extends StatelessWidget {
  final IconData icon;
  final String title;
  final List<Widget> children;

  const _SectionCard({
    required this.icon,
    required this.title,
    required this.children,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFFE5E7EB)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
            child: Row(
              children: [
                Icon(icon, size: 14, color: const Color(0xFF1B5E20)),
                const SizedBox(width: 6),
                Text(
                  title,
                  style: const TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                    color: Color(0xFF1B5E20),
                    letterSpacing: 0.4,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 4),
          ...children,
        ],
      ),
    );
  }
}

// ── Info row ──────────────────────────────────────────────────────────────────

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
    final display = (value != null && value!.isNotEmpty) ? value! : '—';

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
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
