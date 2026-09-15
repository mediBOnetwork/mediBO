part of '../home_shell.dart';

// CHANGE #327 · LAYER 1 — sharded out of home_shell.dart.
//
// The page-swap animation and the whole view-as surface: the banner and the customer / company / delivery-partner previews.
//
// It is a `part`, not a new library, on purpose: nearly every widget in
// the shell is library-private and used by the others, so extracting them
// into real libraries would force ~40 classes public and rewrite every
// reference. A part shares the library's imports and its privacy scope, so
// this is a pure move — and it gives this concern its own leasable path, so
// a cart command and a login command stop fighting over one file.
class _FadingIndexedStack extends StatefulWidget {
  final int index;
  final List<Widget> children;
  const _FadingIndexedStack({required this.index, required this.children});

  @override
  State<_FadingIndexedStack> createState() => _FadingIndexedStackState();
}

class _FadingIndexedStackState extends State<_FadingIndexedStack>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;
  late final Animation<double> _fade;
  late int _index;

  @override
  void initState() {
    super.initState();
    _index = widget.index;
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 220),
    );
    _fade = CurvedAnimation(parent: _ctrl, curve: Curves.easeInOut);
    _ctrl.value = 1.0;
  }

  @override
  void didUpdateWidget(_FadingIndexedStack old) {
    super.didUpdateWidget(old);
    if (widget.index != old.index) {
      _ctrl.reverse().then((_) {
        if (mounted) {
          setState(() => _index = widget.index);
          _ctrl.forward();
        }
      });
    }
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: _fade,
      child: IndexedStack(index: _index, children: widget.children),
    );
  }
}



// ── View As banner ────────────────────────────────────────────────────────────

class _ViewAsBanner extends StatelessWidget {
  final ViewAsRole role;
  final ViewAsIdentity identity;
  final VoidCallback onExit;
  const _ViewAsBanner({required this.role, required this.identity, required this.onExit});

  String get _roleLabel {
    switch (role) {
      case ViewAsRole.supplier:        return 'Supplier';
      case ViewAsRole.customer:        return 'Customer';
      case ViewAsRole.company:         return 'Company';
      case ViewAsRole.deliveryPartner: return 'Delivery Partner';
    }
  }

  @override
  Widget build(BuildContext context) {
    return Material(
      color: const Color(0xFFFEF2F2), // light red — writes are LIVE
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        decoration: const BoxDecoration(
          border: Border(bottom: BorderSide(color: Color(0xFFFCA5A5))),
        ),
        child: Row(
          children: [
            const Icon(Icons.warning_amber_rounded, size: 16, color: Color(0xFFDC2626)),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                cf('home_shell.acting_as_banner', {'a': _roleLabel, 'b': identity.name}),
                style: const TextStyle(
                  fontSize: 13, fontWeight: FontWeight.w600, color: Color(0xFF991B1B),
                ),
                overflow: TextOverflow.ellipsis,
              ),
            ),
            TextButton(
              onPressed: onExit,
              style: TextButton.styleFrom(
                foregroundColor: const Color(0xFFDC2626),
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                minimumSize: Size.zero,
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              child: Text(c('home_shell.exit'), style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700)),
            ),
          ],
        ),
      ),
    );
  }
}

// ── View As preview screens ───────────────────────────────────────────────────

class _ViewAsCustomerPreview extends StatefulWidget {
  final ViewAsIdentity identity;
  const _ViewAsCustomerPreview({required this.identity});

  @override
  State<_ViewAsCustomerPreview> createState() => _ViewAsCustomerPreviewState();
}

class _ViewAsCustomerPreviewState extends State<_ViewAsCustomerPreview> {
  Map<String, dynamic>? _profile;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _fetch();
  }

  Future<void> _fetch() async {
    try {
      final res = await Supabase.instance.client
          .rpc('viewas_identity_profile',
               params: {'p_kind': 'customer', 'p_id': widget.identity.id});
      final m = (res is List ? res.first : res) as Map;
      if (mounted) {
        setState(() {
          _profile = m['found'] == true
              ? Map<String, dynamic>.from(m['row'] as Map)
              : null;
          _loading = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return const Center(child: CircularProgressIndicator(color: Color(0xFF1B7A43)));
    final p = _profile;
    return SingleChildScrollView(
      padding: const EdgeInsets.all(20),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 520),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            _previewHeader('Customer Profile', Icons.person_outline, const Color(0xFF1B7A43)),
            const SizedBox(height: 16),
            _previewField('Name', p?['customer_name'] ?? p?['owner_name']),
            _previewField('Pharmacy', p?['pharmacy_name']),
            _previewField('Email', p?['email'] ?? widget.identity.email),
            _previewField('Phone', p?['phone']),
            _previewField('City', p?['city']),
            _previewField('State', p?['state']),
            _previewField('Pincode', p?['pincode']),
            _previewField('Status', p?['status']),
            _previewField('Customer Code', p?['customer_code']),
            _previewField('Drug License', p?['drug_license']),
            _previewField('GST', p?['gst_no'] ?? p?['gstin']),
          ]),
        ),
      ),
    );
  }
}

