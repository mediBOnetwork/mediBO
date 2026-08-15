import 'package:flutter/material.dart';

import '../../../design_tokens.dart';
import '../../../services/ui_copy.dart';
import 'dev_queue_common.dart';
import 'dev_queue_service.dart';

/// Bug-Loop Prevention — the Journey Library.
///
/// Lists every enabled journey (journeys_get), scoped by a backend-provided
/// area filter and a free-text search. Each journey shows its area, kind and
/// required/optional state plus its steps + assertions — all rendered verbatim
/// from the backend row.
class JourneyLibraryScreen extends StatefulWidget {
  final DevQueueService? service;
  const JourneyLibraryScreen({super.key, this.service});

  @override
  State<JourneyLibraryScreen> createState() => _JourneyLibraryScreenState();
}

class _JourneyLibraryScreenState extends State<JourneyLibraryScreen> {
  late final DevQueueService _svc = widget.service ?? DevQueueService();
  List<Map<String, dynamic>> _journeys = const [];
  List<Map<String, dynamic>> _areas = const [];
  String? _area; // null = all areas (backend p_area = null)
  String _query = '';
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _loadAreas();
    _load();
  }

  Future<void> _loadAreas() async {
    try {
      final a = await _svc.areasGet();
      if (mounted) setState(() => _areas = a);
    } catch (_) {/* the "all areas" chip still works */}
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final j = await _svc.journeysGet(area: _area);
      if (!mounted) return;
      setState(() {
        _journeys = j;
        _loading = false;
      });
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  List<Map<String, dynamic>> get _visible {
    if (_query.trim().isEmpty) return _journeys;
    final q = _query.toLowerCase();
    return _journeys
        .where((j) => (j['name'] ?? '').toString().toLowerCase().contains(q) ||
            (j['steps'] ?? '').toString().toLowerCase().contains(q))
        .toList();
  }

  @override
  Widget build(BuildContext context) {
    final visible = _visible;
    return Scaffold(
      backgroundColor: kPageBg,
      appBar: AppBar(
        backgroundColor: Colors.white,
        elevation: 0,
        iconTheme: const IconThemeData(color: kBrand),
        title: Text(c('dev_queue.journey_title'),
            style: Ds.t.subtitle.copyWith(fontWeight: FontWeight.w700, color: kTextHi)),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(1),
          child: Container(height: 1, color: kBorder),
        ),
      ),
      body: SafeArea(
        child: Column(children: [
          Padding(
            padding: EdgeInsets.fromLTRB(
                Ds.space.x16, Ds.space.x12, Ds.space.x16, Ds.space.x8),
            child: Semantics(
              identifier: 'journey_search',
              child: TextField(
                onChanged: (v) => setState(() => _query = v),
                decoration: InputDecoration(
                  prefixIcon: Icon(Icons.search, color: kTextLo),
                  hintText: c('dev_queue.journey_search'),
                  filled: true,
                  fillColor: Colors.white,
                  isDense: true,
                  border: OutlineInputBorder(
                      borderRadius: Ds.r.rButton,
                      borderSide: BorderSide(color: kBorder)),
                ),
              ),
            ),
          ),
          SizedBox(
            height: Ds.space.x48,
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding: EdgeInsets.symmetric(horizontal: Ds.space.x16),
              children: [
                _areaChip(null, c('dev_queue.journey_area_all')),
                for (final a in _areas)
                  _areaChip((a['area'] ?? '').toString(),
                      (a['label'] ?? '').toString()),
              ],
            ),
          ),
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator(color: kBrand))
                : visible.isEmpty
                    ? Center(
                        child: Text(c('dev_queue.journey_empty'),
                            style: Ds.t.body.copyWith(color: kTextLo)))
                    : ListView.builder(
                        padding: EdgeInsets.fromLTRB(Ds.space.x16, Ds.space.x8,
                            Ds.space.x16, Ds.space.x32),
                        itemCount: visible.length,
                        itemBuilder: (_, i) => _journeyCard(visible[i]),
                      ),
          ),
        ]),
      ),
    );
  }

  Widget _areaChip(String? area, String label) {
    final selected = _area == area;
    return Padding(
      padding: EdgeInsets.only(right: Ds.space.x8),
      child: ChoiceChip(
        label: Text(label,
            style: Ds.t.caption.copyWith(
                fontWeight: FontWeight.w600,
                color: selected ? Colors.white : kTextHi)),
        selected: selected,
        selectedColor: kBrand,
        backgroundColor: Colors.white,
        side: BorderSide(color: selected ? kBrand : kBorder),
        onSelected: (_) {
          setState(() => _area = area);
          _load();
        },
      ),
    );
  }

  Widget _journeyCard(Map<String, dynamic> j) {
    final name = (j['name'] ?? '').toString();
    final areaLabel = (j['area'] ?? '').toString();
    final kind = (j['kind'] ?? '').toString();
    final required = j['required'] == true;
    final enabled = j['enabled'] == true;
    final steps = (j['steps'] as List?) ?? const [];
    final asserts = (j['assertions'] as List?) ?? const [];

    return Padding(
      padding: EdgeInsets.only(bottom: Ds.space.x12),
      child: DqCard(
        accent: required ? Ds.c.brand : kBorder,
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(name,
              style: Ds.t.body.copyWith(fontWeight: FontWeight.w700, color: kTextHi)),
          SizedBox(height: Ds.space.x8),
          Wrap(spacing: Ds.space.x8, runSpacing: Ds.space.x8, children: [
            if (areaLabel.isNotEmpty)
              ToneChip(
                  label: _areaLabelFor(areaLabel),
                  tone: toneByName('neutral'),
                  icon: Icons.category_outlined),
            ToneChip(
                label: kind == 'browser'
                    ? c('dev_queue.journey_kind_browser')
                    : c('dev_queue.journey_kind_api'),
                tone: toneByName('info'),
                icon: kind == 'browser'
                    ? Icons.web_outlined
                    : Icons.api_outlined),
            ToneChip(
                label: !enabled
                    ? c('dev_queue.journey_disabled')
                    : (required
                        ? c('dev_queue.journey_required')
                        : c('dev_queue.journey_optional')),
                tone: toneByName(!enabled
                    ? 'neutral'
                    : (required ? 'success' : 'warning')),
                icon: required ? Icons.verified : Icons.pending_outlined),
          ]),
          if (steps.isNotEmpty) ...[
            SizedBox(height: Ds.space.x12),
            Text(c('dev_queue.journey_steps'),
                style: Ds.t.caption.copyWith(fontWeight: FontWeight.w700, color: kTextLo)),
            SizedBox(height: Ds.space.x4),
            for (final s in steps)
              Padding(
                padding: EdgeInsets.only(bottom: Ds.space.x4),
                child: Text('• ${s.toString()}',
                    style: Ds.t.caption.copyWith(color: kTextHi)),
              ),
          ],
          if (asserts.isNotEmpty) ...[
            SizedBox(height: Ds.space.x8),
            Text(c('dev_queue.journey_assertions'),
                style: Ds.t.caption.copyWith(fontWeight: FontWeight.w700, color: kTextLo)),
            SizedBox(height: Ds.space.x4),
            for (final a in asserts)
              Padding(
                padding: EdgeInsets.only(bottom: Ds.space.x4),
                child: Text('• ${a.toString()}',
                    style: Ds.t.caption.copyWith(color: kTextHi)),
              ),
          ],
        ]),
      ),
    );
  }

  // The backend stores the raw area token (e.g. "devops"); the areas list
  // carries the display label. Fall back to the token when unmapped.
  String _areaLabelFor(String area) {
    for (final a in _areas) {
      if ((a['area'] ?? '').toString() == area) {
        return (a['label'] ?? area).toString();
      }
    }
    return area;
  }
}
