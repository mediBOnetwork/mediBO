import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../design_tokens.dart';
import '../../pages/supplier_disputes_page.dart';
import '../../services/supplier_account_state.dart';
import '../../services/ui_copy.dart';
import '../../user_state.dart';
import '../../utils/render_log.dart';
import 'supplier_account_page.dart';
import 'supplier_add_medicine_screen.dart';
import 'supplier_home_screen.dart';
import 'supplier_inquiry_screen.dart';
import 'supplier_orders_screen.dart';
import 'supplier_payments_screen.dart';
import 'supplier_payout_screen.dart';
import 'supplier_records_screen.dart';
import 'supplier_scorecard_inbox.dart'; // #465 row 65 — the bell + inbox
import 'supplier_staff_screen.dart';

class SupplierShell extends StatefulWidget {
  // When set, the shell runs in View-As preview mode using admin preview RPCs.
  final String? viewAsSupplierId;
  final String? viewAsSupplierName;

  const SupplierShell({
    super.key,
    this.viewAsSupplierId,
    this.viewAsSupplierName,
  });

  bool get isViewAs => viewAsSupplierId != null;

  @override
  State<SupplierShell> createState() => _SupplierShellState();
}

class _SupplierShellState extends State<SupplierShell> {
  int _index = 0;

  /// CHANGE #402 — `supplier_session()`: who this login is, which surfaces it
  /// may open, and which language it reads. Null until it lands, and while it
  /// is null the shell shows exactly what it showed before this change — a
  /// slow session must never take a tab away from the owner.
  Map<String, dynamic>? _session;
  int _pendingInquiryCount = 0;
  /// CHANGE #465 · row 65 — the BACKEND's unread total for this supplier.
  int _inboxUnread = 0;
  int _activeDisputeCount = 0;
  bool _bannerDismissed = false;

  // Keys to allow deep-linking into child screens
  final GlobalKey<SupplierInquiryScreenState> _inquiryKey = GlobalKey();

  static const List<IconData> _tabIcons = [
    Icons.store_outlined,
    Icons.add_circle_outline,
    Icons.question_answer_outlined,
    Icons.receipt_long_outlined,
    Icons.gavel_outlined,
  ];

  List<String> get _tabLabels => [
    c('supplier_shell.tab_home'),
    c('supplier_shell.tab_add_medicine'),
    c('supplier_shell.tab_inquiry'),
    c('supplier_shell.tab_orders'),
    c('supplier_shell.tab_disputes'),
  ];

  /// The bar is the tabs this login may READ, in their original order. The
  /// grade is the backend's; this file only asks.
  List<_NavItem> get _navItems => [
    for (var slot = 0; slot < _tabIcons.length; slot++)
      if (_tabFeature[slot] == null || _canRead(_tabFeature[slot]!))
        _NavItem(icon: _tabIcons[slot], label: _tabLabels[slot], slot: slot),
  ];

  /// The feature key each tab index needs. Home is the shell itself and is
  /// never gated; the other four are the four surfaces the backend grades.
  static const Map<int, String> _tabFeature = {
    1: 'supplier.catalog',
    2: 'supplier.inquiry',
    3: 'supplier.orders',
    4: 'supplier.disputes',
  };

  /// The backend's grade for one feature. Absent session => 'write', i.e. the
  /// behaviour that existed before staff logins did.
  String _access(String featureKey) {
    final s = _session;
    if (s == null) return 'write';
    for (final f in supplierRows(s['features'])) {
      if (supplierStr(f, 'feature_key') == featureKey) {
        return supplierStr(f, 'access');
      }
    }
    return 'none';
  }

  bool _canRead(String featureKey) => _access(featureKey) != 'none';

  @override
  void initState() {
    super.initState();
    RenderLog.write('supplier_shell', 'init');
    if (!widget.isViewAs) {
      _loadSession();
      _loadInbox();
    }
  }

  Future<void> _loadSession() async {
    try {
      final s = await SupplierApi.session();
      if (!mounted || s['ok'] != true) return;
      setState(() {
        _session = s;
        // A tab this login may not open must not stay selected.
        final need = _tabFeature[_index];
        if (need != null && !_canRead(need)) _index = 0;
      });
      RenderLog.write('c402_supplier_session',
          supplierRows(s['features']).length);
    } catch (_) {
      // The shell keeps working on its pre-#402 behaviour.
    }
  }

  /// The inbox is asked for its own unread count; nothing is counted here.
  Future<void> _loadInbox() async {
    try {
      final raw = await Supabase.instance.client
          .rpc('supplier_inbox', params: {'p_limit': 1});
      final map = (raw is List ? (raw.isEmpty ? null : raw.first) : raw);
      if (!mounted || map is! Map || map['ok'] != true) return;
      final n = (map['unread'] as num?)?.toInt() ?? 0;
      if (n != _inboxUnread) setState(() => _inboxUnread = n);
      RenderLog.write('c465_sup_bell', 'unread:$n');
    } catch (_) {
      // A bell that cannot ask simply shows no number.
    }
  }

