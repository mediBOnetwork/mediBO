part of '../home_shell.dart';

// CHANGE #327 · LAYER 1 — sharded out of home_shell.dart.
//
// Mobile chrome: the location header and the staff profile avatar (CMD #2125 —
// the customer header is the logo alone; the cart icon is gone).
//
// It is a `part`, not a new library, on purpose: nearly every widget in
// the shell is library-private and used by the others, so extracting them
// into real libraries would force ~40 classes public and rewrite every
// reference. A part shares the library's imports and its privacy scope, so
// this is a pure move — and it gives this concern its own leasable path, so
// a cart command and a login command stop fighting over one file.
class _LocationHeader extends StatelessWidget {
  final bool isAdmin;
  final VoidCallback onCart;
  final VoidCallback onHome;
  final VoidCallback onLogoTap;
  final String logoTooltip;
  final ValueChanged<String>? onAdminNav;
  final bool isSuperAdmin;
  final int deletionCount;
  /// CHANGE #306 — unactioned unpaid orders, for the nav badge.
  final int alertCount;
  /// CHANGE #298 — the shell owns the bell's state so a foreground push can
  /// refresh the badge that is currently mounted.
  final GlobalKey<NotificationBellState>? bellKey;
  const _LocationHeader({
    required this.isAdmin,
    required this.onCart,
    required this.onHome,
    required this.onLogoTap,
    required this.logoTooltip,
    this.onAdminNav,
    this.isSuperAdmin = false,
    this.deletionCount = 0,
    this.alertCount = 0,
    this.bellKey,
  });

