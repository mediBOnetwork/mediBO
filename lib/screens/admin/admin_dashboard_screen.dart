import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:pharma_b2b/utils/render_log.dart';

class AdminDashboardScreen extends StatefulWidget {
  const AdminDashboardScreen({super.key});

  @override
  State<AdminDashboardScreen> createState() => _AdminDashboardScreenState();
}

class _AdminDashboardScreenState extends State<AdminDashboardScreen> {
  int _pendingBills = 0;
  int _totalMedicines = 0;
  int _billsNeedingReview = 0;
  int _pendingOrders = 0;
  int _inquiries = 0;
  int _pendingRegistrations = 0;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _loadStats();
  }

  Future<void> _loadStats() async {
    try {
      final results = await Future.wait<int>([
        Supabase.instance.client.from('MEDICINE').count(),
        Supabase.instance.client
            .from('pending_bills')
            .count()
            .eq('status', 'pending'),
        Supabase.instance.client
            .from('pending_bills')
            .count()
            .inFilter('verdict', ['needs_approval', 'fake']),
        Supabase.instance.client
            .from('orders')
            .count()
            .eq('status', 'pending'),
        Supabase.instance.client.from('contact_inquiries').count(),
        Supabase.instance.client
            .from('pharmacy_profiles')
            .count()
            .or('approved.is.null,approved.eq.false'),
      ]);
      if (mounted) {
        setState(() {
          _totalMedicines       = results[0];
          _pendingBills         = results[1];
          _billsNeedingReview   = results[2];
          _pendingOrders        = results[3];
          _inquiries            = results[4];
          _pendingRegistrations = results[5];
          _loading = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  Widget _buildActionRequired() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Wrap(
          spacing: 12,
          runSpacing: 12,
          children: [
            _ActionCard(
              label: 'Bills to Review',
              count: _billsNeedingReview,
              icon: Icons.assignment_late_outlined,
              activeColor: const Color(0xFFDC2626),
              route: 'bills',
            ),
            _ActionCard(
              label: 'Pending Orders',
              count: _pendingOrders,
              icon: Icons.receipt_long_outlined,
              activeColor: const Color(0xFFD97706),
              route: 'orders',
            ),
            _ActionCard(
              label: 'Inquiries',
              count: _inquiries,
              icon: Icons.help_outline,
              activeColor: const Color(0xFF2563EB),
              route: 'inquiry',
            ),
            _ActionCard(
              label: 'Pending Sign-ups',
              count: _pendingRegistrations,
              icon: Icons.person_add_outlined,
              activeColor: const Color(0xFF1B7A43),
              route: 'customers',
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildOverview() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Wrap(spacing: 16, runSpacing: 16, children: [
          _StatCard(
            label: 'Pending Bills',
            value: '$_pendingBills',
            icon: Icons.inbox_outlined,
            color: _pendingBills > 0 ? const Color(0xFFDC2626) : const Color(0xFF6B7280),
          ),
          _StatCard(
            label: 'Medicines',
            value: '$_totalMedicines',
            icon: Icons.medication_outlined,
            color: const Color(0xFF1B7A43),
          ),
        ]),
      ],
    );
  }

  static Widget _sectionLabel(String text) => Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: Text(
          text.toUpperCase(),
          style: const TextStyle(
            fontSize: 10,
            fontWeight: FontWeight.w700,
            color: Color(0xFF9CA3AF),
            letterSpacing: 1.0,
          ),
        ),
      );

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (ctx, box) {
      final isNarrow = box.maxWidth < 600;
      final hpad = isNarrow ? 16.0 : 28.0;

      return SingleChildScrollView(
        padding: EdgeInsets.fromLTRB(hpad, 24, hpad, 32),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Builder(builder: (_) {
              RenderLog.write('titles_removed_dashboard', 'true');
              return const SizedBox(height: 8);
            }),

            if (_loading)
              const Center(
                child: Padding(
                  padding: EdgeInsets.all(32),
                  child: CircularProgressIndicator(
                      color: Color(0xFF1B7A43), strokeWidth: 2.5),
                ),
              )
            else
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  _sectionLabel('Action Required'),
                  _buildActionRequired(),
                  const SizedBox(height: 28),
                  _sectionLabel('Overview'),
                  _buildOverview(),
                  const SizedBox(height: 28),
                  _sectionLabel('Quick Navigation'),
                  Wrap(spacing: 10, runSpacing: 10, children: const [
                    _QuickTile(
                        label: 'Add Medicine',
                        icon: Icons.medication_outlined,
                        route: 'add_medicine'),
                    _QuickTile(
                        label: 'Orders',
                        icon: Icons.receipt_long_outlined,
                        route: 'orders'),
                    _QuickTile(
                        label: 'Inquiry',
                        icon: Icons.help_outline,
                        route: 'inquiry'),
                    _QuickTile(
                        label: 'Suppliers',
                        icon: Icons.inventory_2_outlined,
                        route: 'suppliers'),
                    _QuickTile(
                        label: 'Customers',
                        icon: Icons.people_outline,
                        route: 'customers'),
                    _QuickTile(
                        label: 'Bills',
                        icon: Icons.inbox_outlined,
                        route: 'bills'),
                  ]),
                ],
              ),
          ],
        ),
      );
    });
  }
}

