import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

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
        const Row(children: [
          Icon(Icons.warning_amber_rounded, size: 16, color: Color(0xFFD97706)),
          SizedBox(width: 6),
          Text('Action Required',
              style: TextStyle(
                  fontSize: 14, fontWeight: FontWeight.w700, color: Color(0xFF374151))),
        ]),
        const SizedBox(height: 10),
        // Wrap instead of horizontal scroll so cards stack on narrow screens
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
              activeColor: const Color(0xFF7C3AED),
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
        const Text('Overview',
            style: TextStyle(
                fontSize: 14, fontWeight: FontWeight.w700, color: Color(0xFF374151))),
        const SizedBox(height: 10),
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
            color: const Color(0xFF1B5E20),
          ),
        ]),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (ctx, box) {
      // Tighter padding on narrow screens so cards don't overflow
      final isNarrow = box.maxWidth < 600;
      final pad = isNarrow ? 16.0 : 28.0;

      return SingleChildScrollView(
        padding: EdgeInsets.all(pad),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Dashboard header
            Row(children: [
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  color: const Color(0xFFECFDF5),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: const Icon(Icons.dashboard_outlined,
                    size: 22, color: Color(0xFF1B5E20)),
              ),
              const SizedBox(width: 14),
              const Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Dashboard',
                        style: TextStyle(
                            fontSize: 22,
                            fontWeight: FontWeight.w800,
                            color: Color(0xFF111827))),
                    SizedBox(height: 2),
                    Text('mediBO admin panel',
                        style: TextStyle(fontSize: 13, color: Color(0xFF6B7280))),
                  ],
                ),
              ),
            ]),
            const SizedBox(height: 24),

            if (_loading)
              const Center(
                child: Padding(
                  padding: EdgeInsets.all(32),
                  child: CircularProgressIndicator(
                      color: Color(0xFF1B5E20), strokeWidth: 2.5),
                ),
              )
            else
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  _buildActionRequired(),
                  const SizedBox(height: 28),
                  _buildOverview(),
                  const SizedBox(height: 32),
                  const Text('Sections',
                      style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w700,
                          color: Color(0xFF374151))),
                  const SizedBox(height: 12),
                  Wrap(spacing: 12, runSpacing: 12, children: const [
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
      borderRadius: BorderRadius.circular(10),
      child: Container(
        // 156px wide — 2 fit per row at ≥340px content width (with 12px gap)
        width: 156,
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        decoration: BoxDecoration(
          color: isActive ? activeColor.withValues(alpha: 0.05) : Colors.white,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: isActive
                ? activeColor.withValues(alpha: 0.35)
                : const Color(0xFFE5E7EB),
          ),
        ),
        child: Row(children: [
          Container(
            width: 34,
            height: 34,
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Icon(icon, size: 17, color: color),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  '$count',
                  style: TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.w800,
                    color: isActive ? activeColor : const Color(0xFF374151),
                  ),
                ),
                Text(
                  label,
                  style: const TextStyle(fontSize: 11, color: Color(0xFF6B7280)),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
        ]),
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
      width: 170,
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFFE5E7EB)),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Container(
          width: 40,
          height: 40,
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.1),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Icon(icon, size: 22, color: color),
        ),
        const SizedBox(height: 14),
        Text(value,
            style: const TextStyle(
                fontSize: 28, fontWeight: FontWeight.w800, color: Color(0xFF111827))),
        const SizedBox(height: 4),
        Text(label,
            style: const TextStyle(fontSize: 12, color: Color(0xFF6B7280))),
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
        width: 130,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: const Color(0xFFE5E7EB)),
        ),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Icon(icon, size: 24, color: const Color(0xFF1B5E20)),
          const SizedBox(height: 8),
          Text(label,
              textAlign: TextAlign.center,
              style: const TextStyle(
                  fontSize: 12,
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




