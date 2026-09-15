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
              // CMD #2030 — same token target as the avatar; its right edge is
              // the search bar's right edge.
              width: Ds.touch.minTarget,
              height: Ds.touch.minTarget,
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

// ─── CMD #2030 — the header band follows the finger, 1:1 ─────────────────────
// ─── CMD #2038 — …but only when the finger actually asked for it ─────────────
// ─── CMD #2052 — so stop asking the LIST, and ask the finger ─────────────────
//
// CMD #2019 gave the band back to the products on scroll, but on a verdict:
// 12 px of travel flipped a bool and a 180 ms curve played the rest. #2030
// deleted the verdict and made the band a DISTANCE that IS the scroll delta.
// #2038 then filtered the deltas no finger produced — overscroll, bounce, the
// snap-back, a tremor mid-drag.
//
// All of it read the SCROLL OFFSET, and the offset is the problem. It does not
// only move when a finger moves it: a page of products arriving shortens
// nothing but re-measures everything, a grid re-lays-out, a keyboard opens, a
// `jumpTo` fires, a collapsing band hands its own height to the viewport. Each
// of those reports pixels running BACKWARDS, every backward pixel read as "the
// finger came up", and the header flashed back mid-scroll with no reversal of
// Om's own. Filtering harder could never fix it: a re-measure is
// indistinguishable from a drag once you are looking at an offset.
//
// So the input is not the offset any more. It is the POINTER, and only while it
// is down:
//
//   1. ONLY A FINGER MOVES THE BAND. The driver reads `dragDetails.delta`, the
//      pointer's own travel, and ignores every ScrollUpdate that carries no
//      drag. Inserted content, a re-measure, a keyboard, a programmatic jump
//      and the band's own effect on the viewport all arrive without a finger,
//      so all of them move the header by exactly zero.
//   2. MOMENTUM FOLLOWS THE DRAG THAT STARTED IT. A ballistic phase drives
//      nothing at all. When the finger leaves the glass the band finishes in
//      the direction the DRAG was going, so a downward fling can only ever end
//      with the header away — it can never reveal it on the way.
//   3. A REVERSAL EARNS ITS TURN, on the finger: `Ds.touch.headerHysteresis`
//      (40 px) of deliberate travel the other way. Under that the band does not
//      move — but the travel is KEPT, so the moment the turn is earned every
//      pixel the finger asked for is paid at once, rather than the first 40 px
//      of every reversal being eaten.
//   4. OVERSCROLL AND BOUNCE ARE NOT SCROLL. An OverscrollNotification is
//      discarded outright, and so is any drag reported while the list is
//      outside its own [min, max] — the whole of a bounce and the whole of the
//      spring back.
//   5. IT IS NEVER LEFT HALF OPEN. The gesture decides which end;
//      `Ds.touch.headerSettleMs` decides how fast it gets there. The settle is
//      an ANIMATION VALUE written into the same notifier the render object
//      already listens to, so a settle rebuilds exactly as much as a drag
//      does: nothing.
//
// It is still not a real SliverAppBar, for #2019's reason: the chrome BELOW the
// band is what must stay pinned, and that chrome changes height with focus (the
// search bar, the breadcrumb, the A–Z rail, the category chip row, and the idle
// rail that opens under them). A pinned sliver must be told its extent in
// advance; a widget that sits outside the scroll view need not be, and outside
// the scroll view is the strongest form of pinned there is. The band shrinks
// its own height, so every one of those rows stays exactly under wherever the
// band currently ends. Nothing reflows: the width never changes.
//
// ONE band, ONE driver, ONE notifier — for Home and for the Catalogue both
// (#2052(8)). They are two pages of the same shell, so the Catalogue's lists
// bubble their notifications into the same listener and collapse the same
// header; there is no second controller to keep in step with this one.

/// How many logical pixels of the header band are currently gone: 0 = the whole
/// band is showing, `Ds.touch.headerBand` = it is entirely off the top. Every
/// value in between is real — this is a position, not a state.
final ValueNotifier<double> shellHeaderCollapse = ValueNotifier<double>(0);

