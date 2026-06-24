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
}
