// CHANGE #657 — ONE interface means the SAME nav, not a stripped one.
//
// #653 collapsed super admin, admin and partner into one shell. #657 deleted the
// last client-side partner branch, and the first partner login through the
// shared shell arrived with a bottom bar holding a single tab: Dashboard. The
// five containers are gated on admin.dashboard / admin.whatsapp /
// admin.customers / admin.suppliers / admin.fulfillment, and a partner's grants
// are named partner.pack, partner.inquiry, partner.collect… — so the matrix
// hid every door to the work she has full write access to.
//
// Two things fix that, and this file pins both:
//   1. The partner ROLE DEFAULT now carries View on the five containers, so the
//      interface is identical. Write is NOT granted by that default — what she
//      may change is still the per-feature matrix's answer.
//   2. Opening a container must not hand over its contents. The supplier and
//      customer screens already ask Access.tabCanView per tab; the fulfilment
//      screen is addressed by tab NUMBER, so the matrix derives that set here.
//      Unbounded (null) is returned only when the matrix has not resolved or
//      every tab is granted — so a full admin is never narrowed by this.
import 'package:flutter_test/flutter_test.dart';
import 'package:pharma_b2b/services/access.dart';

AccessTab _tab(String key, int index, {bool v = true, bool w = true}) =>
    AccessTab(
        tabKey: key,
        label: key,
        featureKey: 'partner.$key',
        canView: v,
        canWrite: w,
        index: index);

/// The live access_boot() shape for the partner of Jai Mahakal: full write on
/// every fulfilment stage, view-only on the supplier list.
AccessMatrix _partnerMatrix({List<AccessTab>? fulfillment}) => AccessMatrix(
      resolved: true,
      role: 'partner',
      zoneLocked: true,
      zoneLabel: 'Raipur Zone',
      features: const {
        'admin.dashboard': FeatureAccess(canView: true, canWrite: false),
        'admin.whatsapp': FeatureAccess(canView: true, canWrite: false),
        'admin.customers': FeatureAccess(canView: true, canWrite: false),
        'admin.suppliers': FeatureAccess(canView: true, canWrite: false),
        'admin.fulfillment': FeatureAccess(canView: true, canWrite: false),
        'partner.pack': FeatureAccess(canView: true, canWrite: true),
      },
      routeFeature: const {
        'dashboard': 'admin.dashboard',
        'whatsapp': 'admin.whatsapp',
        'customers': 'admin.customers',
        'suppliers': 'admin.suppliers',
        'fulfillment': 'admin.fulfillment',
      },
      tabs: {
        'fulfillment': fulfillment ??
            [
              _tab('collect', 0),
              _tab('count', 1),
              _tab('bag_mapping', 2),
              _tab('pack', 3),
              _tab('disputes', 4),
              _tab('assign_delivery', 5),
            ],
      },
    );

void main() {
  group('the nav a partner sees is the nav an admin sees', () {
    test('all five containers are viewable', () {
      final m = _partnerMatrix();
      for (final route in const [
        'dashboard',
        'whatsapp',
        'customers',
        'suppliers',
        'fulfillment',
      ]) {
        expect(m.routeCanView(route), isTrue, reason: route);
      }
    });

    test('View on a container is not Write on it', () {
      // The identical interface is a VIEW grant. A partner opening WhatsApp
      // must not thereby be able to send from it.
      final m = _partnerMatrix();
      expect(m.routeCanWrite('whatsapp'), isFalse);
      expect(m.routeCanWrite('customers'), isFalse);
      expect(m.canWrite('partner.pack'), isTrue);
    });

    test('a container the matrix genuinely denies is still hidden', () {
      // The fix is a grant, not the removal of gating.
      final m = AccessMatrix(
        resolved: true,
        features: const {
          'admin.dashboard': FeatureAccess(canView: true, canWrite: false),
        },
        routeFeature: const {
          'dashboard': 'admin.dashboard',
          'whatsapp': 'admin.whatsapp',
        },
      );
      expect(m.routeCanView('dashboard'), isTrue);
      expect(m.routeCanView('whatsapp'), isFalse);
    });
  });

  group('opening a container does not hand over its contents', () {
    test('every tab granted is UNBOUNDED — a full admin is never narrowed', () {
      expect(_partnerMatrix().allowedTabIndexes('fulfillment'), isNull);
    });

    test('a partial grant becomes the backend own tab numbers', () {
      final m = _partnerMatrix(fulfillment: [
        _tab('collect', 0, v: false, w: false),
        _tab('count', 1),
        _tab('bag_mapping', 2, v: false, w: false),
        _tab('pack', 3),
        _tab('disputes', 4, v: false, w: false),
        _tab('assign_delivery', 5),
      ]);
      // The NUMBERS are partner_screen_tab.tab_index, not the position of the
      // entry in this list — a tab that moves must not re-map a grant.
      expect(m.allowedTabIndexes('fulfillment'), {1, 3, 5});
    });

    test('a tab with no index from the backend is never guessed at', () {
      final m = _partnerMatrix(fulfillment: [
        _tab('collect', 0, v: false, w: false),
        const AccessTab(
            tabKey: 'pack',
            label: 'Pack',
            featureKey: 'partner.pack',
            canView: true,
            canWrite: true),
      ]);
      expect(m.allowedTabIndexes('fulfillment'), isEmpty);
    });

    test('an unresolved matrix and an unknown screen are both unbounded', () {
      expect(AccessMatrix.unresolved.allowedTabIndexes('fulfillment'), isNull);
      expect(_partnerMatrix().allowedTabIndexes('nothing_like_this'), isNull);
    });
  });
}
