// cmd #433 — the monthly cloud waste card computes NOTHING.
//
// The card exists to report money, and the one way a money report goes wrong is
// by inventing a number or a reassurance the backend never sent. These tests
// pin the two failures that would matter:
//
//   1. every rupee, label, heading and empty state is printed VERBATIM from the
//      payload — the card never sums a group, never formats a ₹, never
//      pluralises anything;
//   2. a group the scan was NOT ALLOWED to read is never painted as a clean
//      bill. `blocked` comes from the backend and the refusal sentence is what
//      shows, because "no unattached disks" when we were denied
//      ec2:DescribeVolumes is a lie that costs real money to believe.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:pharma_b2b/screens/admin/dev_queue/dev_queue_waste_card.dart';
import 'package:pharma_b2b/utils/render_log.dart';

Widget _host(Map<String, dynamic> waste, {VoidCallback? onScan}) => MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child: DevQueueWasteCard(
            waste: waste,
            busy: false,
            onScan: onScan ?? () {},
          ),
        ),
      ),
    );

Map<String, dynamic> _group({
  required String key,
  required String title,
  List<Map<String, dynamic>> rows = const [],
  bool blocked = false,
  String? note,
  required String emptyLabel,
  required String subtotal,
}) =>
    {
      'key': key,
      'title': title,
      'rows': rows,
      'blocked': blocked,
      'note': note,
      'empty_label': emptyLabel,
      'subtotal_display': subtotal,
    };

void main() {
  setUpAll(() => RenderLog.flushEnabled = false);

  testWidgets('never scanned renders the backend empty state, no groups',
      (t) async {
    await t.pumpWidget(_host({
      'title': 'Unused cloud resources',
      'subtitle': 'Read-only scan. Nothing is ever deleted by it.',
      'button': 'Scan now',
      'has': false,
      'empty_label': 'Not scanned yet.',
      'groups': const [],
    }));

    expect(find.text('Unused cloud resources'), findsOneWidget);
    expect(find.text('Not scanned yet.'), findsOneWidget);
    // No result furniture at all before a first scan.
    expect(find.textContaining('/month'), findsNothing);
  });

  testWidgets('totals and amounts print verbatim — Dart adds nothing up',
      (t) async {
    await t.pumpWidget(_host({
      'title': 'Unused cloud resources',
      'subtitle': 'sub',
      'button': 'Scan now',
      'has': true,
      'ran_label': 'Scanned 01 Sep, 03:30 AM · AWS ap-south-1',
      // Deliberately NOT the sum of the rows: if the card ever computed the
      // total itself this test would go green on the wrong number.
      'total_display': '₹9,999/month if all of it were removed',
      'footer': 'Nothing was deleted.',
      'groups': [
        _group(
          key: 'disks',
          title: 'Unattached disks',
          subtotal: '₹800/mo',
          emptyLabel: 'No unattached disks.',
          rows: const [
            {
              'label': 'vol-0abc · 100 GB · ap-south-1a',
              'amount_display': '₹800/mo',
              'copy_text': 'vol-0abc',
            },
          ],
        ),
      ],
    }));

    expect(find.text('₹9,999/month if all of it were removed'), findsOneWidget);
    expect(find.text('Scanned 01 Sep, 03:30 AM · AWS ap-south-1'), findsOneWidget);
    expect(find.text('vol-0abc · 100 GB · ap-south-1a'), findsOneWidget);
    // The row amount and the group subtotal are two separate backend strings.
    expect(find.text('₹800/mo'), findsNWidgets(2));
    expect(find.text('Nothing was deleted.'), findsOneWidget);
  });

  testWidgets('a blocked group shows the refusal, never a clean bill',
      (t) async {
    await t.pumpWidget(_host({
      'title': 'Unused cloud resources',
      'subtitle': 'sub',
      'button': 'Scan now',
      'has': true,
      'total_display': 'Nothing reclaimable found — ₹0/month',
      'footer': 'Nothing was deleted.',
      'blocked': 'Add ec2:DescribeVolumes to the IAM policy, then scan again.',
      'groups': [
        _group(
          key: 'disks',
          title: 'Unattached disks',
          blocked: true,
          subtotal: '₹0/mo',
          // The backend already swapped the empty state for the refusal; the
          // card must print THAT and must not fall back to a reassuring line.
          emptyLabel: 'Cannot read this — the saved AWS key is missing '
              'ec2:DescribeVolumes.',
        ),
      ],
    }));

    expect(
        find.text('Cannot read this — the saved AWS key is missing '
            'ec2:DescribeVolumes.'),
        findsOneWidget);
    expect(find.textContaining('No unattached disks'), findsNothing);
    expect(
        find.text('Add ec2:DescribeVolumes to the IAM policy, then scan again.'),
        findsOneWidget);
  });

  testWidgets('groups render in payload order and an empty group keeps its own '
      'backend empty state', (t) async {
    await t.pumpWidget(_host({
      'title': 'Unused cloud resources',
      'subtitle': 'sub',
      'button': 'Scan now',
      'has': true,
      'total_display': '₹0/month',
      'footer': 'f',
      'groups': [
        _group(
          key: 'ips',
          title: 'Reserved but unused IP addresses',
          subtotal: '₹0/mo',
          emptyLabel: 'No idle IP addresses.',
        ),
        _group(
          key: 'buckets',
          title: 'Buckets worth reviewing',
          subtotal: '₹0/mo',
          note: 'Storage is 5.7 GB of the 100 GB included in the plan.',
          emptyLabel: 'No orphan buckets.',
          rows: const [
            {
              'label': 'app-assets · empty, never used',
              'amount_display': '₹0/mo',
              'copy_text': 'app-assets',
            },
          ],
        ),
      ],
    }));

    final ips = t.getTopLeft(find.text('Reserved but unused IP addresses')).dy;
    final buckets = t.getTopLeft(find.text('Buckets worth reviewing')).dy;
    expect(ips, lessThan(buckets), reason: 'payload order, not a client sort');

    expect(find.text('No idle IP addresses.'), findsOneWidget);
    expect(find.text('app-assets · empty, never used'), findsOneWidget);
    expect(find.text('Storage is 5.7 GB of the 100 GB included in the plan.'),
        findsOneWidget);
  });

  testWidgets('Scan now is one tap on a real 44px target', (t) async {
    var taps = 0;
    await t.pumpWidget(_host({
      'title': 'Unused cloud resources',
      'subtitle': 'sub',
      'button': 'Scan now',
      'has': false,
      'empty_label': 'Not scanned yet.',
      'groups': const [],
    }, onScan: () => taps++));

    expect(t.getSize(find.byType(OutlinedButton)).height,
        greaterThanOrEqualTo(44.0));
    await t.tap(find.text('Scan now'));
    expect(taps, 1);
  });
}