  void _onPendingCount(int count) {
    if (!mounted) return;
    if (count != _pendingInquiryCount) {
      setState(() {
        _pendingInquiryCount = count;
        if (count > 0) _bannerDismissed = false;
      });
    }
  }

  void _onDisputeCount(int count) {
    if (!mounted) return;
    if (count != _activeDisputeCount) setState(() => _activeDisputeCount = count);
  }

  void _goToInquiry() {
    setState(() { _index = 2; _bannerDismissed = false; });
    _inquiryKey.currentState?.refresh(source: 'banner_tap');
  }

  // CHANGE #470: the Inquiry tab lives in an IndexedStack (kept alive across
  // tab switches), so it never gets a fresh initState when the admin drafts,
  // sends, or an expiry lapses while the user is on another tab. Force a
  // refetch every time the tab is switched TO, so it's never stale on show.
  // CHANGE #472: pause its 8s poll timer when navigating away from it.
  void _onTabTap(int i) {
    final wasInquiry = _index == 2;
    setState(() => _index = i);
    if (i == 2) {
      _inquiryKey.currentState?.refresh(source: 'tab_switch');
    } else if (wasInquiry) {
      _inquiryKey.currentState?.pause();
    }
  }

  /// CHANGE #402 — the three self-service surfaces, behind the header's menu.
  /// Each row appears only when the backend graded that feature readable, and
  /// each row's LABEL is the backend's own (so it is Hindi in Hindi).
  void _openAccountSheet() {
    final s = _session;
    final language = supplierMap(s?['language']);
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: Ds.c.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(Ds.r.sheet)),
      ),
      builder: (sheetCtx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // CHANGE #850 — My Account: the supplier's own page, with every
            // tab the backend registry offers this login. The rows below it
            // stay where they were; each is also a tab inside it.
            ListTile(
              leading: Icon(Icons.account_circle_outlined, color: Ds.c.text),
              title: Text(c('sup_acct.title'), style: Ds.t.body),
              onTap: () {
                Navigator.pop(sheetCtx);
                openSupplierAccountPage(context);
              },
            ),
            if (_canRead('supplier.staff'))
              ListTile(
                leading: Icon(Icons.people_outline, color: Ds.c.text),
                title: Text(c('supplier_staff.feature_label'), style: Ds.t.body),
                onTap: () {
                  Navigator.pop(sheetCtx);
                  Navigator.push(context, MaterialPageRoute<void>(
                      builder: (_) => const SupplierStaffScreen()));
                },
              ),
            if (_canRead('supplier.payouts'))
              ListTile(
                leading: Icon(Icons.account_balance_outlined, color: Ds.c.text),
                title: Text(c('supplier_payout.feature_label'), style: Ds.t.body),
                onTap: () {
                  Navigator.pop(sheetCtx);
                  Navigator.push(context, MaterialPageRoute<void>(
                      builder: (_) => const SupplierPayoutScreen()));
                },
              ),
            // CHANGE #527 (#62) — the supplier's own payment statement. Before
            // this row he could not see what was owed, what was paid or
            // against which PO anywhere in the product.
            ListTile(
              leading: Icon(Icons.payments_outlined, color: Ds.c.text),
              title: Text(c('supplier_pay.feature_label'), style: Ds.t.body),
              onTap: () {
                Navigator.pop(sheetCtx);
                Navigator.push(context, MaterialPageRoute<void>(
                    builder: (_) => const SupplierPaymentsScreen()));
              },
            ),
            // CHANGE #403 — one row, four record surfaces behind it. The tabs
            // inside are the backend's list, so a fifth record type never
            // grows this sheet.
            if (_canRead('supplier.records'))
              ListTile(
                leading: Icon(Icons.folder_outlined, color: Ds.c.text),
                title: Text(c('supplier_records.feature_label'), style: Ds.t.body),
                onTap: () {
                  Navigator.pop(sheetCtx);
                  Navigator.push(context, MaterialPageRoute<void>(
                      builder: (_) => const SupplierRecordsScreen()));
                },
              ),
            ListTile(
              leading: Icon(Icons.language, color: Ds.c.text),
              title: Text(
                language['title'] is String && (language['title'] as String).isNotEmpty
                    ? language['title'] as String
                    : c('supplier_lang.title'),
                style: Ds.t.body,
              ),
              subtitle: Text(supplierStr(language, 'label'), style: Ds.t.caption),
              onTap: () {
                Navigator.pop(sheetCtx);
                _openLanguageSheet();
              },
            ),
          ],
        ),
      ),
    );
  }

  /// The options are `language.options` from the session — this file never
  /// names a language, so adding Marathi is one INSERT and no deploy.
  void _openLanguageSheet() {
    final language = supplierMap(_session?['language']);
    final options = supplierRows(language['options']);
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: Ds.c.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(Ds.r.sheet)),
      ),
      builder: (sheetCtx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: EdgeInsets.fromLTRB(
                  Ds.space.x16, Ds.space.x16, Ds.space.x16, Ds.space.x8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(supplierStr(language, 'title'), style: Ds.t.subtitle),
                  SizedBox(height: Ds.space.x4),
                  Text(supplierStr(language, 'subtitle'), style: Ds.t.caption),
                ],
              ),
            ),
            for (final o in options)
              ListTile(
                title: Text(supplierStr(o, 'label'), style: Ds.t.body),
                subtitle: Text(supplierStr(o, 'sub_label'), style: Ds.t.caption),
                trailing: o['selected'] == true
                    ? Icon(Icons.check, color: Ds.c.brand)
                    : null,
                onTap: () {
                  Navigator.pop(sheetCtx);
                  _setLanguage(supplierStr(o, 'code'));
                },
              ),
          ],
        ),
      ),
    );
  }

  Future<void> _setLanguage(String code) async {
    final r = await SupplierApi.languageSet(code);
    if (!mounted) return;
    final msg = supplierStr(r, 'message');
    if (msg.isNotEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(msg),
        backgroundColor: supplierTone(r['tone']),
      ));
    }
    if (r['ok'] != true) return;
    // The whole app's words come from ONE payload, so one refetch repaints
    // every screen in the new language — there is nothing else to reload.
    await UiCopy.refresh();
    await _loadSession();
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final supplierName = widget.viewAsSupplierName
        ?? UserState.of(context).supplierName
        ?? c('supplier_shell.supplier_fallback_name');
    final viewAsSupplierId = widget.viewAsSupplierId;
    final isDesktop = MediaQuery.of(context).size.width >= 900;

    final pages = [
      SupplierHomeScreen(viewAsSupplierId: viewAsSupplierId),
      if (viewAsSupplierId == null) const SupplierAddMedicineScreen()
      else _ViewAsReadOnlyPlaceholder(label: c('supplier_shell.viewas_readonly')),
      SupplierInquiryScreen(
        key: _inquiryKey,
        viewAsSupplierId: viewAsSupplierId,
        viewAsSupplierName: widget.viewAsSupplierName,
        onPendingCount: _onPendingCount,
      ),
      SupplierOrdersScreen(viewAsSupplierId: viewAsSupplierId, supplierName: supplierName),
      SupplierDisputesPage(
        viewAsSupplierName: widget.viewAsSupplierName,
        onActiveCount: _onDisputeCount,
      ),
    ];

    final showBanner = _pendingInquiryCount > 0 && !_bannerDismissed && _index != 2;

    return Scaffold(
      backgroundColor: const Color(0xFFF5F6F8),
      body: Column(children: [
        _SupplierHeader(
          inboxUnread: _inboxUnread,
          onInbox: viewAsSupplierId == null
              ? () async {
                  await showSupplierInbox(context);
                  await _loadInbox();
                }
              : null,
          supplierName: supplierName,
          isDesktop: isDesktop,
          staffLabel: supplierStr(supplierMap(_session), 'actor_label'),
          onMenu: viewAsSupplierId == null ? _openAccountSheet : null,
          onLogout: viewAsSupplierId == null
              ? () => UserState.read(context).signOut()
              : null, // no logout in preview mode
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
            pendingInquiry: _pendingInquiryCount,
            activeDisputes: _activeDisputeCount,
            onTap: _onTabTap,
          ),
        Expanded(
          child: IndexedStack(index: _index, children: pages),
        ),
      ]),
      bottomNavigationBar: isDesktop ? null : _MobileBottomNav(
        index: _index,
        items: _navItems,
        pendingInquiry: _pendingInquiryCount,
        activeDisputes: _activeDisputeCount,
        onTap: _onTabTap,
      ),
    );
  }
}

