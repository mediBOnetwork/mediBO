part of '../home_shell.dart';

// CHANGE #327 · LAYER 1 — sharded out of home_shell.dart.
//
// Desktop header, search row and the profile buttons on both breakpoints.
//
// It is a `part`, not a new library, on purpose: nearly every widget in
// the shell is library-private and used by the others, so extracting them
// into real libraries would force ~40 classes public and rewrite every
// reference. A part shares the library's imports and its privacy scope, so
// this is a pure move — and it gives this concern its own leasable path, so
// a cart command and a login command stop fighting over one file.
class _DesktopHeader extends StatelessWidget {
  final bool scrolled;
  final VoidCallback onHome;
  final String logoTooltip;
  final VoidCallback onBulk;
  final VoidCallback onOrders;
  final VoidCallback onCart;
  final VoidCallback onLogin;
  final int index;
  final bool cartOpen;
  /// CHANGE #298 — see _LocationHeader.bellKey.
  final GlobalKey<NotificationBellState>? bellKey;

  const _DesktopHeader({
    this.bellKey,
    required this.onHome,
    required this.logoTooltip,
    required this.onBulk,
    required this.onOrders,
    required this.onCart,
    required this.onLogin,
    required this.index,
    required this.cartOpen,
    this.scrolled = false,
  });