class _ViewAsCompanyPreview extends StatefulWidget {
  final ViewAsIdentity identity;
  const _ViewAsCompanyPreview({super.key, required this.identity});

  @override
  State<_ViewAsCompanyPreview> createState() => _ViewAsCompanyPreviewState();
}

class _ViewAsCompanyPreviewState extends State<_ViewAsCompanyPreview> {
  Map<String, dynamic>? _profile;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _fetch();
  }

  Future<void> _fetch() async {
    try {
      final res = await Supabase.instance.client
          .rpc('viewas_identity_profile',
               params: {'p_kind': 'company', 'p_id': widget.identity.id});
      final m = (res is List ? res.first : res) as Map;
      if (mounted) {
        setState(() {
          _profile = m['found'] == true
              ? Map<String, dynamic>.from(m['row'] as Map)
              : null;
          _loading = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return const Center(child: CircularProgressIndicator(color: Color(0xFF1B7A43)));
    final p = _profile;
    return SingleChildScrollView(
      padding: const EdgeInsets.all(20),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 520),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            _previewHeader('Company Profile', Icons.business_outlined, const Color(0xFF1B7A43)),
            const SizedBox(height: 16),
            _previewField('Company Name', p?['company_name'] ?? widget.identity.name),
            _previewField('Contact Person', p?['contact_person']),
            _previewField('Email', p?['email'] ?? widget.identity.email),
            _previewField('Phone', p?['phone']),
            _previewField('City', p?['city']),
            _previewField('State', p?['state']),
            _previewField('Status', p?['status']),
            _previewField('Drug License', p?['drug_license']),
            _previewField('GST', p?['gst_no']),
            _previewField('Website', p?['website']),
            _previewField('Product Categories', p?['product_categories']),
          ]),
        ),
      ),
    );
  }
}

class _ViewAsDeliveryPartnerPreview extends StatefulWidget {
  final ViewAsIdentity identity;
  const _ViewAsDeliveryPartnerPreview({super.key, required this.identity});

  @override
  State<_ViewAsDeliveryPartnerPreview> createState() => _ViewAsDeliveryPartnerPreviewState();
}

class _ViewAsDeliveryPartnerPreviewState extends State<_ViewAsDeliveryPartnerPreview> {
  Map<String, dynamic>? _profile;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _fetch();
  }

  Future<void> _fetch() async {
    try {
      final res = await Supabase.instance.client
          .rpc('viewas_identity_profile',
               params: {'p_kind': 'delivery_partner', 'p_id': widget.identity.id});
      final m = (res is List ? res.first : res) as Map;
      if (mounted) {
        setState(() {
          _profile = m['found'] == true
              ? Map<String, dynamic>.from(m['row'] as Map)
              : null;
          _loading = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return const Center(child: CircularProgressIndicator(color: Color(0xFF1B7A43)));
    final p = _profile;
    return SingleChildScrollView(
      padding: const EdgeInsets.all(20),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 520),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            _previewHeader('Delivery Partner Profile', Icons.delivery_dining_outlined, const Color(0xFF1B7A43)),
            const SizedBox(height: 16),
            _previewField('Full Name', p?['full_name'] ?? widget.identity.name),
            _previewField('Email', p?['email'] ?? widget.identity.email),
            _previewField('Phone', p?['phone']),
            _previewField('City', p?['city']),
            _previewField('State', p?['state']),
            _previewField('Delivery Zone', p?['delivery_zone']),
            _previewField('Vehicle Type', p?['vehicle_type']),
            _previewField('Status', p?['status']),
          ]),
        ),
      ),
    );
  }
}

Widget _previewHeader(String title, IconData icon, Color color) {
  return Row(children: [
    Icon(icon, size: 20, color: color),
    const SizedBox(width: 8),
    Text(title, style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700, color: color)),
  ]);
}

Widget _previewField(String label, dynamic value) {
  final v = value?.toString() ?? '';
  if (v.isEmpty) return const SizedBox.shrink();
  return Padding(
    padding: const EdgeInsets.only(bottom: 12),
    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(label, style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w500, color: Color(0xFF9CA3AF))),
      const SizedBox(height: 2),
      Text(v, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: Color(0xFF111827))),
    ]),
  );
}