/// Is any of the band still showing? Derived, never stored: a second source of
/// truth is how a scroll-linked header starts snapping again.
bool get shellHeaderBandShowing =>
    shellHeaderCollapse.value < Ds.touch.headerBand;

/// The deepest collapse this session has reached, for the render log: a live
/// page that reports it has moved the band by N pixels is proof the driver ran,
/// which a screenshot of a header at rest can never be.
double _bandDeepest = 0;

void _bandSet(double v) {
  if (shellHeaderCollapse.value == v) return;
  shellHeaderCollapse.value = v;
  if (v > _bandDeepest) {
    _bandDeepest = v;
    RenderLog.write('c2030_band_px', v.round());
  }
}

// ── The driver's memory. Three numbers and a flag, no widget state. ──────────

/// The direction the band is currently travelling in: 1 = hiding (the finger is
/// going up the glass), -1 = showing, 0 = it has not moved yet.
double _bandDir = 0;

/// Finger travel AGAINST [_bandDir] that has been asked for but not yet
/// believed, signed. It is spent in full the moment it crosses the hysteresis,
/// so a reversal is DELAYED by 40 px — never shortened by 40 px.
double _bandPending = 0;

/// Is a finger currently on the glass? Set by the first drag delta of a
/// gesture, cleared when the gesture is finished off. It is what tells a
/// ballistic delta apart from a re-measure: both arrive without a finger, but
/// only one of them follows one.
bool _bandDragging = false;

/// Deltas the filters threw away, for the render log: a live page that reports
/// it refused N deltas is the only proof a flicker guard can give, because the
/// flicker it prevents is by definition not in a screenshot.
int _bandHeld = 0;

/// Gestures finished off by the settle, for the render log.
int _bandSettled = 0;

/// The mounted band's settle animation, or null when no band is on screen (a
/// unit test, a disabled tab). Without one the band still finishes — it simply
/// arrives instantly instead of travelling.
_ShellHeaderSettle? _bandSettle;

void _bandHold() {
  _bandHeld++;
  RenderLog.write('c2038_hold', _bandHeld);
}

/// Put the band back. A new tab, or a tab the band does not belong to, starts
/// with full chrome — and with no memory of the last tab's direction.
void shellHeaderBandShow() {
  _bandDir = 0;
  _bandPending = 0;
  _bandDragging = false;
  _bandSettle?.stop();
  _bandSet(0);
}

