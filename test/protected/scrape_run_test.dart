// CMD #1870 — the scrape run's two decisions, held down.
//
// What broke before this test existed:
//   * "Delete this run" hard-DELETEd the leads, and the checkbox that decided
//     whether to was a client-side choice. Delete is now one archive call with
//     no options, and every word of the confirmation is the backend's.
//   * The Include chips only chose what was SEARCHED, and Dart resolved them
//     into ui_types before calling. Flutter now sends the chip keys and
//     nothing else — if this file starts computing Google types again, the
//     hard filter in lead_scrape_finish_cell() is being fed a guess.

import 'package:flutter_test/flutter_test.dart';
import 'package:pharma_b2b/screens/admin/scrape_run.dart';

Map<String, dynamic> _run({
  Object? keptDropped = '12 kept · 3 dropped by your chips',
  Object? canDelete,
  Object? delete = const {
    'label': 'Delete this run',
    'title': 'Delete this scrape run?',
    'body': 'Its 12 leads move to Archived. Restore them from the Archived '
        'filter within 30 days.',
    'ok': 'Delete run',
    'cancel': 'Cancel',
    'count': 12,
  },
}) =>
    {
      'run_id': 'r-1',
      'city': 'Raipur',
      'status': 'done',
      'types_label': 'medical',
      'summary_label': '12 new · 12 found · 40 API calls',
      'kept_dropped_label': keptDropped,
      'error': null,
      if (canDelete != null) 'can_delete': canDelete,
      'delete': delete,
    };

void main() {
  group('ScrapeRunView — the card prints, it does not decide', () {
    test('every caption is the backend string, verbatim', () {
      final v = ScrapeRunView.from(_run());
      expect(v.runId, 'r-1');
      expect(v.city, 'Raipur');
      expect(v.typesLabel, 'medical');
      expect(v.summaryLabel, '12 new · 12 found · 40 API calls');
      expect(v.keptDroppedLabel, '12 kept · 3 dropped by your chips');
      expect(v.error, isNull);
    });

    test('the kept/dropped line is absent, not zeroed, when none was sent', () {
      expect(ScrapeRunView.from(_run(keptDropped: null)).keptDroppedLabel, isNull);
      expect(ScrapeRunView.from(_run(keptDropped: '')).keptDroppedLabel, isNull);
      // A run from before the filter existed must not grow a Dart-made
      // "0 kept · 0 dropped".
      final legacy = Map<String, dynamic>.from(_run())..remove('kept_dropped_label');
      expect(ScrapeRunView.from(legacy).keptDroppedLabel, isNull);
    });

    test('the whole confirmation — count included — comes from the payload', () {
      final d = ScrapeRunView.from(_run()).delete!;
      expect(d.label, 'Delete this run');
      expect(d.title, 'Delete this scrape run?');
      expect(d.body, contains('12 leads move to Archived'));
      expect(d.body, contains('30 days'));
      expect(d.ok, 'Delete run');
      expect(d.cancel, 'Cancel');
      expect(d.count, 12);
    });

    test('the singular/plural body is the backend\'s sentence, not a Dart if', () {
      final one = ScrapeRunView.from(_run(delete: const {
        'label': 'Delete this run',
        'title': 'Delete this scrape run?',
        'body': 'Its 1 lead moves to Archived. Restore it from the Archived '
            'filter within 30 days.',
        'ok': 'Delete run',
        'cancel': 'Cancel',
        'count': 1,
      }));
      expect(one.delete!.body, startsWith('Its 1 lead moves'));
      expect(one.delete!.count, 1);
    });

    test('no action when the backend withholds it', () {
      expect(ScrapeRunView.from(_run(canDelete: false)).canDelete, isFalse);
      expect(ScrapeRunView.from(_run(delete: null)).canDelete, isFalse);
      // A block with no caption is not an action either.
      expect(
          ScrapeRunView.from(_run(delete: const {'count': 3})).canDelete, isFalse);
      // ...and the default row is deletable.
      expect(ScrapeRunView.from(_run()).canDelete, isTrue);
    });
  });

  group('ScrapeStartArgs — Flutter sends the chips and nothing else', () {
    test('the trays go out as chip keys; no Google type is computed here', () {
      final a = ScrapeStartArgs.fromTrays(
        name: '  Raipur ',
        level: 'city',
        include: {'medical', 'medical_general'},
        exclude: {'hospital'},
        maxCalls: 800,
      );
      expect(a.toParams(), {
        'p_name': 'Raipur',
        'p_level': 'city',
        'p_include': ['medical', 'medical_general'],
        'p_exclude': ['hospital'],
        'p_cell_km': null,
        'p_max_calls': 800,
      });
      // The old p_ui_types parameter is gone: sending it would mean Dart had
      // resolved the categories again.
      expect(a.toParams().containsKey('p_ui_types'), isFalse);
    });

    test('the same selection always produces the same call', () {
      final a = ScrapeStartArgs.fromTrays(
          name: 'Raipur',
          level: 'city',
          include: {'b', 'a'},
          exclude: {'z', 'y'},
          maxCalls: 50);
      final b = ScrapeStartArgs.fromTrays(
          name: 'Raipur',
          level: 'city',
          include: {'a', 'b'},
          exclude: {'y', 'z'},
          maxCalls: 50);
      expect(a.toParams().toString(), b.toParams().toString());
      expect(a.include, ['a', 'b']);
      expect(a.exclude, ['y', 'z']);
    });

    test('a chip cannot be included and excluded at once', () {
      final a = ScrapeStartArgs.fromTrays(
        name: 'Raipur',
        level: 'district',
        include: {'medical'},
        exclude: {'medical', 'hospital'},
        maxCalls: 800,
      );
      expect(a.include, ['medical']);
      expect(a.exclude, ['hospital']);
    });

    test('an empty tray is sent empty — never a default category', () {
      final a = ScrapeStartArgs.fromTrays(
          name: 'Raipur',
          level: 'city',
          include: {},
          exclude: {},
          maxCalls: 800);
      expect(a.toParams()['p_include'], isEmpty);
      expect(a.toParams()['p_exclude'], isEmpty);
    });
  });
}
