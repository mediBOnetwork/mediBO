import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../design_tokens.dart';
import '../../services/customer_surfaces.dart';
import '../../services/ui_copy.dart';
import '../../user_state.dart';
import '../../widgets/delete_account_section.dart';
import '../admin/loyalty_admin_screen.dart';
import '../admin/nav_registry_view.dart' show navIcon, navIconResolves;
import '../orders_screen.dart';
import '../rewards_screen.dart';
import '../wishlist_screen.dart';
import 'address_book_screen.dart';
import 'customer_staff_screen.dart';
import 'my_account_screen.dart';

/// CHANGE #745 — the screen a customer `route_key` opens.
///
/// The ONE thing that cannot live in Postgres: a Dart class is not data. Every
/// other property of a menu entry — its label, its caption, its icon, its
/// order, the surface it appears on, whether the caller is offered it at all —
/// arrives from `customer_surfaces()`. A route this build has never heard of
/// resolves to null, and the caller skips it in silence rather than throwing:
/// a registry row that ships before its screen must not break the menu.
Widget? customerMenuScreen(String routeKey) => switch (routeKey) {
      // CHANGE #840 — the account page. Every other row below is also a tab
      // INSIDE it; they stay routable because the registry, not this file,
      // decides where a customer reaches them from.
      'cust_account' => const MyAccountScreen(),
      'cust_orders' => const OrdersScreen(),
      // CMD #1815 — there is ONE profile screen. The old Edit profile screen is
      // gone; a registry row (or an older payload) still naming it lands on the
      // tab that now holds the editor.
      'cust_profile_edit' =>
        const MyAccountScreen(initialTab: 'profile', initialSection: 'profile'),
      'cust_addresses' => const AddressBookScreen(),
      'cust_staff_logins' => const CustomerStaffScreen(),
      'cust_loyalty_admin' => const LoyaltyAdminScreen(),
      'cust_wishlist' => const WishlistScreen(),
      'cust_rewards' => const RewardsScreen(),
      _ => null,
    };

/// The Account group on My Profile, rendered verbatim from the backend.
///
/// Nothing here decides what belongs in a pharmacy's profile. The list is
/// `placements.profile_account`, in the backend's order, and `render_kind`
/// picks the shape: a `row` is a tappable card, `action` is the neutral Logout
/// button, `danger_zone` is the collapsed delete section that must stay last.
/// Wishlist and Rewards are absent because their placement rows moved, not
/// because Dart stopped drawing them.
class ProfileAccountMenu extends StatelessWidget {
  /// False in View As mode: an operator looking at a customer's profile must
  /// not be offered that customer's logout or delete button.
  final bool interactive;

  const ProfileAccountMenu({super.key, this.interactive = true});

  /// True while what is on screen came off the device rather than the network.
  /// The WORDS are still the backend's — this only decides whether to say them.
  static bool _isStale(Map<String, dynamic> payload) =>
      payload.isNotEmpty && !CustomerSurfaces.isLive;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<Map<String, dynamic>>(
      valueListenable: CustomerSurfaces.value,
      builder: (context, payload, _) {
        final items = CustomerSurfaces.itemsFor(payload, 'profile_account');
        final children = <Widget>[];
        var hasLogout = false;
        for (final e in items) {
          final kind = (e['render_kind'] ?? 'row').toString();
          final route = (e['route_key'] ?? '').toString();
          final label = (e['label'] ?? '').toString();
          if (label.isEmpty) continue;
          switch (kind) {
            case 'action':
              hasLogout = true;
              if (interactive) children.add(_LogoutButton(label: label));
              break;
            case 'danger_zone':
              if (interactive) children.add(const _DeleteZone());
              break;
            default:
              final screen = customerMenuScreen(route);
              if (screen == null) break; // forward compat: skip, never throw
              children.add(_MenuRow(
                label: label,
                iconKey: (e['icon_key'] ?? '').toString(),
                onTap: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(builder: (_) => screen)),
              ));
          }
        }
        // Hostile QA round 1, blocker 1: a signed-in account that the payload
        // does not describe — no pharmacy row yet, a role the customer menu
        // does not admit, or a first boot the RPC never answered — still has to
        // be able to SIGN OUT. Signing out is not a pharmacy feature and it is
        // the one affordance a wrong-account login needs; before #745 it was an
        // unconditional button and it must not become conditional now. The word
        // is still the backend's (ui_copy, cached at boot), never a Dart
        // literal, and it is only added when the payload did not already carry
        // its own Logout entry.
        if (interactive && !hasLogout) {
          children.add(_LogoutButton(label: c('profile.btn_logout')));
        }
        if (children.isEmpty) return const SizedBox.shrink();
        // Round 2 QA, NEW-2: the payload already carried the group's heading
        // and the sentence that tells a customer they are looking at the last
        // saved menu, and nothing rendered either — a backend string nobody
        // draws is the same defect as a Dart string nobody can change.
        final title = (payload['account_title'] ?? '').toString();
        final stale = _isStale(payload)
            ? (payload['offline_note'] ?? '').toString()
            : '';
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (title.isNotEmpty)
              Padding(
                padding: EdgeInsets.fromLTRB(
                    Ds.space.x16, Ds.space.x24, Ds.space.x16, Ds.space.x4),
                child: Text(title,
                    style: Ds.t.subtitle.copyWith(fontWeight: FontWeight.w700)),
              ),
            if (stale.isNotEmpty)
              Padding(
                padding: EdgeInsets.fromLTRB(
                    Ds.space.x16, 0, Ds.space.x16, Ds.space.x4),
                child: Text(stale,
                    style: Ds.t.caption.copyWith(color: Ds.c.textSecondary)),
              ),
            ...children,
          ],
        );
      },
    );
  }
}