/// Feeds [shellHeaderCollapse] from the FINGER, 1:1 — and from nothing else.
/// Always returns false: this listens, it never swallows a notification.
bool shellHeaderScroll(ScrollNotification n, bool enabled) {
  if (!enabled) {
    shellHeaderBandShow();
    return false;
  }
  // Horizontal rails (the home feed's carousels, the chip row, the A–Z strip,
  // the idle rail) scroll constantly and must never move the band.
  if (n.metrics.axis != Axis.vertical) return false;
  if (!n.metrics.hasContentDimensions) return false;

  final double h = Ds.touch.headerBand;

  // A finger landing cancels a settle that is still playing and throws away a
  // reversal that was still being built: the next gesture starts its own
  // argument. The direction SURVIVES, because the 40 px a turn costs is about
  // the finger changing its mind, not about where a gesture happens to end.
  if (n is ScrollStartNotification) {
    _bandSettle?.stop();
    _bandPending = 0;
    _bandDragging = n.dragDetails != null;
    return false;
  }
  // #2052(5) — the list has come to rest. Whatever is left half open is
  // finished off now.
  if (n is ScrollEndNotification) {
    _bandFinishGesture();
    return false;
  }
  // #2052(2) — `idle` IS the finger leaving the glass, and it is reported
  // BEFORE the ballistic phase starts. The band settles from here, so the
  // momentum that follows has nothing left to do and nothing to reveal.
  if (n is UserScrollNotification) {
    if (n.direction == ScrollDirection.idle) _bandFinishGesture();
    return false;
  }
  // #2052(4) — an OverscrollNotification IS the bounce. It never drives.
  if (n is OverscrollNotification) {
    _bandHold();
    return false;
  }
  if (n is! ScrollUpdateNotification) return false;

  // #2052(1) — no finger, no movement. A fling coasting, the physics settling,
  // a page of products inserted, a grid re-measuring, the keyboard opening, a
  // programmatic jump: every one of them arrives here without `dragDetails`,
  // and not one of them is allowed a pixel of the header. The first of them
  // after a drag is also the moment the finger left, so the gesture is
  // finished off rather than abandoned half open.
  if (n.dragDetails == null) {
    if (_bandDragging) {
      _bandFinishGesture();
    } else {
      _bandHold();
    }
    return false;
  }

  // A page with less to scroll than the band is tall can never lose its header:
  // hiding it would be the only scrolling the page had.
  if (n.metrics.maxScrollExtent - n.metrics.minScrollExtent <= h) {
    shellHeaderBandShow();
    return false;
  }

  // #2052(4) — the list is past one of its own ends: this drag is stretching a
  // bounce, not scrolling. Ignored entirely, in both directions.
  if (n.metrics.outOfRange) {
    _bandHold();
    return false;
  }

  _bandDragging = true;
  _bandSettle?.stop();

  // The pointer's own travel. A finger moving UP the glass (a negative dy)
  // takes the list DOWN and the header with it, so the band's sign is the
  // pointer's, flipped. `scrollDelta` is deliberately not read: it is the
  // number that lies when the list re-measures.
  final double d = -n.dragDetails!.delta.dy;
  if (d == 0) return false;

  // Sitting at the very top of the list wearing half a header is a state no
  // drag can leave, because there is no more list to drag back. The floor is
  // read only while a finger is down, so an offset that arrives at 0 on its own
  // — a reset, a jumpTo, a re-measure — can still never flash the header back.
  if (n.metrics.pixels <= n.metrics.minScrollExtent && d <= 0) {
    _bandDir = -1;
    _bandPending = 0;
    _bandSet(0);
    return false;
  }

  double spend = d;
  if (_bandDir == 0) {
    // Nothing to reverse yet — the first push sets the direction and is paid in
    // full, exactly as #2030 promised.
    _bandPending = 0;
  } else {
    // #2052(3) — the reservoir. Every drag delta goes in; the band moves only
    // when what is in it points the way the band is already going, or when a
    // reversal has travelled far enough to be believed. So a wobble that nets
    // nothing moves nothing in EITHER direction, and a reversal that is finally
    // believed is paid in full rather than docked the threshold.
    _bandPending += d;
    if (_bandPending * _bandDir > 0) {
      spend = _bandPending; // with the grain: net travel, 1:1
    } else if (_bandPending.abs() >= Ds.touch.headerHysteresis) {
      spend = _bandPending; // the turn is earned, and paid in full
    } else {
      _bandHold();
      return false;
    }
    _bandPending = 0;
  }
  _bandDir = spend > 0 ? 1.0 : -1.0;

  // 1:1, both directions, inside the band's own height.
  double v = shellHeaderCollapse.value + spend;
  if (v < 0) v = 0;
  if (v > h) v = h;
  _bandSet(v);
  return false;
}

/// #2052(5) — the finger has left. The band is finished off at the end the DRAG
/// was heading for, never at the end an offset happens to be nearest: that is
/// what makes a downward fling unable to reveal it. With no gesture behind it
/// (a stray end notification) the nearer end wins, so the band is never left
/// standing half open by anything at all.
void _bandFinishGesture() {
  if (!_bandDragging) return;
  _bandDragging = false;
  _bandPending = 0;
  final double h = Ds.touch.headerBand;
  final double from = shellHeaderCollapse.value;
  final double to = _bandDir > 0
      ? h
      : _bandDir < 0
          ? 0
          : (from * 2 >= h ? h : 0);
  if (from == to) return;
  _bandSettled++;
  RenderLog.write('c2052_settle', _bandSettled);
  final _ShellHeaderSettle? s = _bandSettle;
  if (s == null) {
    _bandSet(to);
    return;
  }
  s.run(from, to);
}