  @override
  Widget build(BuildContext context) {
    final cartItems = AppState.of(context).distinctItems;
    final isBulk = index == 2 && !cartOpen;
    final isOrders = index == 1 && !cartOpen;

    final shadow = BoxShadow(
      color: Colors.black.withValues(alpha: scrolled ? 0.11 : 0.04),
      blurRadius: scrolled ? 14.0 : 4.0,
      offset: scrolled ? const Offset(0, 4) : const Offset(0, 1),
    );
    return AnimatedContainer(
      duration: const Duration(milliseconds: 220),
      height: 76,
      decoration: BoxDecoration(
        color: Colors.white,
        boxShadow: [shadow],
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          // 1. Logo — padded 24px left
          Padding(
            padding: const EdgeInsets.only(left: 24),
            child: Tooltip(
              message: logoTooltip,
              child: MouseRegion(
                cursor: SystemMouseCursors.click,
                child: GestureDetector(
                  onTap: onHome,
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Image.asset('assets/images/medibo_logo.png', width: 40, height: 40),
                      const SizedBox(width: 10),
                      RichText(
                        text: const TextSpan(
                          children: [
                            TextSpan(
                              text: 'medi',
                              style: TextStyle(
                                fontSize: 22,
                                fontWeight: FontWeight.w700,
                                color: Color(0xFF1B5E20),
                                letterSpacing: -0.3,
                              ),
                            ),
                            TextSpan(
                              text: 'BO',
                              style: TextStyle(
                                fontSize: 22,
                                fontWeight: FontWeight.w800,
                                color: Color(0xFF4CAF50),
                                letterSpacing: -0.3,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
          const Spacer(),
          // Customer nav: Bulk Upload, Orders, Cart
          _DesktopNavLink(
            label: c('home_shell.bulk_upload'),
            icon: Icons.upload_file_outlined,
            selected: isBulk,
            onTap: onBulk,
          ),
          const SizedBox(width: 4),
          _DesktopNavLink(
            label: c('home_shell.orders'),
            icon: Icons.receipt_long_outlined,
            selected: isOrders,
            onTap: onOrders,
          ),
          const SizedBox(width: 8),
          // Cart
          PressEffect(
            child: InkWell(
              onTap: onCart,
              borderRadius: BorderRadius.circular(8),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Badge(
                      isLabelVisible: cartItems > 0,
                      // CHANGE #559: badge string comes from cart_state().
                      label: Text(AppState.of(context).badge ?? '',
                          style: const TextStyle(fontSize: 10)),
                      child: const Icon(Icons.shopping_cart_outlined,
                          size: 22, color: Brand.ink),
                    ),
                    const SizedBox(width: 6),
                    Text(
                      c('home_shell.cart'),
                      style: const TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        color: Brand.ink,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          const SizedBox(width: 16),
          // CHANGE #298 — the inbox bell, left of the profile button, for the
          // same reason it sits left of the cart on mobile: it belongs to the
          // signed-in identity, not to the storefront.
          if (UserState.of(context).isAuthenticated)
            NotificationBell(key: bellKey),
          // 6. Auth button (Login or profile dropdown) — far right
          _DesktopProfileButton(onLogin: onLogin),
          const SizedBox(width: 24),
        ],
      ),
    );
  }
}

// ─────────────────────── Desktop search row ─────────────────────────────

class _DesktopSearchRow extends StatefulWidget {
  final TextEditingController controller;
  final FocusNode? focusNode;
  final bool isLoading;
  final ValueChanged<String> onSearch;
  final VoidCallback onScrollToResults;

  const _DesktopSearchRow({
    required this.controller,
    this.focusNode,
    required this.isLoading,
    required this.onSearch,
    required this.onScrollToResults,
  });

  @override
  State<_DesktopSearchRow> createState() => _DesktopSearchRowState();
}

class _DesktopSearchRowState extends State<_DesktopSearchRow> {
  Timer? _debounce;
  bool _hasText = false;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onControllerChange);
    _hasText = widget.controller.text.isNotEmpty;
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onControllerChange);
    _debounce?.cancel();
    super.dispose();
  }

  void _onControllerChange() {
    final hasText = widget.controller.text.isNotEmpty;
    if (hasText != _hasText) setState(() => _hasText = hasText);
  }

  void _onChanged(String v) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 150), () {
      widget.onSearch(v);
    });
  }

  void _submitNow() {
    _debounce?.cancel();
    final text = widget.controller.text;
    widget.onSearch(text);
    if (text.trim().length >= 2) widget.onScrollToResults();
    FocusManager.instance.primaryFocus?.unfocus();
  }

  void _clearSearch() {
    _debounce?.cancel();
    widget.controller.clear();
    widget.onSearch('');
    FocusManager.instance.primaryFocus?.unfocus();
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      // CHANGE #274 — the desktop search sits on the SAME brand band as the
      // mobile one and the chip row directly under it. Leaving it on white
      // while the chips moved onto the band split the header into two
      // unrelated strips, which is the exact "unfinished" look this command
      // set out to remove.
      color: Ds.c.brand,
      padding: EdgeInsets.symmetric(
          horizontal: Ds.space.x24, vertical: Ds.space.x12),
      child: Container(
        height: 46,
        clipBehavior: Clip.antiAlias,
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(Ds.r.button),
        ),
        child: Row(
          children: [
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 14),
              child: Icon(Icons.search, color: Color(0xFF9CA3AF), size: 20),
            ),
            Expanded(
              child: TextField(
                controller: widget.controller,
                focusNode: widget.focusNode,
                onChanged: _onChanged,
                onSubmitted: (_) => _submitNow(),
                textInputAction: TextInputAction.search,
                autocorrect: false,
                enableSuggestions: false,
                keyboardType: TextInputType.text,
                style: const TextStyle(fontSize: 14, color: Brand.ink),
                decoration: InputDecoration(
                  border: InputBorder.none,
                  enabledBorder: InputBorder.none,
                  focusedBorder: InputBorder.none,
                  hintText: c('home_shell.search_for_medicines'),
                  hintStyle: const TextStyle(color: Brand.inkMuted, fontSize: 14),
                  isDense: true,
                  contentPadding: const EdgeInsets.symmetric(vertical: 14),
                  filled: false,
                ),
              ),
            ),
            if (widget.isLoading)
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 10),
                child: SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2, color: Brand.green),
                ),
              )
            else if (_hasText)
              IconButton(
                onPressed: _clearSearch,
                icon: const Icon(Icons.close, size: 18, color: Color(0xFF6B7280)),
                visualDensity: VisualDensity.compact,
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
              ),
            // CMD #409 — scan and voice, in the search bar itself. Both hand
            // back a QUERY or a product the backend resolved; neither one
            // decides anything here.
            ScanSearchButton(color: Ds.c.textSecondary),
            VoiceSearchButton(
              color: Ds.c.textSecondary,
              onQuery: (q) {
                widget.controller.text = q;
                _submitNow();
              },
            ),
            SizedBox(width: Ds.space.x4),
            GestureDetector(
              onTap: _submitNow,
              child: Container(
                height: double.infinity,
                padding: const EdgeInsets.symmetric(horizontal: 22),
                // The parent clips, so the button just fills its corner.
                decoration: BoxDecoration(color: Ds.c.brand),
                child: Center(
                  child: Text(
                    c('home_shell.search'),
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ─────────────────────── Profile buttons ────────────────────────────────

/// Desktop: solid green "Login" button when logged out;
/// "Hello [name]" avatar pill with dropdown when logged in.
class _DesktopProfileButton extends StatelessWidget {
  final VoidCallback onLogin;
  final ValueChanged<String>? onAdminNav;
  final bool isSuperAdmin;
  const _DesktopProfileButton({required this.onLogin, this.onAdminNav, this.isSuperAdmin = false});

  @override
  Widget build(BuildContext context) {
    final auth = UserState.of(context);
    final viewAs = ViewAsState.of(context);
    final isCustomerViewAs = viewAs.isActive && viewAs.role == ViewAsRole.customer;

    if (!auth.isAuthenticated) {
      return PressEffect(
        child: InkWell(
          onTap: onLogin,
          borderRadius: BorderRadius.circular(8),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
            decoration: BoxDecoration(
              color: const Color(0xFF1D9E75),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Text(
              c('home_shell.login'),
              style: const TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w700,
                color: Colors.white,
              ),
            ),
          ),
        ),
      );
    }

    // #571 — no ViewAs name branch. my_session() already returns the
    // impersonated account's name when acting_as is set, so there is one name
    // and one place it comes from.
    final displayName = auth.headerTitle;
    final initial = displayName.isNotEmpty ? displayName[0].toUpperCase() : '?';
    final shortName =
        displayName.length > 16 ? '${displayName.substring(0, 14)}…' : displayName;
    final hasAdminNav = onAdminNav != null;

    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 200),
      child: PopupMenuButton<String>(
      offset: const Offset(0, 52),
      tooltip: '',
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      itemBuilder: (_) {
        if (hasAdminNav) {
          RenderLog.write('c206_dropdown_addmed', 1);
          RenderLog.write('c206_dropdown_bills', 1);
        }
        return [
        for (final row in NavProfileMenu.items.value)
          if ((row['feature_key'] ?? '') != 'identity.logout')
            PopupMenuItem(
              value: (row['route_key'] ?? '').toString(),
              child: Row(
                children: [
                  Icon(navIcon((row['icon_key'] ?? '').toString()),
                      size: 16, color: const Color(0xFF374151)),
                  const SizedBox(width: 10),
                  Text((row['label'] ?? '').toString(),
                      style: const TextStyle(
                          fontSize: 14, color: Color(0xFF374151))),
                ],
              ),
            ),
        // CHANGE #325 — the ~20 feature rows that used to sit here are the
        // dropdown Om counted to thirty. They live on the dashboard now. This
        // popup draws View Profile and Logout, from the registry.
        // CMD #411 — the pharmacy counter, from pos_entry().
        if (PosEntry.show)
          PopupMenuItem(
            value: 'pos',
            child: Row(
              children: [
                Icon(Icons.point_of_sale_outlined, size: 16, color: Ds.c.brand),
                SizedBox(width: Ds.space.x8),
                Text((PosEntry.value.value['label'] ?? '').toString(),
                    style: Ds.t.body),
              ],
            ),
          ),
        PopupMenuItem(
          value: 'logout',
          child: Row(
            children: [
              const Icon(Icons.logout, size: 16, color: Color(0xFFDC2626)),
              const SizedBox(width: 10),
              Text(c('home_shell.logout'),
                  style: const TextStyle(fontSize: 14, color: Color(0xFFDC2626))),
            ],
          ),
        ),
      ];
      },
      onSelected: (val) async {
        if (val == 'pos' && context.mounted) {
          Navigator.push(context,
              MaterialPageRoute<void>(builder: (_) => const PosScreen()));
          return;
        }
        if (val == 'profile' && context.mounted) {
          if (isCustomerViewAs) {
            Navigator.push(context, MaterialPageRoute(
              builder: (_) => ProfileScreen(viewAsUserId: viewAs.identity!.userId),
            ));
          } else {
            Navigator.push(context,
                MaterialPageRoute(builder: (_) => const ProfileScreen()));
          }
        } else if (val == 'logout') {
          if (isCustomerViewAs) {
            if (context.mounted) {
              showToast(context, c('home_shell.exit_view_as_first_then_sign_out'), isError: true);
            }
          } else {
            await UserState.read(context).signOut();
          }
        } else if (onAdminNav != null) {
          onAdminNav!(val);
        }
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: const Color(0xFFECFDF5),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: const Color(0xFFBBF7D0)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 32,
              height: 32,
              decoration: const BoxDecoration(
                color: Color(0xFF1B5E20),
                shape: BoxShape.circle,
              ),
              child: Center(
                child: Text(
                  initial,
                  style: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                    color: Colors.white,
                    height: 1,
                  ),
                ),
              ),
            ),
            const SizedBox(width: 9),
            Flexible(
              child: Text(
                cf('home_shell.hello_a', {'a': shortName}),
                style: const TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: Color(0xFF111827),
                ),
                overflow: TextOverflow.ellipsis,
                maxLines: 1,
              ),
            ),
            const SizedBox(width: 4),
            const Icon(Icons.expand_more, size: 16, color: Color(0xFF6B7280)),
          ],
        ),
      ),
    ));
  }
}

