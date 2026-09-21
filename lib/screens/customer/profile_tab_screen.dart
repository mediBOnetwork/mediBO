import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:share_plus/share_plus.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../design_tokens.dart';
import '../../services/ui_copy.dart';
import '../../user_state.dart';
import '../../utils/render_log.dart';
import '../../widgets/animations.dart' show Shimmer, SkeletonBox;
import '../admin/nav_registry_view.dart' show navIcon;
import '../auth/login_screen.dart';
import '../pharmacy/my_shop_screen.dart';
import 'profile_account_menu.dart' show customerMenuScreen;

/// CMD #2125 — the Profile tab, the fifth bottom tab.
///
/// It replaces the header avatar and the My Shop tab. Everything on it is
/// `customer_profile_tab()`'s answer rendered verbatim: the header (initial,
/// pharmacy name, phone · code, approval chip), then `sections[]` in payload
/// order — `tiles` (three shortcut cards), `hero` (the My Shop card) and
/// `rows` (a titled card of 56 px rows). Which rows exist, their words, their
/// order and their section are `customer_feature_placement` rows over
/// `feature_registry`; this file names no feature.
typedef ProfileTabLoader = Future<Map<String, dynamic>> Function();

class ProfileTabScreen extends StatefulWidget {
  /// True while this is the shell page on screen. The tab asks on becoming
  /// active, so an IndexedStack build at boot costs no round trip.
  final bool active;

  /// The shell's own router, for route keys the shell owns (saved lists,
  /// help requests, 'home' after a logout).
  final ValueChanged<String> navigate;

  /// Opens the cart panel — the "Your cart" row's door.
  final VoidCallback onOpenCart;

  /// Injected by tests; production asks Supabase.
  final ProfileTabLoader? loader;

  /// Tests pin the signed-in state; production reads UserState.
  final bool? signedIn;

  const ProfileTabScreen({
    super.key,
    required this.active,
    required this.navigate,
    required this.onOpenCart,
    this.loader,
    this.signedIn,
  });

  @override
  State<ProfileTabScreen> createState() => _ProfileTabScreenState();
}

/// What a tap on a payload row does — decided from the row alone, so a test
/// can hold it down without a widget.
enum ProfileTabDoor { cart, share, logout, myShop, screen, shell }

class ProfileTabAction {
  static ProfileTabDoor doorOf(Map<String, dynamic> item) {
    final route = (item['route_key'] ?? '').toString();
    switch (route) {
      case 'cust_cart':
        return ProfileTabDoor.cart;
      case 'cust_share':
        return ProfileTabDoor.share;
      case 'cust_logout':
      case 'logout':
        return ProfileTabDoor.logout;
      case 'my_shop':
        return ProfileTabDoor.myShop;
    }
    return customerMenuScreen(route, tab: (item['tab'] ?? '').toString()) != null
        ? ProfileTabDoor.screen
        : ProfileTabDoor.shell;
  }

  /// Every item of every section, in payload order.
  static List<Map<String, dynamic>> itemsOf(Map<String, dynamic> section) =>
      ((section['items'] as List?) ?? const [])
          .whereType<Map>()
          .map((m) => Map<String, dynamic>.from(m))
          .toList();

  static List<Map<String, dynamic>> sectionsOf(Map<String, dynamic> payload) =>
      ((payload['sections'] as List?) ?? const [])
          .whereType<Map>()
          .map((m) => Map<String, dynamic>.from(m))
          .toList();
}

class _ProfileTabScreenState extends State<ProfileTabScreen> {
  Map<String, dynamic>? _payload;
  bool _loading = false;
  bool _failed = false;
  String? _loadedFor;