/// The Account setup card — Payment term and Customer code.
///
/// Read-only by design, and every string is the backend's: the value, its
/// label, and the words shown when a field is genuinely not set. The em-dash
/// this screen used to print was written in Dart over a NULL column; `has`
/// is the backend saying which of the two it is.
class AccountSetupCard extends StatelessWidget {
  const AccountSetupCard({super.key});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<Map<String, dynamic>>(
      valueListenable: CustomerSurfaces.value,
      builder: (context, payload, _) {
        final setup = CustomerSurfaces.block(payload, 'account_setup');
        final rows = (setup['rows'] as List?) ?? const [];
        if (rows.isEmpty) return const SizedBox.shrink();
        final title = (setup['title'] ?? '').toString();
        return Container(
          margin: EdgeInsets.fromLTRB(
              Ds.space.x16, Ds.space.x16, Ds.space.x16, 0),
          decoration: BoxDecoration(
            color: Ds.c.surface,
            borderRadius: Ds.r.rCard,
            border: Border.all(color: Ds.c.divider),
            boxShadow: Ds.elevation.e1,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (title.isNotEmpty)
                Padding(
                  padding: EdgeInsets.fromLTRB(Ds.space.x16, Ds.space.x16,
                      Ds.space.x16, Ds.space.x8),
                  child: Text(title,
                      style: Ds.t.subtitle.copyWith(fontWeight: FontWeight.w700)),
                ),
              for (var i = 0; i < rows.length; i++)
                _SetupRow(
                  row: Map<String, dynamic>.from(rows[i] as Map),
                  isLast: i == rows.length - 1,
                ),
            ],
          ),
        );
      },
    );
  }
}

class _SetupRow extends StatelessWidget {
  final Map<String, dynamic> row;
  final bool isLast;
  const _SetupRow({required this.row, required this.isLast});

  @override
  Widget build(BuildContext context) {
    final has = row['has'] == true;
    final iconKey = (row['icon_key'] ?? '').toString();
    return Column(
      children: [
        Padding(
          padding: EdgeInsets.symmetric(
              horizontal: Ds.space.x16, vertical: Ds.space.x12),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (navIconResolves(iconKey)) ...[
                Icon(navIcon(iconKey), size: 18, color: Ds.c.textSecondary),
                SizedBox(width: Ds.space.x12),
              ],
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text((row['label'] ?? '').toString(),
                        style: Ds.t.caption.copyWith(color: Ds.c.textSecondary)),
                    SizedBox(height: Ds.space.x4),
                    Text(
                      (row['value'] ?? '').toString(),
                      style: Ds.t.body.copyWith(
                        fontWeight: FontWeight.w600,
                        color: has ? Ds.c.text : Ds.c.textSecondary,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        if (!isLast) Divider(height: 1, color: Ds.c.divider),
      ],
    );
  }
}

class _MenuRow extends StatelessWidget {
  final String label;
  final String iconKey;
  final VoidCallback onTap;
  const _MenuRow(
      {required this.label, required this.iconKey, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding:
          EdgeInsets.fromLTRB(Ds.space.x16, Ds.space.x8, Ds.space.x16, 0),
      child: InkWell(
        onTap: onTap,
        borderRadius: Ds.r.rCard,
        child: Container(
          constraints: BoxConstraints(minHeight: Ds.touch.listRowMinHeight),
          padding: EdgeInsets.symmetric(
              horizontal: Ds.space.x16, vertical: Ds.space.x16),
          decoration: BoxDecoration(
            color: Ds.c.surface,
            borderRadius: Ds.r.rCard,
            border: Border.all(color: Ds.c.divider),
            boxShadow: Ds.elevation.e1,
          ),
          child: Row(
            children: [
              Icon(navIcon(iconKey), size: 22, color: Ds.c.brand),
              SizedBox(width: Ds.space.x12),
              Expanded(
                child: Text(label,
                    style: Ds.t.body.copyWith(fontWeight: FontWeight.w600)),
              ),
              Icon(Icons.chevron_right, size: 20, color: Ds.c.textSecondary),
            ],
          ),
        ),
      ),
    );
  }
}

/// Logout — a normal action, kept neutral (never red) and always ABOVE the
/// delete zone, so a tap meant for one can never land on the other.
class _LogoutButton extends StatelessWidget {
  final String label;
  const _LogoutButton({required this.label});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.fromLTRB(
          Ds.space.x16, Ds.space.x16, Ds.space.x16, Ds.space.x8),
      child: OutlinedButton.icon(
        onPressed: () async {
          await UserState.read(context).signOut();
          if (context.mounted) {
            Navigator.of(context).popUntil((r) => r.isFirst);
          }
        },
        icon: Icon(Icons.logout, size: 18, color: Ds.c.textSecondary),
        label: Text(label),
        style: OutlinedButton.styleFrom(
          foregroundColor: Ds.c.textSecondary,
          side: BorderSide(color: Ds.c.divider),
          shape: RoundedRectangleBorder(borderRadius: Ds.r.rButton),
          minimumSize: Size.fromHeight(Ds.touch.minTarget),
        ),
      ),
    );
  }
}

class _DeleteZone extends StatelessWidget {
  const _DeleteZone();

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        SizedBox(height: Ds.space.x8),
        DeleteAccountSection(
          rpc: (scope, reason) async {
            final raw = await Supabase.instance.client.rpc(
              'request_account_deletion',
              params: {'p_scope': scope, 'p_reason': reason},
            );
            return Map<String, dynamic>.from(
                (raw is List ? raw.first : raw) as Map);
          },
        ),
        SizedBox(height: Ds.space.x32),
      ],
    );
  }
}