/// The settle: an [AnimationController] whose value is written straight into
/// [shellHeaderCollapse]. Nothing rebuilds — the render object is already
/// listening to that notifier, so an animated frame costs exactly what a
/// dragged frame costs.
class _ShellHeaderSettle {
  _ShellHeaderSettle(TickerProvider vsync)
      : _c = AnimationController(vsync: vsync, duration: _settleDuration) {
    _c.addListener(_tick);
  }

  static Duration get _settleDuration =>
      Duration(milliseconds: Ds.touch.headerSettleMs.round());

  final AnimationController _c;
  double _from = 0;
  double _to = 0;

  void _tick() {
    final double t = Curves.easeOutCubic.transform(_c.value);
    _bandSet(_from + (_to - _from) * t);
  }

  void run(double from, double to) {
    _from = from;
    _to = to;
    _c.duration = _settleDuration;
    _c.forward(from: 0);
  }

  void stop() {
    if (_c.isAnimating) _c.stop();
  }

  void dispose() {
    _c.removeListener(_tick);
    _c.dispose();
  }
}

/// CMD #2052(8) — the shell tabs the band belongs to: the storefront Home (0)
/// and the Catalogue (12). Both are pages of the SAME shell, drawn under the
/// SAME header, so both are driven by the one controller above rather than by a
/// second one that would have to be kept in step with it. Every other tab —
/// Orders, Bulk upload, My Shop, and every staff page — keeps its header at all
/// times, which is what `shellHeaderScroll(n, false)` restores.
bool shellHeaderBandTab(int index) => index == 0 || index == 12;

/// The header band, wrapped so it can ride the scroll. [enabled] is the shell's
/// own verdict — only the customer phone chrome collapses.
Widget shellCollapsibleBand(bool enabled, Widget child) =>
    enabled ? _CollapsingBand(child: child) : child;

/// CMD #2052 — the band owns the settle's ticker, and nothing else.
///
/// It is a StatefulWidget purely so there is a [TickerProvider] with the band's
/// own lifetime to hang the settle on. It never calls `setState`, so the child
/// is built exactly once: the movement — dragged or settling — is a number on a
/// notifier the render object below reads for itself.
class _CollapsingBand extends StatefulWidget {
  const _CollapsingBand({required this.child});

  final Widget child;

  @override
  State<_CollapsingBand> createState() => _CollapsingBandState();
}