class _NavItem {
  final IconData icon;
  final String label;

  /// CHANGE #402 — the tab's position in the FULL five, kept even when the bar
  /// draws fewer of them. The badges key off this, so hiding a tab a staff
  /// login may not open can never move a badge onto the wrong icon.
  final int slot;
  const _NavItem({required this.icon, required this.label, required this.slot});
}

// ── Header ────────────────────────────────────────────────────────────────────

class _SupplierHeader extends StatelessWidget {
  /// CHANGE #465 · register row 65 — the bell. notification_log had 35 rows for
  /// audience='supplier' and every one was channel='whatsapp', so a supplier
  /// who opened the app was told nothing about a new inquiry, a new PO or a
  /// dispute. The count is the BACKEND's unread total, never counted here.
  final int inboxUnread;
  final VoidCallback? onInbox;
  final String supplierName;
  final bool isDesktop;
  final VoidCallback? onLogout;

  /// CHANGE #402 — the backend's own "who is signed in" line for a STAFF
  /// login, empty for the owner. Never composed here.
  final String staffLabel;
  final VoidCallback? onMenu;

  const _SupplierHeader({
    this.inboxUnread = 0,
    this.onInbox,
    required this.supplierName,
    required this.isDesktop,
    required this.onLogout,
    this.staffLabel = '',
    this.onMenu,
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
        Text(c('supplier_shell.brand'), style: const TextStyle(
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
          child: Text(c('supplier_shell.role_badge'), style: const TextStyle(
            color: Colors.white, fontSize: 11, fontWeight: FontWeight.w500,
          )),
        ),
        const Spacer(),
        Flexible(
          child: Text(
            staffLabel.isNotEmpty
                ? staffLabel
                : cf('supplier_shell.greeting', {'name': supplierName}),
            style: const TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.w500),
            overflow: TextOverflow.ellipsis,
          ),
        ),
        const SizedBox(width: 12),
        if (onInbox != null)
          InkWell(
            onTap: onInbox,
            borderRadius: Ds.r.rButton,
            child: Padding(
              padding: EdgeInsets.all(Ds.space.x4),
              child: Badge(
                isLabelVisible: inboxUnread > 0,
                label: Text('$inboxUnread'),
                child: const Icon(Icons.notifications_none,
                    color: Colors.white, size: 20),
              ),
            ),
          ),
        if (onMenu != null)
          InkWell(
            onTap: onMenu,
            borderRadius: Ds.r.rButton,
            child: Padding(
              padding: EdgeInsets.all(Ds.space.x4),
              child: const Icon(Icons.more_vert, color: Colors.white, size: 20),
            ),
          ),
        if (onLogout != null)
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
              cf(
                count == 1
                    ? 'supplier_shell.banner_pending_one'
                    : 'supplier_shell.banner_pending_many',
                {'count': '$count'},
              ),
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
  final int pendingInquiry;
  final int activeDisputes;
  final ValueChanged<int> onTap;

  const _DesktopTabBar({
    required this.index,
    required this.items,
    required this.pendingInquiry,
    required this.activeDisputes,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      color: Colors.white,
      padding: const EdgeInsets.symmetric(horizontal: 24),
      child: Row(
        children: List.generate(items.length, (i) {
          final item = items[i];
          final selected = item.slot == index;
          return InkWell(
            onTap: () => onTap(item.slot),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
              decoration: BoxDecoration(
                border: Border(bottom: BorderSide(
                  color: selected ? const Color(0xFF1B7A43) : Colors.transparent,
                  width: 2,
                )),
              ),
              child: Row(children: [
                Stack(clipBehavior: Clip.none, children: [
                  Icon(item.icon,
                    size: 18,
                    color: selected ? const Color(0xFF1B7A43) : const Color(0xFF6B7280),
                  ),
                  if ((item.slot == 2 && pendingInquiry > 0) ||
                      (item.slot == 4 && activeDisputes > 0))
                    Positioned(
                      right: -5, top: -3,
                      child: Container(
                        width: 8, height: 8,
                        decoration: const BoxDecoration(
                          color: Color(0xFFDC2626),
                          shape: BoxShape.circle,
                        ),
                      ),
                    ),
                ]),
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
  final int activeDisputes;
  final ValueChanged<int> onTap;

  const _MobileBottomNav({
    required this.index,
    required this.items,
    required this.pendingInquiry,
    required this.activeDisputes,
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
              final selected = item.slot == index;
              final showBadge = (item.slot == 2 && pendingInquiry > 0) ||
                               (item.slot == 4 && activeDisputes > 0);
              return Expanded(
                child: InkWell(
                  onTap: () => onTap(item.slot),
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
                              child: Text(
                                item.slot == 4 ? '$activeDisputes' : '$pendingInquiry',
                                style: const TextStyle(color: Colors.white, fontSize: 9,
                                    fontWeight: FontWeight.w700),
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

// ── Read-only placeholder (shown in View-As preview for write-only screens) ───

class _ViewAsReadOnlyPlaceholder extends StatelessWidget {
  final String label;
  const _ViewAsReadOnlyPlaceholder({required this.label});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
          const Icon(Icons.preview_outlined, size: 40, color: Color(0xFFD97706)),
          const SizedBox(height: 12),
          Text(
            label,
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 14, color: Color(0xFF92400E)),
          ),
        ]),
      ),
    );
  }
}
