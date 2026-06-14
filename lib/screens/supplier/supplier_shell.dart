// ignore_for_file: avoid_web_libraries_in_flutter
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../user_state.dart';
import '../../utils/render_log.dart';
import '../../utils/toast.dart';
import 'supplier_home_screen.dart';
import 'supplier_inquiry_screen.dart';
import 'supplier_orders_screen.dart';
import 'supplier_add_medicine_screen.dart';

class SupplierShell extends StatefulWidget {
  const SupplierShell({super.key});

  @override
  State<SupplierShell> createState() => _SupplierShellState();
}

class _SupplierShellState extends State<SupplierShell> {
  int _index = 0;
  int _pendingInquiryCount = 0;
  Timer? _pollTimer;
  bool _bannerDismissed = false;

  // Keys to allow deep-linking into child screens
  final GlobalKey<SupplierInquiryScreenState> _inquiryKey = GlobalKey();

  final List<_NavItem> _navItems = const [
    _NavItem(icon: Icons.store_outlined,       label: 'Home'),
    _NavItem(icon: Icons.add_circle_outline,   label: 'Add Medicine'),
    _NavItem(icon: Icons.question_answer_outlined, label: 'Inquiry'),
    _NavItem(icon: Icons.receipt_long_outlined, label: 'Orders'),
  ];

  @override
  void initState() {
    super.initState();
    RenderLog.write('supplier_shell', 'init');
    _startPolling();
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    super.dispose();
  }

  void _startPolling() {
    _fetchPendingCount();
    _pollTimer = Timer.periodic(const Duration(seconds: 30), (_) => _fetchPendingCount());
  }

  Future<void> _fetchPendingCount() async {
    try {
      final res = await Supabase.instance.client
          .rpc('supplier_pending_inquiry_count') as int?;
      if (mounted) {
        final count = res ?? 0;
        if (count != _pendingInquiryCount) {
          setState(() {
            _pendingInquiryCount = count;
            if (count > 0) _bannerDismissed = false;
          });
        }
      }
    } catch (_) {}
  }

  void _goToInquiry() {
    setState(() { _index = 2; _bannerDismissed = false; });
  }

  @override
  Widget build(BuildContext context) {
    final supplierName = UserState.of(context).supplierName ?? 'Supplier';
    final isDesktop = MediaQuery.of(context).size.width >= 900;

    final pages = [
      const SupplierHomeScreen(),
      const SupplierAddMedicineScreen(),
      SupplierInquiryScreen(key: _inquiryKey),
      const SupplierOrdersScreen(),
    ];

    final showBanner = _pendingInquiryCount > 0 && !_bannerDismissed && _index != 2;

    return Scaffold(
      backgroundColor: const Color(0xFFF5F6F8),
      body: Column(children: [
        _SupplierHeader(
          supplierName: supplierName,
          isDesktop: isDesktop,
          onLogout: () => UserState.read(context).signOut(),
        ),
        // Attention banner
        if (showBanner)
          _InquiryBanner(
            count: _pendingInquiryCount,
            onTap: _goToInquiry,
            onDismiss: () => setState(() => _bannerDismissed = true),
          ),
        if (isDesktop)
          _DesktopTabBar(
            index: _index,
            items: _navItems,
            onTap: (i) => setState(() => _index = i),
          ),
        Expanded(
          child: IndexedStack(index: _index, children: pages),
        ),
      ]),
      bottomNavigationBar: isDesktop ? null : _MobileBottomNav(
        index: _index,
        items: _navItems,
        pendingInquiry: _pendingInquiryCount,
        onTap: (i) => setState(() => _index = i),
      ),
    );
  }
}

class _NavItem {
  final IconData icon;
  final String label;
  const _NavItem({required this.icon, required this.label});
}

// ── Header ────────────────────────────────────────────────────────────────────

class _SupplierHeader extends StatelessWidget {
  final String supplierName;
  final bool isDesktop;
  final VoidCallback onLogout;