  @override
  Widget build(BuildContext context) {
    RenderLog.write('c2125_header', isAdmin ? 'staff' : 'v2');
    // CMD #2147 — the customer header v2: ONE row, logo left with the
    // order-hours pill beside it, the bell right. No WhatsApp, profile or cart.
    if (!isAdmin) return _CustomerHeaderRow(onLogoTap: onLogoTap, bellKey: bellKey);
    return SafeArea(
      bottom: false,
      child: Container(
        width: double.infinity,
        // CMD #2030 — ONE height, and it is the token the scroll-linked band
        // travels by, so "how tall is the header" and "how far does it move"
        // are the same number. And ONE side margin: Ds.space.x16, the search
        // bar's own, so the avatar's left edge and the cart's right edge sit
        // exactly on the field's edges instead of 4 px inside them.
        // CMD #2037 — the height is the token again (64, the pre-#2030 one),
        // and the rule under it is GONE: the search bar below is white now
        // too, so header + field read as one white block instead of two
        // stacked white strips with a grey hairline between them.
        height: Ds.touch.headerBand,
        decoration: const BoxDecoration(color: Colors.white),
        padding: EdgeInsets.symmetric(horizontal: Ds.space.x16),
        // CMD #1947 — a Stack, not a Row. The logo is centred against the
        // HEADER itself, so it stays exactly centred whatever the avatar on the
        // left and the date·zone chip on the right happen to measure. The chip
        // is capped at half the row less the logo's own half and truncates
        // inside that cap ("12 Sep · Rai…"), so the logo can never be pushed
        // off centre at any width.
        child: LayoutBuilder(builder: (context, box) {
          final sideMax =
              (box.maxWidth / 2 - _kLogoHalfReserve).clamp(Ds.touch.minTarget, box.maxWidth);
          return Stack(
            alignment: Alignment.center,
            children: [
              Center(
                child: Tooltip(
                  message: logoTooltip,
                  child: MouseRegion(
                    cursor: SystemMouseCursors.click,
                    child: GestureDetector(
                      onTap: onLogoTap,
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Image.asset('assets/images/medibo_logo.png', width: 28, height: 28),
                          const SizedBox(width: 7),
                          RichText(
                            text: const TextSpan(
                              children: [
                                TextSpan(
                                  text: 'medi',
                                  style: TextStyle(
                                    fontSize: 20,
                                    fontWeight: FontWeight.w700,
                                    color: Color(0xFF1B5E20),
                                    letterSpacing: -0.3,
                                  ),
                                ),
                                TextSpan(
                                  text: 'BO',
                                  style: TextStyle(
                                    fontSize: 20,
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
              // CMD #1914 (Om) — the wishlist heart and the inbox bell used
              // to stand on the right too, so that edge was three icons wide
              // against a single 40px avatar. Both moved into the profile
              // dropdown, which is a `customer_feature_placement` row rather
              // than anything this file decides. The unread count did not go
              // with the bell: it rides the avatar (ProfileUnreadDot).
              Row(
                children: [
                  // LEFT: staff keep the profile avatar. CMD #2125 — a customer's
                  // header is the logo alone; the avatar's doors live on the
                  // Profile tab (the fifth bottom tab) now.
                  if (isAdmin) _MobileProfileAvatar(
                      onAdminNav: onAdminNav,
                      isSuperAdmin: isSuperAdmin,
                      deletionCount: deletionCount,
                      alertCount: alertCount),
                  // CMD #1964 — the TEST badge stands with the avatar, inside
                  // the SAME half-width reserve the date·zone chip obeys on the
                  // other side, so switching a session on can never push the
                  // centred logo off centre or collide with it. Flexible +
                  // loose fit means it takes its natural width when there is
                  // room and clips when there is not; it is absent entirely
                  // (SizedBox.shrink, gap included) while the banner says
                  // on:false, which is every real session.
                  Flexible(
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: ConstrainedBox(
                        constraints: BoxConstraints(
                            maxWidth: (sideMax - Ds.touch.minTarget)
                                .clamp(0.0, box.maxWidth)),
                        child: const TestModeBadge(),
                      ),
                    ),
                  ),
                  const Spacer(),
                  // RIGHT: staff get the date·zone chip that replaced the old
                  // second row of filters. CMD #2125 — a customer gets nothing:
                  // the floating "View cart" pill is the cart's one door.
                  if (isAdmin) ScopeChip(maxWidth: sideMax),
                ],
              ),
            ],
          );
        }),
      ),
    );
  }
}

/// CMD #2147 — the customer header row, [Ds.touch.headerBand] tall (52 from
/// the backend token): logo + [OrderHoursHeaderPill] on the left, the inbox
/// bell on the right. The pill is Flexible so a long backend label truncates
/// before it can push the bell off the row at 320 px.
class _CustomerHeaderRow extends StatelessWidget {
  const _CustomerHeaderRow({required this.onLogoTap, this.bellKey});
  final VoidCallback onLogoTap;
  final GlobalKey<NotificationBellState>? bellKey;

  @override
  Widget build(BuildContext context) => SafeArea(
        bottom: false,
        child: Container(
          width: double.infinity,
          height: Ds.touch.headerBand,
          color: Ds.c.surface,
          padding: EdgeInsets.symmetric(horizontal: Ds.space.x16),
          child: Row(children: [
            Semantics(
              identifier: 'c2147_logo',
              button: true,
              child: GestureDetector(
                onTap: onLogoTap,
                child: const _BrandLockup(),
              ),
            ),
            SizedBox(width: Ds.space.x8 + Ds.space.x4 / 2),
            // The pill takes ALL the room between the logo and the bell (a
            // Spacer beside it would take half, truncating "Open till 12 pm"
            // at 360 px), and only ellipsizes when there truly is none left.
            const Expanded(
              child: Align(
                alignment: Alignment.centerLeft,
                child: OrderHoursHeaderPill(),
              ),
            ),
            Semantics(
              identifier: 'c2147_bell',
              child: NotificationBell(key: bellKey),
            ),
          ]),
        ),
      );
}

/// The mediBO lock-up: the m mark + wordmark. [markOnly] draws the m alone —
/// the sticky bar's left edge once the logo row has scrolled away.
class _BrandLockup extends StatelessWidget {
  const _BrandLockup({this.markOnly = false});
  final bool markOnly;

  @override
  Widget build(BuildContext context) {
    final mark = Image.asset('assets/images/medibo_logo.png',
        width: Ds.space.x24 + Ds.space.x4, height: Ds.space.x24 + Ds.space.x4);
    if (markOnly) return mark;
    return Row(mainAxisSize: MainAxisSize.min, children: [
      mark,
      SizedBox(width: Ds.space.x8),
      Text.rich(TextSpan(
        style: Ds.t.title.copyWith(fontWeight: FontWeight.w800),
        children: [
          TextSpan(text: 'medi', style: TextStyle(color: Ds.c.brandDark)),
          TextSpan(text: 'BO', style: TextStyle(color: Ds.c.brand)),
        ],
      )),
    ]);
  }
}

/// Half the centred logo lock-up plus its breathing room, in logical pixels.
/// The avatar and the chip are both held outside it, which is what makes the
/// logo's centring exact rather than approximate.
const double _kLogoHalfReserve = 70;

// ─────────────────────── Mobile profile avatar (left) ───────────────────────

class _MobileProfileAvatar extends StatefulWidget {
  final ValueChanged<String>? onAdminNav;
  final bool isSuperAdmin;
  final int deletionCount;
  /// CHANGE #306 — unactioned unpaid orders, for the nav badge.
  final int alertCount;
  const _MobileProfileAvatar({this.onAdminNav, this.isSuperAdmin = false, this.deletionCount = 0, this.alertCount = 0});

  @override
  State<_MobileProfileAvatar> createState() => _MobileProfileAvatarState();
}

/// CMD #1914 — the avatar is stateful now because it carries the unread count.
/// The bell used to fetch it from the header; the header has no bell any more,
/// so the first ask happens here and the answer is a notifier every reader
/// shares (NotifUnread).
class _MobileProfileAvatarState extends State<_MobileProfileAvatar> {
  ValueChanged<String>? get onAdminNav => widget.onAdminNav;
  bool get isSuperAdmin => widget.isSuperAdmin;
  int get deletionCount => widget.deletionCount;
  int get alertCount => widget.alertCount;

  @override
  void initState() {
    super.initState();
    NotifUnread.refresh();
  }

  @override
  Widget build(BuildContext context) {
    final auth = UserState.of(context);
    // #571 — display_name comes from my_session(); no local profile row.
    final sessionName = auth.displayName;
    final initial =
        sessionName.isNotEmpty ? sessionName[0].toUpperCase() : null;

    final viewAs = ViewAsState.of(context);
    final isCustomerViewAs = viewAs.isActive && viewAs.role == ViewAsRole.customer;

    return PressEffect(
      scale: 0.92,
      child: Semantics(
        identifier: 'cust_avatar',
        button: true,
        child: GestureDetector(
          onTap: () {
            if (!auth.isAuthenticated) {
              Navigator.push(context,
                  MaterialPageRoute(builder: (_) => const LoginScreen()));
            } else if (isCustomerViewAs) {
              // In customer ViewAs mode, show the impersonated customer's profile
              Navigator.push(context,
                  MaterialPageRoute(builder: (_) => ProfileScreen(viewAsUserId: viewAs.identity!.userId)));
            } else if (onAdminNav != null) {
              _showAdminSheet(context, auth);
            } else {
              // CMD #1914 (Om) — a customer's avatar opens the profile DROPDOWN,
              // not the profile page. My profile is the sheet's first row, so
              // the door the tap used to be is still one tap away; the wishlist
              // and the notifications inbox that used to sit on the header are
              // the rows under it. WHICH rows is `profile_dropdown` in
              // customer_feature_placement, so this file names none of them.
              _showCustomerSheet(context, auth);
            }
          },
          child: Stack(
            clipBehavior: Clip.none,
            children: [
          Container(
            // CMD #2030 — the tap target is the token minimum (44), and its edge
            // is the header's own 16 px margin, so it lands on the search bar's
            // left edge exactly.
            width: Ds.touch.minTarget,
            height: Ds.touch.minTarget,
            decoration: BoxDecoration(
              gradient: const LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [Color(0xFF1D9E75), Color(0xFF0F4C35)],
              ),
              shape: BoxShape.circle,
              boxShadow: [
                BoxShadow(
                  color: const Color(0xFF1D9E75).withValues(alpha: 0.35),
                  blurRadius: 8,
                  offset: const Offset(0, 3),
                ),
              ],
            ),
            child: Center(
              child: initial != null
                  ? Text(
                      initial,
                      style: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w800,
                        color: Colors.white,
                        height: 1,
                      ),
                    )
                  : const Icon(Icons.person_rounded,
                      color: Colors.white, size: 20),
            ),
          ),
              if (auth.isAuthenticated)
                const Positioned(
                    top: -2, right: -2, child: ProfileUnreadDot()),
            ],
          ),
        ),
      ),
    );
  }

  /// The customer's dropdown. `showResponsiveSheet` is the same door the admin
  /// sheet uses, so a wide viewport gets a dialog and a phone gets a sheet
  /// without this file deciding which.
  void _showCustomerSheet(BuildContext context, AuthNotifier auth) {
    showResponsiveSheet(
      context: context,
      builder: (_) => CustomerProfileDropdown(title: auth.headerTitle),
    );
  }

  void _showAdminSheet(BuildContext context, AuthNotifier auth) {
    final nav = onAdminNav!;
    showResponsiveSheet(
      context: context,
      builder: (_) => Padding(
        padding: const EdgeInsets.fromLTRB(24, 16, 24, 24),
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
            const SizedBox(height: 16),
            Text(
              auth.headerTitle,
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: Color(0xFF111827)),
            ),
            const SizedBox(height: 4),
            Text(c('home_shell.administrator'), style: const TextStyle(fontSize: 13, color: Color(0xFF6B7280))),
            const SizedBox(height: 4),
            Builder(builder: (_) {
              RenderLog.write('c209_debug_banner_shown', 1);
              return Text('super: $isSuperAdmin',
                  style: const TextStyle(fontSize: 11, color: Color(0xFF9CA3AF)));
            }),
            const SizedBox(height: 16),
            const Divider(),
            Builder(builder: (_) { RenderLog.write('c473_profile_menu_built', 1); return const SizedBox.shrink(); }),
            // CHANGE #325 — View Profile and Logout, and nothing else. The
            // rows are nav_registry().profile_menu, and the backend admits
            // only identity onto that surface, so a feature cannot come back
            // here by anyone editing this file.
            ValueListenableBuilder<List<Map<String, dynamic>>>(
              valueListenable: NavProfileMenu.items,
              builder: (_, items, __) =>
                  AdminProfileMenuTiles(items: items, nav: nav),
            ),
          ],
        ),
      ),
    );
  }
}

// CMD #1906 — the mobile search bar and the mobile category chip row lived
// here, both painted on a solid Ds.c.brand band (CHANGE #274). They are gone.
//
// Home and the Catalogue now draw ONE header — SearchHeaderBar +
// SearchFilterChips + SearchIdleRail in lib/widgets/search_surface.dart —
// on a white ground with a grey rounded field and outlined grey chips, the
// selected chip in brand green. Two headers for one search was why the same
// query looked like two different features depending on which box a pharmacy
// typed into.

// ─────────────────────── Cart panel ───────────────────────
