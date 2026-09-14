part of '../home_shell.dart';

// CHANGE #327 · LAYER 1 — sharded out of home_shell.dart.
//
// Mobile chrome: the location header, the profile avatar, the cart icon, the search bar and the category chips.
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
    final cartItems = AppState.of(context).distinctItems;
    return SafeArea(
      bottom: false,
      child: Container(
        width: double.infinity,
        constraints: const BoxConstraints(minHeight: 70),
        decoration: const BoxDecoration(
          color: Colors.white,
          border: Border(bottom: BorderSide(color: Brand.border)),
        ),
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 12),
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
                  // LEFT: profile avatar
                  _MobileProfileAvatar(
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
                  // second row of filters; a customer keeps the cart.
                  if (isAdmin)
                    ScopeChip(maxWidth: sideMax)
                  else
                    _MobileCartIcon(cartItems: cartItems, onCart: onCart),
                ],
              ),
            ],
          );
        }),
      ),
    );
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
          width: 40,
          height: 40,
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

// ─────────────────────── Mobile cart icon (right) ────────────────────────────

class _MobileCartIcon extends StatefulWidget {
  final int cartItems;
  final VoidCallback onCart;
  const _MobileCartIcon({required this.cartItems, required this.onCart});

  @override
  State<_MobileCartIcon> createState() => _MobileCartIconState();
}