// ── Dashboard button (admins only) ───────────────────────────────────────────

class _DashboardButton extends StatelessWidget {
  final VoidCallback onTap;
  const _DashboardButton({required this.onTap});

  @override
  Widget build(BuildContext context) {
    return PressEffect(
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
          decoration: BoxDecoration(
            border: Border.all(color: Brand.green, width: 1.5),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.dashboard_outlined, size: 15, color: Brand.green),
              const SizedBox(width: 6),
              Text(
                c('home_shell.dashboard'),
                style: const TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: Brand.green,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Mobile: compact person icon that opens a profile bottom sheet.
class _MobileProfileButton extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final auth = UserState.of(context);

    return PressEffect(
      child: InkWell(
        borderRadius: BorderRadius.circular(20),
        onTap: () {
          if (!auth.isAuthenticated) {
            Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const LoginScreen()),
            );
          } else {
            _showProfileSheet(context, auth);
          }
        },
        child: Padding(
          padding: const EdgeInsets.all(4),
          child: auth.isAuthenticated
              ? Container(
                  width: 28,
                  height: 28,
                  decoration: const BoxDecoration(
                    color: Color(0xFF1B5E20),
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(Icons.person,
                      color: Colors.white, size: 16),
                )
              : const Icon(Icons.person_outline,
                  size: 26, color: Brand.ink),
        ),
      ),
    );
  }

  void _showProfileSheet(BuildContext context, AuthNotifier auth) {
    // #571 — one name, from my_session(). It already accounts for View As.
    final displayName = auth.headerTitle;
    showResponsiveSheet(
      context: context,
      builder: (_) => Padding(
        padding: const EdgeInsets.fromLTRB(24, 20, 24, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(
              child: Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: const Color(0xFFD1D5DB),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            const SizedBox(height: 20),
            Row(
              children: [
                Container(
                  width: 44,
                  height: 44,
                  decoration: const BoxDecoration(
                    color: Color(0xFF1B5E20),
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(Icons.person,
                      color: Colors.white, size: 24),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        displayName,
                        style: const TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w700,
                          color: Color(0xFF111827),
                        ),
                      ),
                      if (auth.session.profileText('phone').isNotEmpty) ...[
                        const SizedBox(height: 2),
                        Text(
                          auth.session.profileText('phone'),
                          style: const TextStyle(
                              fontSize: 13, color: Color(0xFF6B7280)),
                        ),
                      ],
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 24),
            const Divider(),
            const SizedBox(height: 4),
            InkWell(
              onTap: () {
                Navigator.pop(context);
                Navigator.push(context,
                    MaterialPageRoute(builder: (_) => const ProfileScreen()));
              },
              borderRadius: BorderRadius.circular(8),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 12),
                child: Row(
                  children: [
                    const Icon(Icons.person_outline,
                        size: 20, color: Color(0xFF374151)),
                    const SizedBox(width: 12),
                    Text(
                      c('home_shell.view_profile'),
                      style: const TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                        color: Color(0xFF374151),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            InkWell(
              onTap: () async {
                Navigator.pop(context);
                await auth.signOut();
              },
              borderRadius: BorderRadius.circular(8),
              child: Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 4, vertical: 12),
                child: Row(
                  children: [
                    const Icon(Icons.logout,
                        size: 20, color: Color(0xFFDC2626)),
                    const SizedBox(width: 12),
                    Text(
                      c('home_shell.logout'),
                      style: const TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                        color: Color(0xFFDC2626),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ─────────────────────── Admin desktop header ────────────────────────────────