class _CollapsingBandState extends State<_CollapsingBand>
    with SingleTickerProviderStateMixin {
  late final _ShellHeaderSettle _settle;

  @override
  void initState() {
    super.initState();
    _settle = _ShellHeaderSettle(this);
    _bandSettle = _settle;
  }

  @override
  void dispose() {
    if (identical(_bandSettle, _settle)) _bandSettle = null;
    _settle.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => _BandBox(child: widget.child);
}

/// CMD #2038 — a render object, not a builder.
///
/// #2030 already handed the header subtree through a `ValueListenableBuilder`
/// untouched, so the header's own widgets never rebuilt. The WRAPPER still did:
/// every frame of every flick allocated a new `Align` and updated its element,
/// 60 times a second, to change one number. There is no widget to rebuild here
/// at all. The notifier is read by the render object itself; moving it marks
/// layout and paint and nothing else, and the child is laid out with the very
/// same constraints every frame, so it never relayouts either — it is simply
/// painted [_gone] pixels higher, under a clip.
class _BandBox extends SingleChildRenderObjectWidget {
  const _BandBox({required Widget child}) : super(child: child);

  @override
  _RenderCollapsingBand createRenderObject(BuildContext context) {
    RenderLog.write('c2030_band', 1);
    RenderLog.write('c2038_band', 1);
    RenderLog.write('c2052_band', 1);
    return _RenderCollapsingBand(shellHeaderCollapse);
  }
}

class _RenderCollapsingBand extends RenderBox
    with RenderObjectWithChildMixin<RenderBox> {
  _RenderCollapsingBand(this._collapse);

  final ValueListenable<double> _collapse;

  /// How many pixels of the band are gone, clamped to the band's own measured
  /// height. Read from the notifier, never stored anywhere else.
  double _gone = 0;

  ClipRectLayer? _clip;

  @override
  void attach(PipelineOwner owner) {
    super.attach(owner);
    _gone = _read();
    _collapse.addListener(_onCollapse);
  }

  @override
  void detach() {
    _collapse.removeListener(_onCollapse);
    super.detach();
  }

  @override
  void dispose() {
    _clip?.dispose();
    _clip = null;
    super.dispose();
  }

  double _read() {
    final double v = _collapse.value;
    return v.isFinite && v > 0 ? v : 0;
  }

  void _onCollapse() {
    final double v = _read();
    if (v == _gone) return;
    _gone = v;
    // Our own height changes, so this is layout — but the CHILD's constraints
    // do not change, so the header itself is never laid out again either.
    markNeedsLayout();
  }

  /// The band's natural height, and how much of it is currently hidden.
  double get _hidden {
    final RenderBox? c = child;
    if (c == null) return 0;
    final double nat = c.size.height;
    return _gone > nat ? nat : _gone;
  }

  @override
  void setupParentData(RenderObject child) {
    if (child.parentData is! BoxParentData) child.parentData = BoxParentData();
  }

  @override
  void performLayout() {
    final RenderBox? c = child;
    if (c == null) {
      size = constraints.smallest;
      return;
    }
    // Width comes from the parent, height is the header's own: the same
    // constraints on every frame, which is what keeps the child out of layout.
    c.layout(constraints.widthConstraints(), parentUsesSize: true);
    final double nat = c.size.height;
    final double gone = _gone > nat ? nat : _gone;
    size = constraints.constrain(Size(c.size.width, nat - gone));
  }

  @override
  Size computeDryLayout(BoxConstraints constraints) {
    final RenderBox? c = child;
    if (c == null) return constraints.smallest;
    final Size s = c.getDryLayout(constraints.widthConstraints());
    final double gone = _gone > s.height ? s.height : _gone;
    return constraints.constrain(Size(s.width, s.height - gone));
  }

  @override
  double computeMinIntrinsicWidth(double height) =>
      child?.getMinIntrinsicWidth(height) ?? 0;

  @override
  double computeMaxIntrinsicWidth(double height) =>
      child?.getMaxIntrinsicWidth(height) ?? 0;

  @override
  double computeMinIntrinsicHeight(double width) =>
      ((child?.getMinIntrinsicHeight(width) ?? 0) - _gone).clamp(0.0, 1e9);

  @override
  double computeMaxIntrinsicHeight(double width) =>
      ((child?.getMaxIntrinsicHeight(width) ?? 0) - _gone).clamp(0.0, 1e9);

  @override
  void paint(PaintingContext context, Offset offset) {
    final RenderBox? c = child;
    if (c == null) return;
    final double gone = _hidden;
    // The band RISES: the slice still on screen is its BOTTOM, exactly as if
    // the row were scrolling off the top of the list. A pure translation, and
    // a clip so the part that has risen past the top paints nowhere.
    if (gone <= 0) {
      _clip?.dispose();
      _clip = null;
      context.paintChild(c, offset);
      return;
    }
    _clip = context.pushClipRect(
      needsCompositing,
      offset,
      Offset.zero & size,
      (PaintingContext inner, Offset o) =>
          inner.paintChild(c, o + Offset(0, -gone)),
      oldLayer: _clip,
    );
  }

  @override
  bool hitTestChildren(BoxHitTestResult result, {required Offset position}) {
    final RenderBox? c = child;
    if (c == null) return false;
    final Offset shift = Offset(0, -_hidden);
    return result.addWithPaintOffset(
      offset: shift,
      position: position,
      hitTest: (BoxHitTestResult r, Offset p) => c.hitTest(r, position: p),
    );
  }

  @override
  void applyPaintTransform(RenderObject child, Matrix4 transform) {
    transform.translateByDouble(0.0, -_hidden, 0.0, 1.0);
  }
}
