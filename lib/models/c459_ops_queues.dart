/// CHANGE #459 — the Ops queues payload, parsed and nothing more.
///
/// `admin_ops_queues()` returns `sections[]` in RENDER ORDER, each with its own
/// `layout`. This file computes NOTHING: no sorting, no counting, no wording,
/// no tone decisions. It only turns the payload into typed rows and drops a
/// section whose layout this build has never heard of, so a queue added in SQL
/// tomorrow cannot crash a build shipped today.
library;

/// A single row inside a queue section. Every field is a backend string.
class OpsRow {
  final String id;
  final String title;
  final String subtitle;
  final String ageLabel;
  final String stateLabel;
  final String stateTone;
  final String qtyLabel;
  final String nextLabel;
  final String askLabel;
  final String quietLabel;
  final String attemptsLabel;
  final String ordersLabel;
  final String sourceLabel;
  final bool canResend;
  final bool canRescan;
  final bool canAck;
  final String resendLabel;
  final String rescanLabel;
  final String closeLabel;
  final String ackLabel;

  const OpsRow({
    required this.id,
    required this.title,
    this.subtitle = '',
    this.ageLabel = '',
    this.stateLabel = '',
    this.stateTone = 'info',
    this.qtyLabel = '',
    this.nextLabel = '',
    this.askLabel = '',
    this.quietLabel = '',
    this.attemptsLabel = '',
    this.ordersLabel = '',
    this.sourceLabel = '',
    this.canResend = false,
    this.canRescan = false,
    this.canAck = false,
    this.resendLabel = '',
    this.rescanLabel = '',
    this.closeLabel = '',
    this.ackLabel = '',
  });

  static String _s(Map m, String k) {
    final v = m[k];
    return v == null ? '' : v.toString();
  }

  static bool _b(Map m, String k) => m[k] == true;

  factory OpsRow.fromJson(Map m) => OpsRow(
        id: _s(m, 'id'),
        title: _s(m, 'title'),
        subtitle: _s(m, 'subtitle'),
        ageLabel: _s(m, 'age_label'),
        stateLabel: _s(m, 'state_label'),
        stateTone: _s(m, 'state_tone').isEmpty ? 'info' : _s(m, 'state_tone'),
        qtyLabel: _s(m, 'qty_label'),
        nextLabel: _s(m, 'next_label'),
        askLabel: _s(m, 'ask_label'),
        quietLabel: _s(m, 'quiet_label'),
        attemptsLabel: _s(m, 'attempts_label'),
        ordersLabel: _s(m, 'orders_label'),
        sourceLabel: _s(m, 'source_label'),
        canResend: _b(m, 'can_resend'),
        canRescan: _b(m, 'can_rescan'),
        canAck: _b(m, 'can_ack'),
        resendLabel: _s(m, 'resend_label'),
        rescanLabel: _s(m, 'rescan_label'),
        closeLabel: _s(m, 'close_label'),
        ackLabel: _s(m, 'ack_label'),
      );

  /// The secondary lines this row actually carries, in payload order, with the
  /// empties dropped. The screen prints this list — it never asks "is this an
  /// alert row or an arrivals row?".
  List<String> get detailLines => <String>[
        for (final s in [
          subtitle,
          qtyLabel,
          askLabel,
          attemptsLabel,
          ordersLabel,
          nextLabel,
          quietLabel,
        ])
          if (s.isNotEmpty) s,
      ];
}

/// One row of the PO-integrity strip: label / value / detail / tone.
class OpsStripRow {
  final String label;
  final String value;
  final String detail;
  final String tone;

  const OpsStripRow({
    required this.label,
    required this.value,
    this.detail = '',
    this.tone = 'info',
  });

  factory OpsStripRow.fromJson(Map m) => OpsStripRow(
        label: (m['label'] ?? '').toString(),
        value: (m['value'] ?? '').toString(),
        detail: (m['detail'] ?? '').toString(),
        tone: (m['tone'] ?? 'info').toString(),
      );
}

/// A section of the screen. `layout` decides which body is drawn.
class OpsSection {
  static const knownLayouts = {'queue', 'strip'};

  final String key;
  final String layout;
  final String title;
  final String subtitle;
  final String countLabel;
  final String tone;
  final String emptyLabel;
  final String bannerLabel;
  final String bannerTone;
  final int count;
  final List<OpsRow> rows;
  final List<OpsStripRow> stripRows;

  const OpsSection({
    required this.key,
    required this.layout,
    required this.title,
    this.subtitle = '',
    this.countLabel = '',
    this.tone = 'info',
    this.emptyLabel = '',
    this.bannerLabel = '',
    this.bannerTone = 'info',
    this.count = 0,
    this.rows = const [],
    this.stripRows = const [],
  });

  static OpsSection? tryParse(Object? raw) {
    if (raw is! Map) return null;
    final layout = (raw['layout'] ?? '').toString();
    // Forward compatibility: a layout this build cannot draw is skipped in
    // silence, exactly as the home feed skips an unknown section layout.
    if (!knownLayouts.contains(layout)) return null;
    final list = (raw['rows'] as List?) ?? const [];
    return OpsSection(
      key: (raw['key'] ?? '').toString(),
      layout: layout,
      title: (raw['title'] ?? '').toString(),
      subtitle: (raw['subtitle'] ?? '').toString(),
      countLabel: (raw['count_label'] ?? '').toString(),
      tone: (raw['tone'] ?? 'info').toString(),
      emptyLabel: (raw['empty_label'] ?? '').toString(),
      bannerLabel: (raw['banner_label'] ?? '').toString(),
      bannerTone: (raw['banner_tone'] ?? 'info').toString(),
      count: raw['count'] is num ? (raw['count'] as num).toInt() : 0,
      rows: layout == 'queue'
          ? [for (final r in list) if (r is Map) OpsRow.fromJson(r)]
          : const [],
      stripRows: layout == 'strip'
          ? [for (final r in list) if (r is Map) OpsStripRow.fromJson(r)]
          : const [],
    );
  }
}

/// The whole screen, as the backend sent it.
class OpsQueues {
  final bool ok;
  final String title;
  final String subtitle;
  final String refreshLabel;
  final List<OpsSection> sections;

  /// Set when the payload itself is a refusal (`ok:false`) — the screen then
  /// renders the backend's own message instead of a queue.
  final String refusalMessage;
  final String refusalCode;

  const OpsQueues({
    required this.ok,
    this.title = '',
    this.subtitle = '',
    this.refreshLabel = '',
    this.sections = const [],
    this.refusalMessage = '',
    this.refusalCode = '',
  });

  factory OpsQueues.fromJson(Map m) {
    if (m['ok'] != true) {
      return OpsQueues(
        ok: false,
        refusalMessage: (m['message'] ?? '').toString(),
        refusalCode: (m['code'] ?? '').toString(),
        title: (m['title'] ?? '').toString(),
      );
    }
    final raw = (m['sections'] as List?) ?? const [];
    final sections = <OpsSection>[];
    for (final s in raw) {
      final parsed = OpsSection.tryParse(s);
      if (parsed != null) sections.add(parsed);
    }
    return OpsQueues(
      ok: true,
      title: (m['title'] ?? '').toString(),
      subtitle: (m['subtitle'] ?? '').toString(),
      refreshLabel: (m['refresh_label'] ?? '').toString(),
      sections: sections,
    );
  }
}