  bool get _signedIn =>
      widget.signedIn ?? UserState.of(context).isAuthenticated;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _maybeLoad();
  }

  @override
  void didUpdateWidget(ProfileTabScreen old) {
    super.didUpdateWidget(old);
    // Re-ask every time the tab is opened: the approval chip, the wishlist
    // count and the unread label all move while the shopper is elsewhere.
    if (widget.active && !old.active) {
      _loadedFor = null;
      _maybeLoad();
    }
  }

  void _maybeLoad() {
    if (!widget.active || !_signedIn) return;
    final who = widget.signedIn == null
        ? Supabase.instance.client.auth.currentUser?.id ?? ''
        : 'test';
    if (_loadedFor == who || _loading) return;
    _loadedFor = who;
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _failed = false;
    });
    try {
      final Map<String, dynamic> m;
      if (widget.loader != null) {
        m = await widget.loader!();
      } else {
        final raw =
            await Supabase.instance.client.rpc('customer_profile_tab');
        m = raw is Map ? Map<String, dynamic>.from(raw) : <String, dynamic>{};
      }
      if (!mounted) return;
      setState(() {
        _payload = m;
        _loading = false;
        _failed = m['ok'] != true;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _failed = _payload == null;
      });
    }
  }

  Future<void> _open(Map<String, dynamic> item) async {
    final route = (item['route_key'] ?? '').toString();
    final tab = (item['tab'] ?? '').toString();
    switch (ProfileTabAction.doorOf(item)) {
      case ProfileTabDoor.cart:
        widget.onOpenCart();
        break;
      case ProfileTabDoor.share:
        await _share();
        break;
      case ProfileTabDoor.logout:
        await UserState.read(context).signOut();
        // CMD #2144 — signOut() already replaced the whole stack with a fresh
        // public home; this tab's shell is gone, so there is nothing to steer.
        if (!mounted) return;
        // The public home, not the tab the shopper was standing on.
        widget.navigate('home');
        break;
      case ProfileTabDoor.myShop:
        final label = (item['label'] ?? '').toString();
        Navigator.of(context).push(MaterialPageRoute<void>(
          builder: (_) => Scaffold(
            backgroundColor: Ds.c.bg,
            appBar: AppBar(title: Text(label)),
            body: MyShopScreen(navigate: widget.navigate, active: true),
          ),
        ));
        break;
      case ProfileTabDoor.screen:
        final screen = customerMenuScreen(route, tab: tab);
        if (screen != null) {
          Navigator.of(context)
              .push(MaterialPageRoute<void>(builder: (_) => screen));
        }
        break;
      case ProfileTabDoor.shell:
        widget.navigate(route);
        break;
    }
  }

  Future<void> _share() async {
    final text = (_payload?['share_text'] ?? '').toString();
    if (text.isEmpty) return;
    try {
      await Share.share(text);
    } catch (_) {
      // A browser without the Web Share API: the link goes to the clipboard
      // and the backend's own sentence says so.
      await Clipboard.setData(ClipboardData(text: text));
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text((_payload?['share_copied'] ?? '').toString())));
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!_signedIn) return _SignedOut(onSignIn: _signIn);
    final p = _payload;
    if (_failed && (p == null || p['ok'] != true)) {
      return _ErrorState(onRetry: () {
        _loadedFor = null;
        _maybeLoad();
      });
    }
    if (p == null) return const _ProfileSkeleton();

    final sections = ProfileTabAction.sectionsOf(p);
    final header = Map<String, dynamic>.from((p['header'] as Map?) ?? const {});
    var rows = 0;
    for (final s in sections) {
      rows += ProfileTabAction.itemsOf(s).length;
    }
    RenderLog.write('c2125_profile_tab', 'sections=${sections.length}|rows=$rows');

    return RefreshIndicator(
      color: Ds.c.brand,
      onRefresh: _load,
      child: ListView(
        // CMD #2147 — the floating host hands down the pill + dock room.
        padding: EdgeInsets.only(
            bottom: MediaQuery.paddingOf(context).bottom + Ds.space.x16),
        children: [
          _Header(header: header),
          for (final s in sections)
            Padding(
              padding: EdgeInsets.fromLTRB(
                  Ds.space.x16, Ds.space.x12, Ds.space.x16, 0),
              child: _Section(section: s, onOpen: _open),
            ),
        ],
      ),
    );
  }

  void _signIn() {
    Navigator.of(context)
        .push(MaterialPageRoute<void>(builder: (_) => const LoginScreen()));
  }
}

