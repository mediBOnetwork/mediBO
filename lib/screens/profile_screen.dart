import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../models/account_registration.dart';
import '../models/app_session.dart';
import '../models/user_profile.dart';
import '../user_state.dart';
import '../utils/render_log.dart';
import '../view_as_state.dart';
import 'auth/business_details_screen.dart';
import 'admin/view_as_picker_dialog.dart';

class ProfileScreen extends StatefulWidget {
  // CHANGE #374 — when set (View As Customer), load the impersonated
  // customer's pharmacy_profiles by their auth USER ID (pharmacy_profiles.
  // user_id), not the pharmacy_profiles row id. Root cause of a false "Not
  // Registered" screen: some ViewAs-activation call sites (the Leads
  // Convert-to-Order flow) only had the user id on hand and were passing it
  // in as if it were the pharmacy row id, so the old `.eq('id', ...)` lookup
  // matched nothing. Keying on user_id here works regardless of that.
  final String? viewAsUserId;
  const ProfileScreen({super.key, this.viewAsUserId});

  @override
  State<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends State<ProfileScreen> {
  Map<String, dynamic>? _viewAsProfileRow;
  bool _viewAsLoading = false;

  // CHANGE #569 / RULE 1 — the signed-in account comes from my_session() and
  // from nothing else. The old path asked UserState, which resolves the
  // profile with `pharmacy_profiles.eq('user_id', auth.uid())`. That join is
  // not the account's identity: a profile whose user_id is null or points at a
  // stale auth user resolves to no row, and the screen then claimed "Not
  // Registered" for a fully registered, approved customer. my_session()
  // resolves through login_identities (email/phone), so it is right whatever
  // state the user_id column happens to be in.
  AppSession? _session;

  /// The account's own pharmacy_profiles row, fetched by PRIMARY KEY using the
  /// owner_id my_session() returned — never by user_id. RLS allows this via
  /// `own_profile_select: (id = my_customer_id() OR user_id = auth.uid())`,
  /// and the first arm resolves the same way my_session() does.
  Map<String, dynamic>? _ownProfileRow;
  bool _selfLoading = false;
  bool _selfError = false;

  @override
  void initState() {
    super.initState();
    if (widget.viewAsUserId != null) {
      _fetchViewAsProfile();
    } else {
      _loadSession();
    }
  }

  /// RULE 1 — role, display_name and owner_id all come from this one call.
  Future<void> _loadSession() async {
    setState(() { _selfLoading = true; _selfError = false; });
    try {
      final client = Supabase.instance.client;
      final raw = await client.rpc('my_session');
      final session =
          AppSession.fromJson(Map<String, dynamic>.from(raw as Map));

      // Hydrate the detail fields only once the session says this account IS a
      // customer and names it. No owner_id means there is nothing to load —
      // that is the genuine unregistered case, not a failed lookup.
      Map<String, dynamic>? row;
      if (isRegisteredCustomer(session)) {
        final raw = await client.rpc('my_profile_row');
        final m = (raw is List ? raw.first : raw) as Map;
        row = m['found'] == true
            ? Map<String, dynamic>.from(m['row'] as Map)
            : null;
      }

      if (!mounted) return;
      setState(() {
        _session = session;
        _ownProfileRow = row;
        _selfLoading = false;
      });
    } catch (_) {
      // A transport/RPC failure is "we don't know", not "unregistered" — the
      // retry card renders instead of the registration form (#402).
      if (!mounted) return;
      setState(() { _selfError = true; _selfLoading = false; });
    }
  }

  Future<void> _fetchViewAsProfile() async {
    setState(() => _viewAsLoading = true);
    try {
      final raw = await Supabase.instance.client
          .rpc('admin_customer_profile_by_user',
               params: {'p_user_id': widget.viewAsUserId!});
      final m = (raw is List ? raw.first : raw) as Map;
      if (mounted) {
        setState(() {
          _viewAsProfileRow = m['found'] == true
              ? Map<String, dynamic>.from(m['row'] as Map)
              : null;
          _viewAsLoading = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _viewAsLoading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final isViewAs = widget.viewAsUserId != null;

    // In View As mode: use the fetched row; otherwise use the my_session()
    // account resolved in [_loadSession]. UserState is deliberately NOT read
    // here — its user_id-keyed profile is the path that produced the false
    // "Not Registered" (CHANGE #569 / RULE 1).
    final authUser = Supabase.instance.client.auth.currentUser;
    final session = _session;

    // Build a synthetic UserProfile-like read from the fetched row when viewing as customer.
    final profile = isViewAs
        ? (_viewAsProfileRow != null ? UserProfile.fromJson(_viewAsProfileRow!) : null)
        : (_ownProfileRow != null ? UserProfile.fromJson(_ownProfileRow!) : null);
    final authEmail = isViewAs
        ? (_viewAsProfileRow?['email'] as String? ?? '')
        : (session?.loginEmail ?? '');

    // RULE 1 — registration is role + owner_id from my_session(), nothing else.
    // owner_id is empty for a signed-in visitor with no customer account, which
    // is exactly the "needs to register" case.
    final isRegistered =
        isViewAs ? (profile != null) : isRegisteredCustomer(session);

    // The header name is the backend's display_name; the profile row is only a
    // fallback for the brief window before the row lands.
    final headerName = isViewAs
        ? (profile?.displayName ?? 'My Account')
        : ((session?.displayName.isNotEmpty ?? false)
            ? session!.displayName
            : (profile?.displayName ?? 'My Account'));

    // #402: while the fetch is still in flight, wait for it instead of judging
    // isRegistered on a not-yet-loaded session (which would flash the
    // "Registration required" form for a real user).
    final selfUnresolved = _selfLoading || (session == null && !_selfError);
    if ((isViewAs && _viewAsLoading) || (!isViewAs && selfUnresolved)) {
      return const Scaffold(
        backgroundColor: Color(0xFFF9FAFB),
        body: Center(child: CircularProgressIndicator(color: Color(0xFF1B7A43))),
      );
    }

    // #402: a genuine fetch error (not just "no row") for a profile we've
    // never successfully loaded — show a retry option, not a false
    // "please register" screen.
    final fetchErrorUnknown = !isViewAs && _selfError && session == null;

    if (fetchErrorUnknown) {
      RenderLog.write('c402_profile_fetch_err', 'true');
    } else if (isRegistered) {
      RenderLog.write('c402_profile_loaded_existing', 'true');
    } else {
      RenderLog.write('c402_profile_loaded_empty', 'true');
    }

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
                        headerName,
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

                // #402: fetch failed and we don't know the real state yet —
                // offer retry instead of assuming unregistered.
                if (fetchErrorUnknown) ...[
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
                    child: Container(
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        color: const Color(0xFFFFF7ED),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: const Color(0xFFFDBA74)),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          const Row(
                            children: [
                              Icon(Icons.wifi_off,
                                  size: 18, color: Color(0xFFC2410C)),
                              SizedBox(width: 8),
                              Expanded(
                                child: Text(
                                  "Couldn't load your profile. Check your connection and try again.",
                                  style: TextStyle(
                                    fontSize: 13,
                                    fontWeight: FontWeight.w600,
                                    color: Color(0xFFC2410C),
                                  ),
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 10),
                          SizedBox(
                            height: 44,
                            child: OutlinedButton(
                              onPressed: _loadSession,
                              style: OutlinedButton.styleFrom(
                                foregroundColor: const Color(0xFFC2410C),
                                side: const BorderSide(color: Color(0xFFFDBA74)),
                                shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(8)),
                              ),
                              child: const Text('Retry',
                                  style: TextStyle(
                                      fontWeight: FontWeight.w700, fontSize: 14)),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],

                // Unregistered: complete registration CTA
                if (!isRegistered && !fetchErrorUnknown) ...[
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

                // View As (Dev) — super-admin only, build-phase gated; hidden in viewAs mode
                // RULE 1 — the role gating this comes from my_session() too.
                if (!isViewAs && kEnableViewAs && (session?.isSuperAdmin ?? false))
                  _ViewAsCard(),

                // Logout button — hidden when viewing as another customer
                if (!isViewAs)
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

// ── View As card (super-admin dev tool) ───────────────────────────────────────

class _ViewAsCard extends StatelessWidget {
  const _ViewAsCard();

  static const _amber = Color(0xFFD97706);
  static const _amberBg = Color(0xFFFFFBEB);
  static const _amberBorder = Color(0xFFFCD34D);

  Future<void> _pick(BuildContext context, ViewAsRole role) async {
    final identity = await showViewAsPicker(context, role);
    if (identity == null || !context.mounted) return;
    // Warn: writes are now LIVE
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Row(children: [
          const Icon(Icons.warning_amber_rounded, color: Color(0xFFD97706), size: 22),
          const SizedBox(width: 8),
          Expanded(child: Text('Act as ${identity.name}?',
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700))),
        ]),
        content: Text(
          'Any changes (cart, orders, profile) will be SAVED to '
          '${identity.name}\'s real account.\n\nThis cannot be undone.',
          style: const TextStyle(fontSize: 14),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: FilledButton.styleFrom(backgroundColor: const Color(0xFFD97706)),
            child: const Text('Continue — I understand'),
          ),
        ],
      ),
    );
    if (confirmed != true || !context.mounted) return;
    ViewAsState.read(context).activate(role, identity);
    // Close profile screen — home_shell will re-route to preview
    Navigator.of(context).popUntil((r) => r.isFirst);
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 20, 16, 0),
      decoration: BoxDecoration(
        color: _amberBg,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: _amberBorder),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
            child: Row(
              children: const [
                Icon(Icons.preview_outlined, size: 16, color: _amber),
                SizedBox(width: 6),
                Text(
                  'VIEW AS (Dev)',
                  style: TextStyle(
                    fontSize: 11, fontWeight: FontWeight.w700,
                    color: _amber, letterSpacing: 0.4,
                  ),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
            child: Text(
              'Preview any account\'s interface without logging out.',
              style: TextStyle(fontSize: 12, color: Color(0xFF92400E)),
            ),
          ),
          const Divider(color: _amberBorder, height: 1),
          Padding(
            padding: const EdgeInsets.all(12),
            child: Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                _ViewAsChip(label: 'Customer',         icon: Icons.person_outline,          onTap: () => _pick(context, ViewAsRole.customer)),
                _ViewAsChip(label: 'Supplier',         icon: Icons.store_outlined,           onTap: () => _pick(context, ViewAsRole.supplier)),
                _ViewAsChip(label: 'Company',          icon: Icons.business_outlined,        onTap: () => _pick(context, ViewAsRole.company)),
                _ViewAsChip(label: 'Delivery Partner', icon: Icons.delivery_dining_outlined, onTap: () => _pick(context, ViewAsRole.deliveryPartner)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _ViewAsChip extends StatelessWidget {
  final String label;
  final IconData icon;
  final VoidCallback onTap;
  const _ViewAsChip({required this.label, required this.icon, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: const Color(0xFFFCD34D)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 15, color: const Color(0xFFD97706)),
            const SizedBox(width: 6),
            Text(label, style: const TextStyle(
              fontSize: 13, fontWeight: FontWeight.w600, color: Color(0xFF92400E),
            )),
          ],
        ),
      ),
    );
  }
}