  const _SupplierHeader({
    required this.supplierName,
    required this.isDesktop,
    required this.onLogout,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 56,
      padding: EdgeInsets.symmetric(horizontal: isDesktop ? 24 : 16),
      decoration: const BoxDecoration(
        color: Color(0xFF1B7A43),
        boxShadow: [BoxShadow(color: Color(0x20000000), blurRadius: 4, offset: Offset(0, 2))],
      ),
      child: Row(children: [
        const Text('mediBO', style: TextStyle(
          color: Colors.white, fontSize: 20, fontWeight: FontWeight.w700,
          letterSpacing: -0.5,
        )),
        const SizedBox(width: 8),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
          decoration: BoxDecoration(
            color: Colors.white.withOpacity(0.2),
            borderRadius: BorderRadius.circular(12),
          ),
          child: const Text('Supplier', style: TextStyle(
            color: Colors.white, fontSize: 11, fontWeight: FontWeight.w500,
          )),
        ),
        const Spacer(),
        Text('Hello, $supplierName',
          style: const TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.w500),
          overflow: TextOverflow.ellipsis,
        ),
        const SizedBox(width: 12),
        InkWell(
          onTap: onLogout,
          borderRadius: BorderRadius.circular(8),
          child: const Padding(
            padding: EdgeInsets.all(6),
            child: Icon(Icons.logout, color: Colors.white, size: 20),
          ),
        ),
      ]),
    );
  }
}

// ── Inquiry attention banner ──────────────────────────────────────────────────

class _InquiryBanner extends StatelessWidget {
  final int count;
  final VoidCallback onTap;
  final VoidCallback onDismiss;

  const _InquiryBanner({required this.count, required this.onTap, required this.onDismiss});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        color: const Color(0xFFFEF3C7),
        child: Row(children: [
          const Icon(Icons.notifications_active, color: Color(0xFF92400E), size: 18),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              'You have $count item${count == 1 ? '' : 's'} awaiting your response. Tap to answer.',
              style: const TextStyle(
                fontSize: 13, color: Color(0xFF92400E), fontWeight: FontWeight.w500,
              ),
            ),
          ),
          GestureDetector(
            onTap: onDismiss,
            child: const Icon(Icons.close, color: Color(0xFF92400E), size: 18),
          ),
        ]),
      ),
    );
  }
}

// ── Desktop tab bar ───────────────────────────────────────────────────────────

class _DesktopTabBar extends StatelessWidget {
  final int index;
  final List<_NavItem> items;
  final ValueChanged<int> onTap;

  const _DesktopTabBar({required this.index, required this.items, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Container(
      color: Colors.white,
      padding: const EdgeInsets.symmetric(horizontal: 24),
      child: Row(
        children: List.generate(items.length, (i) {
          final item = items[i];
          final selected = i == index;
          return InkWell(
            onTap: () => onTap(i),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
              decoration: BoxDecoration(
                border: Border(bottom: BorderSide(
                  color: selected ? const Color(0xFF1B7A43) : Colors.transparent,
                  width: 2,
                )),
              ),
              child: Row(children: [
                Icon(item.icon,
                  size: 18,
                  color: selected ? const Color(0xFF1B7A43) : const Color(0xFF6B7280),
                ),
                const SizedBox(width: 6),
                Text(item.label,
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                    color: selected ? const Color(0xFF1B7A43) : const Color(0xFF6B7280),
                  ),
                ),
              ]),
            ),
          );
        }),
      ),
    );
  }
}

// ── Mobile bottom nav ─────────────────────────────────────────────────────────

class _MobileBottomNav extends StatelessWidget {
  final int index;
  final List<_NavItem> items;
  final int pendingInquiry;
  final ValueChanged<int> onTap;

  const _MobileBottomNav({
    required this.index,
    required this.items,
    required this.pendingInquiry,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        color: Colors.white,
        boxShadow: [BoxShadow(color: Color(0x15000000), blurRadius: 8, offset: Offset(0, -2))],
      ),
      child: SafeArea(
        child: SizedBox(
          height: 60,
          child: Row(
            children: List.generate(items.length, (i) {
              final item = items[i];
              final selected = i == index;
              final showBadge = i == 2 && pendingInquiry > 0;
              return Expanded(
                child: InkWell(
                  onTap: () => onTap(i),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Stack(clipBehavior: Clip.none, children: [
                        Icon(item.icon,
                          size: 22,
                          color: selected ? const Color(0xFF1B7A43) : const Color(0xFF9CA3AF),
                        ),
                        if (showBadge)
                          Positioned(
                            right: -6, top: -4,
                            child: Container(
                              padding: const EdgeInsets.all(3),
                              decoration: const BoxDecoration(
                                color: Color(0xFFDC2626),
                                shape: BoxShape.circle,
                              ),
                              child: Text('$pendingInquiry',
                                style: const TextStyle(color: Colors.white, fontSize: 9, fontWeight: FontWeight.w700),
                              ),
                            ),
                          ),
                      ]),
                      const SizedBox(height: 3),
                      Text(item.label,
                        style: TextStyle(
                          fontSize: 10,
                          fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                          color: selected ? const Color(0xFF1B7A43) : const Color(0xFF9CA3AF),
                        ),
                      ),
                    ],
                  ),
                ),
              );
            }),
          ),
        ),
      ),
    );
  }
}
