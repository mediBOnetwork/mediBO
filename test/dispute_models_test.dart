import 'package:flutter_test/flutter_test.dart';
import 'package:pharma_b2b/screens/admin/dispute/dispute_models.dart';

void main() {
  group('DisputeItem.fromJson', () {
    Map<String, dynamic> _item(String status, int actionCount, {
      String disputeStatus = 'active',
      bool unfillable = false,
    }) {
      final actions = List.generate(actionCount, (i) => {'code': 'code_$i', 'label': 'Label $i'});
      return {
        'dispute_id': 'uuid-$status',
        'order_item_id': 'oi-$status',
        'product_name': 'Test Product',
        'supplier': 'Test Supplier',
        'mode': 'reminder',
        'kind': 'short',
        'ordered': 10,
        'received': 7,
        'short': 3,
        'status': status,
        'item_status_label': 'Label for $status',
        'dispute_status': disputeStatus,
        'actions': actions,
        'unfillable': unfillable,
      };
    }

    // Per section 9.4: actions counts 3/2/2/1/0 for the five test statuses
    test('reminder_sent: 3 actions, active, label non-empty', () {
      final item = DisputeItem.fromJson(_item('reminder_sent', 3));
      expect(item.actions.length, 3);
      expect(item.isActive, true);
      expect(item.itemStatusLabel, isNotEmpty);
      expect(item.unfillable, false);
    });

    test('waiting_sort_qty: 2 actions, active', () {
      final item = DisputeItem.fromJson(_item('waiting_sort_qty', 2));
      expect(item.actions.length, 2);
      expect(item.isActive, true);
    });

    test('missing_dispute: 2 actions, active', () {
      final item = DisputeItem.fromJson(_item('missing_dispute', 2));
      expect(item.actions.length, 2);
      expect(item.isActive, true);
    });

    test('reinquiry: 1 action, active', () {
      final item = DisputeItem.fromJson(_item('reinquiry', 1));
      expect(item.actions.length, 1);
      expect(item.isActive, true);
    });

    test('missing_arrived: 0 actions, closed', () {
      final item = DisputeItem.fromJson(_item('missing_arrived', 0, disputeStatus: 'closed'));
      expect(item.actions.length, 0);
      expect(item.isActive, false);
    });

    test('unfillable defaults false when absent', () {
      final j = {
        'dispute_id': 'x', 'product_name': 'P', 'status': 'reinquiry',
        'item_status_label': 'L', 'dispute_status': 'active',
        'actions': <dynamic>[],
      };
      final item = DisputeItem.fromJson(j);
      expect(item.unfillable, false);
    });

    test('null-safe: all fields missing', () {
      final item = DisputeItem.fromJson({});
      expect(item.productName, '');
      expect(item.itemStatusLabel, '');
      expect(item.actions, isEmpty);
      expect(item.unfillable, false);
    });

    test('listFromResponse throws DisputeException on error', () {
      expect(
        () => DisputeItem.listFromResponse({'error': 'not_authorized'}),
        throwsA(isA<DisputeException>()),
      );
    });

    test('listFromResponse parses ok response', () {
      final response = {
        'status': 'ok',
        'disputes': [
          {
            'dispute_id': 'a', 'product_name': 'X', 'status': 'reminder_sent',
            'item_status_label': 'Awaiting supplier response',
            'dispute_status': 'active',
            'actions': [{'code': 'admin_got', 'label': 'Got the missing qty'}],
          }
        ],
      };
      final items = DisputeItem.listFromResponse(response);
      expect(items.length, 1);
      expect(items.first.actions.first.code, 'admin_got');
    });
  });

  // ── #189 supplier screen tests (Section 8.2(d)) ───────────────────────────
  group('SupplierDisputesResult / supplier_my_disputes contract', () {
    Map<String, dynamic> _supplierItem({
      required String status,
      required int supplierActionCount,
      required int adminActionCount,
      String disputeStatus = 'active',
    }) {
      return {
        'dispute_id': 'uuid-$status',
        'order_item_id': 'oi-$status',
        'product_name': 'Test Product $status',
        'supplier': 'Test Supplier',
        'mode': 'reminder',
        'kind': 'short',
        'ordered': 10,
        'received': 7,
        'short': 3,
        'status': status,
        'item_status_label': 'Label $status',
        'dispute_status': disputeStatus,
        'actions': List.generate(supplierActionCount,
            (i) => {'code': 'sup_$i', 'label': 'Supplier Action $i'}),
        'admin_actions': List.generate(adminActionCount,
            (i) => {'code': 'adm_$i', 'label': 'Admin Action $i'}),
      };
    }

    // reminder_sent: 2 supplier actions + 3 admin actions
    test('reminder_sent: 2 supplier actions, 3 admin actions, active', () {
      final item = DisputeItem.fromJson(
          _supplierItem(status: 'reminder_sent', supplierActionCount: 2, adminActionCount: 3));
      expect(item.actions.length, 2);
      expect(item.adminActions.length, 3);
      expect(item.isActive, true);
    });

    // waiting_sort_qty: 0 supplier actions, 2 admin actions
    test('waiting_sort_qty: 0 supplier actions, 2 admin actions, active', () {
      final item = DisputeItem.fromJson(
          _supplierItem(status: 'waiting_sort_qty', supplierActionCount: 0, adminActionCount: 2));
      expect(item.actions.length, 0);
      expect(item.adminActions.length, 2);
      expect(item.isActive, true);
    });

    // missing_dispute: 0 supplier actions, 2 admin actions
    test('missing_dispute: 0 supplier actions, 2 admin actions, active', () {
      final item = DisputeItem.fromJson(
          _supplierItem(status: 'missing_dispute', supplierActionCount: 0, adminActionCount: 2));
      expect(item.actions.length, 0);
      expect(item.adminActions.length, 2);
      expect(item.isActive, true);
    });

    // reinquiry: 0 supplier actions, 1 admin action
    test('reinquiry: 0 supplier actions, 1 admin action, active', () {
      final item = DisputeItem.fromJson(
          _supplierItem(status: 'reinquiry', supplierActionCount: 0, adminActionCount: 1));
      expect(item.actions.length, 0);
      expect(item.adminActions.length, 1);
      expect(item.isActive, true);
    });

    // closed: 0 supplier actions, 0 admin actions
    test('closed: 0 supplier actions, 0 admin actions, inactive', () {
      final item = DisputeItem.fromJson(_supplierItem(
          status: 'missing_arrived',
          supplierActionCount: 0,
          adminActionCount: 0,
          disputeStatus: 'closed'));
      expect(item.actions.length, 0);
      expect(item.adminActions.length, 0);
      expect(item.isActive, false);
    });

    // SupplierDisputesResult wrapper parses correctly
    test('SupplierDisputesResult: parses supplier + acting + items', () {
      final result = SupplierDisputesResult(
        supplier: 'Test Supplier',
        acting: true,
        items: [
          DisputeItem.fromJson(_supplierItem(
              status: 'reminder_sent', supplierActionCount: 2, adminActionCount: 3)),
        ],
      );
      expect(result.supplier, 'Test Supplier');
      expect(result.acting, true);
      expect(result.items.length, 1);
      expect(result.items.first.adminActions.length, 3);
    });
  });
}