// ── Action-required card ──────────────────────────────────────────────────────

class _ActionCard extends StatelessWidget {
  final String label;
  final int count;
  final IconData icon;
  final Color activeColor;
  final String route;

  const _ActionCard({
    required this.label,
    required this.count,
    required this.icon,
    required this.activeColor,
    required this.route,
  });

  @override
  Widget build(BuildContext context) {
    final isActive = count > 0;
    final color = isActive ? activeColor : const Color(0xFF9CA3AF);
    return InkWell(
      onTap: () => QuickLinkNavigator.of(context)?.navigate(route),
      borderRadius: BorderRadius.circular(12),
      child: Container(
        width: 172,
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(12),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.06),
              blurRadius: 8,
              offset: const Offset(0, 2),
            ),
          ],
          border: isActive
              ? Border.all(color: activeColor.withValues(alpha: 0.18), width: 1)
              : Border.all(color: const Color(0xFFF3F4F6)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(
                color: color.withValues(alpha: 0.10),
                borderRadius: BorderRadius.circular(9),
              ),
              child: Icon(icon, size: 18, color: color),
            ),
            const SizedBox(height: 12),
            Text(
              '$count',
              style: TextStyle(
                fontSize: 26,
                fontWeight: FontWeight.w800,
                color: isActive ? activeColor : const Color(0xFF374151),
              ),
            ),
            const SizedBox(height: 2),
            Text(
              label,
              style: const TextStyle(fontSize: 12, color: Color(0xFF6B7280)),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ),
      ),
    );
  }
}

// ── Stat card ─────────────────────────────────────────────────────────────────

class _StatCard extends StatelessWidget {
  final String label;
  final String value;
  final IconData icon;
  final Color color;

  const _StatCard({
    required this.label,
    required this.value,
    required this.icon,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 200,
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFFF3F4F6)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.06),
            blurRadius: 8,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Row(children: [
        Container(
          width: 44,
          height: 44,
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.10),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Icon(icon, size: 22, color: color),
        ),
        const SizedBox(width: 14),
        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(value,
              style: const TextStyle(
                  fontSize: 26, fontWeight: FontWeight.w800, color: Color(0xFF111827))),
          const SizedBox(height: 2),
          Text(label,
              style: const TextStyle(fontSize: 12, color: Color(0xFF6B7280))),
        ])),
      ]),
    );
  }
}

// ── Quick-action tile ─────────────────────────────────────────────────────────

class _QuickTile extends StatelessWidget {
  final String label;
  final IconData icon;
  final String route;

  const _QuickTile({
    required this.label,
    required this.icon,
    required this.route,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: () => QuickLinkNavigator.of(context)?.navigate(route),
      borderRadius: BorderRadius.circular(10),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: const Color(0xFFE5E7EB)),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.04),
              blurRadius: 6,
              offset: const Offset(0, 1),
            ),
          ],
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Container(
            width: 32,
            height: 32,
            decoration: BoxDecoration(
              color: const Color(0xFFECFDF5),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Icon(icon, size: 17, color: const Color(0xFF1B7A43)),
          ),
          const SizedBox(width: 10),
          Text(label,
              style: const TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: Color(0xFF374151))),
        ]),
      ),
    );
  }
}

// ── Inherited widget — tiles/cards trigger navigation in AdminShell ────────────

class QuickLinkNavigator extends InheritedWidget {
  final void Function(String route) navigate;

  const QuickLinkNavigator({
    super.key,
    required this.navigate,
    required super.child,
  });

  static QuickLinkNavigator? of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<QuickLinkNavigator>();

  @override
  bool updateShouldNotify(QuickLinkNavigator old) => false;
}