// ─────────────────────────────── header ───────────────────────────────

class _Header extends StatelessWidget {
  final Map<String, dynamic> header;
  const _Header({required this.header});

  @override
  Widget build(BuildContext context) {
    final letter = (header['avatar_label'] ?? '').toString();
    final title = (header['title'] ?? '').toString();
    final subtitle = (header['subtitle'] ?? '').toString();
    final chip = Map<String, dynamic>.from((header['chip'] as Map?) ?? const {});
    final chipLabel = (chip['label'] ?? '').toString();
    final tone = _Tone.of((chip['tone'] ?? '').toString());
    return Container(
      color: Ds.c.surface,
      padding: EdgeInsets.fromLTRB(
          Ds.space.x16, Ds.space.x24, Ds.space.x16, Ds.space.x24),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Container(
            width: Ds.space.x48 + Ds.space.x16,
            height: Ds.space.x48 + Ds.space.x16,
            alignment: Alignment.center,
            decoration:
                BoxDecoration(color: Ds.c.brandSoft, shape: BoxShape.circle),
            child: Text(letter,
                style: Ds.t.title.copyWith(color: Ds.c.brand)),
          ),
          SizedBox(width: Ds.space.x16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (title.isNotEmpty)
                  Text(title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: Ds.t.title),
                if (subtitle.isNotEmpty) ...[
                  SizedBox(height: Ds.space.x4),
                  Text(subtitle, style: Ds.t.caption),
                ],
                if (chipLabel.isNotEmpty) ...[
                  SizedBox(height: Ds.space.x8),
                  Container(
                    padding: EdgeInsets.symmetric(
                        horizontal: Ds.space.x12, vertical: Ds.space.x4),
                    decoration: BoxDecoration(
                        color: tone.bg, borderRadius: Ds.r.rChip),
                    child: Text(chipLabel,
                        style: Ds.t.caption.copyWith(
                            color: tone.fg, fontWeight: FontWeight.w600)),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _Tone {
  final Color bg, fg;
  const _Tone(this.bg, this.fg);
  static _Tone of(String tone) => switch (tone) {
        'success' => _Tone(Ds.c.successSoft, Ds.c.success),
        'warning' => _Tone(Ds.c.warningSoft, Ds.c.warning),
        'danger' => _Tone(Ds.c.dangerSoft, Ds.c.danger),
        _ => _Tone(Ds.c.bg, Ds.c.textSecondary),
      };
}

// ─────────────────────────────── sections ─────────────────────────────

class _Section extends StatelessWidget {
  final Map<String, dynamic> section;
  final ValueChanged<Map<String, dynamic>> onOpen;
  const _Section({required this.section, required this.onOpen});

  @override
  Widget build(BuildContext context) {
    final items = ProfileTabAction.itemsOf(section);
    if (items.isEmpty) return const SizedBox.shrink();
    switch ((section['kind'] ?? '').toString()) {
      case 'tiles':
        return Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (var i = 0; i < items.length; i++) ...[
              if (i > 0) SizedBox(width: Ds.space.x12),
              Expanded(child: _Tile(item: items[i], onOpen: onOpen)),
            ],
          ],
        );
      case 'hero':
        return Column(children: [
          for (final it in items) _Hero(item: it, onOpen: onOpen),
        ]);
      default:
        final title = (section['title'] ?? '').toString();
        return _Card(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (title.isNotEmpty)
                Padding(
                  padding: EdgeInsets.fromLTRB(
                      Ds.space.x16, Ds.space.x16, Ds.space.x16, Ds.space.x8),
                  child: Text(title,
                      style: Ds.t.body.copyWith(fontWeight: FontWeight.w700)),
                ),
              for (var i = 0; i < items.length; i++) ...[
                if (i > 0 || title.isNotEmpty)
                  Divider(height: 1, thickness: 1, color: Ds.c.divider),
                _Row(item: items[i], onOpen: onOpen),
              ],
            ],
          ),
        );
    }
  }
}

class _Card extends StatelessWidget {
  final Widget child;
  const _Card({required this.child});

  @override
  Widget build(BuildContext context) => Container(
        decoration: BoxDecoration(
          color: Ds.c.surface,
          borderRadius: Ds.r.rCard,
          boxShadow: Ds.elevation.e1,
        ),
        clipBehavior: Clip.antiAlias,
        child: Material(color: Ds.c.surface, child: child),
      );
}

Widget _identified(Map<String, dynamic> item, Widget child) => Semantics(
      container: true,
      button: true,
      identifier: 'profile_row_${(item['feature_key'] ?? '').toString()}',
      child: child,
    );

class _Tile extends StatelessWidget {
  final Map<String, dynamic> item;
  final ValueChanged<Map<String, dynamic>> onOpen;
  const _Tile({required this.item, required this.onOpen});

  @override
  Widget build(BuildContext context) {
    return _identified(
      item,
      _Card(
        child: InkWell(
          onTap: () => onOpen(item),
          child: Padding(
            padding: EdgeInsets.symmetric(
                horizontal: Ds.space.x8, vertical: Ds.space.x16),
            child: Column(
              children: [
                Container(
                  width: Ds.space.x48,
                  height: Ds.space.x48,
                  decoration: BoxDecoration(
                      color: Ds.c.brandSoft, borderRadius: Ds.r.rButton),
                  child: Icon(navIcon((item['icon_key'] ?? '').toString()),
                      size: Ds.space.x24, color: Ds.c.brand),
                ),
                SizedBox(height: Ds.space.x8),
                Text((item['label'] ?? '').toString(),
                    maxLines: 2,
                    textAlign: TextAlign.center,
                    overflow: TextOverflow.ellipsis,
                    style: Ds.t.body.copyWith(fontWeight: FontWeight.w700)),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _Hero extends StatelessWidget {
  final Map<String, dynamic> item;
  final ValueChanged<Map<String, dynamic>> onOpen;
  const _Hero({required this.item, required this.onOpen});

  @override
  Widget build(BuildContext context) {
    final caption = (item['caption'] ?? '').toString();
    return _identified(
      item,
      Material(
        color: Ds.c.brandDark,
        borderRadius: Ds.r.rCard,
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: () => onOpen(item),
          child: Padding(
            padding: EdgeInsets.all(Ds.space.x16 + Ds.space.x4),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text((item['label'] ?? '').toString(),
                          style: Ds.t.subtitle.copyWith(
                              color: Ds.c.surface,
                              fontWeight: FontWeight.w700)),
                      if (caption.isNotEmpty) ...[
                        SizedBox(height: Ds.space.x4),
                        Text(caption,
                            style: Ds.t.caption.copyWith(
                                color: Ds.c.surface.withValues(alpha: 0.85))),
                      ],
                    ],
                  ),
                ),
                Icon(Icons.chevron_right,
                    size: Ds.space.x24, color: Ds.c.surface),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _Row extends StatelessWidget {
  final Map<String, dynamic> item;
  final ValueChanged<Map<String, dynamic>> onOpen;
  const _Row({required this.item, required this.onOpen});

  @override
  Widget build(BuildContext context) {
    final danger = (item['tone'] ?? '') == 'danger';
    final fg = danger ? Ds.c.danger : Ds.c.text;
    final badge = (item['badge'] ?? '').toString();
    return _identified(
      item,
      InkWell(
        onTap: () => onOpen(item),
        child: SizedBox(
          // One row height for every row on the tab (56 px).
          height: Ds.space.x48 + Ds.space.x8,
          child: Padding(
            padding: EdgeInsets.symmetric(horizontal: Ds.space.x16),
            child: Row(
              children: [
                Container(
                  width: Ds.space.x32,
                  height: Ds.space.x32,
                  decoration: BoxDecoration(
                    color: danger ? Ds.c.dangerSoft : Ds.c.bg,
                    borderRadius: Ds.r.rButton,
                  ),
                  child: Icon(navIcon((item['icon_key'] ?? '').toString()),
                      size: Ds.space.x16 + Ds.space.x4,
                      color: danger ? Ds.c.danger : Ds.c.textSecondary),
                ),
                SizedBox(width: Ds.space.x16),
                Expanded(
                  child: Text((item['label'] ?? '').toString(),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Ds.t.body.copyWith(color: fg)),
                ),
                if (badge.isNotEmpty) ...[
                  Container(
                    padding: EdgeInsets.symmetric(horizontal: Ds.space.x8),
                    decoration: BoxDecoration(
                        color: Ds.c.brandSoft, borderRadius: Ds.r.rChip),
                    child: Text(badge,
                        style: Ds.t.caption.copyWith(
                            color: Ds.c.brand, fontWeight: FontWeight.w600)),
                  ),
                  SizedBox(width: Ds.space.x8),
                ],
                Icon(Icons.chevron_right,
                    size: Ds.space.x16 + Ds.space.x4,
                    color: Ds.c.textSecondary),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ───────────────────────── loading · error · signed out ─────────────────────

class _ProfileSkeleton extends StatelessWidget {
  const _ProfileSkeleton();

  @override
  Widget build(BuildContext context) => Shimmer(
        child: ListView(
          padding: EdgeInsets.all(Ds.space.x16),
          children: [
            SkeletonBox(height: Ds.space.x48 + Ds.space.x32),
            SizedBox(height: Ds.space.x12),
            SkeletonBox(height: Ds.space.x48 + Ds.space.x48),
            SizedBox(height: Ds.space.x12),
            SkeletonBox(height: Ds.space.x48 + Ds.space.x24),
            SizedBox(height: Ds.space.x12),
            SkeletonBox(height: Ds.space.x48 * 5),
          ],
        ),
      );
}

class _ErrorState extends StatelessWidget {
  final VoidCallback onRetry;
  const _ErrorState({required this.onRetry});

  @override
  Widget build(BuildContext context) => Center(
        child: Padding(
          padding: EdgeInsets.all(Ds.space.x24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(c('profile_tab.error'),
                  textAlign: TextAlign.center, style: Ds.t.body),
              SizedBox(height: Ds.space.x16),
              OutlinedButton(
                  onPressed: onRetry, child: Text(c('profile_tab.retry'))),
            ],
          ),
        ),
      );
}

class _SignedOut extends StatelessWidget {
  final VoidCallback onSignIn;
  const _SignedOut({required this.onSignIn});

  @override
  Widget build(BuildContext context) {
    RenderLog.write('c2125_profile_tab', 'signed_out');
    return ListView(
      padding: EdgeInsets.all(Ds.space.x16),
      children: [
        _Card(
          child: Padding(
            padding: EdgeInsets.all(Ds.space.x24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(c('profile_tab.signed_out_title'), style: Ds.t.title),
                SizedBox(height: Ds.space.x8),
                Text(c('profile_tab.signed_out_caption'), style: Ds.t.caption),
                SizedBox(height: Ds.space.x24),
                Semantics(
                  identifier: 'profile_sign_in',
                  button: true,
                  child: SizedBox(
                    height: Ds.space.x48,
                    child: FilledButton(
                      onPressed: onSignIn,
                      child: Text(c('profile_tab.signed_out_button')),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}