class _MobileCartIconState extends State<_MobileCartIcon>
    with SingleTickerProviderStateMixin {
  late final AnimationController _badgeCtrl;
  late final Animation<double> _badgeScale;
  int _prevCount = 0;

  @override
  void initState() {
    super.initState();
    _prevCount = widget.cartItems;
    _badgeCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 400),
    );
    _badgeScale = TweenSequence<double>([
      TweenSequenceItem(tween: Tween(begin: 1.0, end: 1.4), weight: 30),
      TweenSequenceItem(tween: Tween(begin: 1.4, end: 0.85), weight: 30),
      TweenSequenceItem(
        tween: Tween(begin: 0.85, end: 1.0)
            .chain(CurveTween(curve: Curves.elasticOut)),
        weight: 40,
      ),
    ]).animate(_badgeCtrl);
  }

  @override
  void didUpdateWidget(_MobileCartIcon old) {
    super.didUpdateWidget(old);
    if (widget.cartItems != _prevCount) {
      _badgeCtrl.forward(from: 0);
      _prevCount = widget.cartItems;
    }
  }

  @override
  void dispose() {
    _badgeCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return PressEffect(
      scale: 0.92,
      child: GestureDetector(
        onTap: widget.onCart,
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                color: Brand.mint,
                shape: BoxShape.circle,
                border: Border.all(color: const Color(0xFFBBF7D0), width: 1.5),
                boxShadow: [
                  BoxShadow(
                    color: Brand.green.withValues(alpha: 0.18),
                    blurRadius: 6,
                    offset: const Offset(0, 2),
                  ),
                ],
              ),
              child: const Icon(Icons.shopping_bag_outlined,
                  color: Brand.green, size: 20),
            ),
            if (widget.cartItems > 0)
              Positioned(
                top: -2,
                right: -2,
                child: ScaleTransition(
                  scale: _badgeScale,
                  child: Container(
                    width: 18,
                    height: 18,
                    decoration: BoxDecoration(
                      color: const Color(0xFFDC2626),
                      shape: BoxShape.circle,
                      border: Border.all(color: Colors.white, width: 2),
                    ),
                    child: Center(
                      child: Text(
                        // CHANGE #559: badge string comes from cart_state().
                        AppState.of(context).badge ?? '',
                        style: const TextStyle(
                          fontSize: 9,
                          fontWeight: FontWeight.w800,
                          color: Colors.white,
                          height: 1,
                        ),
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

// ─── CMD #2019 — the storefront header collapses on scroll ───────────────────
//
// The phone gives ~70 px of every screen to the header band (profile · logo ·
// cart). Scrolling the storefront down hands that band back to the products
// and scrolling up returns it, which is what a floating+snapping SliverAppBar
// does — done here rather than with a real sliver because the chrome BELOW it
// is what has to stay pinned, and that chrome changes height with focus (the
// search bar, the category chip row, and the idle rail that opens under them).
// A pinned sliver has to be told its height in advance; a widget that sits
// outside the scroll view does not, and "outside the scroll view" is already
// the strongest form of pinned there is. So the search bar and the category
// row never move, and only the band above them animates.
//
// The page's own scrolling is the input: [shellHeaderScroll] reads the deltas
// that bubble up out of whichever scroll view the storefront is currently
// showing (home feed, category list or search results) and flips one notifier.
// A `setState` on the shell would rebuild every page in the IndexedStack on
// every flick, so the band listens to the notifier by itself.

/// Is the mobile header band currently shown?
final ValueNotifier<bool> shellHeaderVisible = ValueNotifier<bool>(true);

/// Below this offset the band is always shown: the top of a page keeps its
/// full chrome, and a page too short to scroll can never hide it.
const double _kBandFloor = 80;

/// How much uninterrupted travel in one direction flips the band. Small enough
/// to feel immediate, large enough that a fling's jitter cannot strobe it.
const double _kBandTravel = 12;

double _bandAcc = 0;

void _bandSet(bool v) {
  _bandAcc = 0;
  if (shellHeaderVisible.value != v) shellHeaderVisible.value = v;
}

/// Put the band back and forget the travel that hid it. Setting the notifier
/// alone would leave the accumulator mid-flick, so the first delta after a tab
/// switch could hide the header again before the finger had travelled.
void shellHeaderBandShow() => _bandSet(true);

/// Feeds [shellHeaderVisible] from the page's own scrolling. Always returns
/// false: this listens, it never swallows a notification.
bool shellHeaderScroll(ScrollNotification n, bool enabled) {
  if (!enabled) {
    _bandSet(true);
    return false;
  }
  // Horizontal rails (the home feed's carousels, the chip row, the idle rail)
  // scroll constantly and must never move the band.
  if (n.metrics.axis != Axis.vertical) return false;
  if (!n.metrics.hasContentDimensions) return false;
  if (n.metrics.pixels <= _kBandFloor ||
      n.metrics.maxScrollExtent <= _kBandFloor) {
    _bandSet(true);
    return false;
  }
  if (n is! ScrollUpdateNotification) return false;
  final d = n.scrollDelta ?? 0;
  if (d == 0) return false;
  if (d.isNegative != _bandAcc.isNegative) _bandAcc = 0;
  _bandAcc += d;
  if (_bandAcc >= _kBandTravel) {
    _bandSet(false);
  } else if (_bandAcc <= -_kBandTravel) {
    _bandSet(true);
  }
  return false;
}

/// The header band, wrapped so it can slide away and come back. [enabled] is
/// the shell's own verdict — only the customer phone storefront collapses.
Widget shellCollapsibleBand(bool enabled, Widget child) =>
    enabled ? _CollapsingBand(child: child) : child;

class _CollapsingBand extends StatefulWidget {
  const _CollapsingBand({required this.child});

  final Widget child;

  @override
  State<_CollapsingBand> createState() => _CollapsingBandState();
}

class _CollapsingBandState extends State<_CollapsingBand>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 180),
    value: 1,
  );
  late final Animation<double> _size =
      CurvedAnimation(parent: _c, curve: Curves.easeOutCubic);

  @override
  void initState() {
    super.initState();
    shellHeaderVisible.addListener(_sync);
  }

  void _sync() {
    if (!mounted) return;
    if (shellHeaderVisible.value) {
      _c.forward();
    } else {
      _c.reverse();
    }
  }

  @override
  void dispose() {
    shellHeaderVisible.removeListener(_sync);
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    RenderLog.write('c2019_band', 1);
    // ClipRect keeps the band's own bottom border from painting outside the
    // height the transition is currently giving it.
    return ClipRect(
      child: SizeTransition(
        sizeFactor: _size,
        alignment: Alignment.topCenter,
        child: widget.child,
      ),
    );
  }
}
