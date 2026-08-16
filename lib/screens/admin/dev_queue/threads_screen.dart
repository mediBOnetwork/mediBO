import 'package:flutter/material.dart';

import '../../../design_tokens.dart';
import '../../../utils/toast.dart';
import 'dev_queue_common.dart';
import 'dev_queue_service.dart';

/// Permanent, resumable conversations (#183) — the app surface over
/// `agent_threads` / `agent_messages`. One RPC per view (`thread_list`,
/// `thread_open`, `conversation_search`), rendered verbatim. Every label comes
/// from the backend payload. Search is semantic (pgvector, embedded via the
/// gte-small edge function); Resume marks the thread so the next agent session
/// preloads it.
///
/// THE APP RENDERS. IT NEVER DECIDES.
class ThreadsScreen extends StatefulWidget {
  final DevQueueService? service;
  const ThreadsScreen({super.key, this.service});

  @override
  State<ThreadsScreen> createState() => _ThreadsScreenState();
}

class _ThreadsScreenState extends State<ThreadsScreen> {
  late final DevQueueService _svc = widget.service ?? DevQueueService();

  Map<String, dynamic> _payload = const {};
  List<Map<String, dynamic>> _rows = const [];
  List<Map<String, dynamic>> _results = const [];
  final _searchCtl = TextEditingController();
  bool _loading = true;
  bool _searching = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _searchCtl.dispose();
    super.dispose();
  }

  List<Map<String, dynamic>> _mapList(dynamic v) => ((v as List?) ?? const [])
      .whereType<Map>()
      .map((e) => Map<String, dynamic>.from(e))
      .toList();

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final p = await _svc.threadList();
      if (!mounted) return;
      setState(() {
        _payload = p;
        _rows = _mapList(p['rows']);
        _loading = false;
      });
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _runSearch(String q) async {
    if (q.trim().isEmpty) {
      setState(() => _results = const []);
      return;
    }
    setState(() => _searching = true);
    try {
      final p = await _svc.conversationSearch(q.trim());
      if (!mounted) return;
      setState(() {
        _results = _mapList(p['rows']);
        _searching = false;
      });
    } catch (_) {
      if (mounted) setState(() => _searching = false);
    }
  }

  String _lbl(String k, [String fb = '']) => (_payload[k] ?? fb).toString();

  @override
  Widget build(BuildContext context) {
    final title = _lbl('screen_title', 'Threads');
    final hasQuery = _searchCtl.text.trim().isNotEmpty;
    return Scaffold(
      backgroundColor: kPageBg,
      appBar: AppBar(
        backgroundColor: Colors.white,
        elevation: 0,
        iconTheme: const IconThemeData(color: kBrand),
        title: Text(title,
            style: Ds.t.subtitle
                .copyWith(fontWeight: FontWeight.w700, color: kTextHi)),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(1),
          child: Container(height: 1, color: kBorder),
        ),
      ),
      body: SafeArea(
        child: _loading
            ? const Center(child: CircularProgressIndicator(color: kBrand))
            : Column(children: [
                if (_lbl('subtitle').isNotEmpty)
                  Padding(
                    padding: EdgeInsets.fromLTRB(
                        Ds.space.x16, Ds.space.x12, Ds.space.x16, 0),
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: Text(_lbl('subtitle'),
                          style: Ds.t.caption.copyWith(color: kTextLo)),
                    ),
                  ),
                Padding(
                  padding: EdgeInsets.fromLTRB(
                      Ds.space.x16, Ds.space.x8, Ds.space.x16, Ds.space.x8),
                  child: TextField(
                    controller: _searchCtl,
                    textInputAction: TextInputAction.search,
                    onChanged: (_) => setState(() {}),
                    onSubmitted: _runSearch,
                    decoration: InputDecoration(
                      prefixIcon: Icon(Icons.search, color: kTextLo),
                      suffixIcon: hasQuery
                          ? IconButton(
                              icon: Icon(Icons.close, color: kTextLo),
                              onPressed: () {
                                _searchCtl.clear();
                                setState(() => _results = const []);
                              },
                            )
                          : null,
                      hintText: _lbl('search_hint', 'Search threads…'),
                      filled: true,
                      fillColor: Colors.white,
                      isDense: true,
                      border: OutlineInputBorder(
                          borderRadius: Ds.r.rButton,
                          borderSide: BorderSide(color: kBorder)),
                    ),
                  ),
                ),
                Expanded(
                  child: _searching
                      ? const Center(child: CircularProgressIndicator(color: kBrand))
                      : hasQuery
                          ? _resultsView()
                          : _threadsView(),
                ),
              ]),
      ),
    );
  }

  Widget _threadsView() {
    if (_rows.isEmpty) {
      return Center(
        child: Padding(
          padding: EdgeInsets.all(Ds.space.x32),
          child: Text(_lbl('empty', 'No threads yet.'),
              textAlign: TextAlign.center,
              style: Ds.t.body.copyWith(color: kTextLo)),
        ),
      );
    }
    return RefreshIndicator(
      color: kBrand,
      onRefresh: _load,
      child: ListView.builder(
        padding: EdgeInsets.fromLTRB(
            Ds.space.x16, Ds.space.x8, Ds.space.x16, Ds.space.x32),
        itemCount: _rows.length,
        itemBuilder: (_, i) => _threadCard(_rows[i]),
      ),
    );
  }

  Widget _threadCard(Map<String, dynamic> t) {
    final id = (t['id'] ?? '').toString();
    final title = (t['title'] ?? '').toString();
    final meta = (t['meta_label'] ?? '').toString();
    final updated = (t['updated_label'] ?? '').toString();
    final summary = (t['summary'] ?? '').toString();
    return Padding(
      padding: EdgeInsets.only(bottom: Ds.space.x12),
      child: DqCard(
        onTap: () => _openThread(id),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(title,
              style:
                  Ds.t.body.copyWith(fontWeight: FontWeight.w700, color: kTextHi)),
          SizedBox(height: Ds.space.x4),
          Text(meta, style: Ds.t.caption.copyWith(color: kTextLo)),
          if (summary.isNotEmpty) ...[
            SizedBox(height: Ds.space.x8),
            Text(summary,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: Ds.t.caption.copyWith(color: kTextHi)),
          ],
          SizedBox(height: Ds.space.x12),
          Row(children: [
            Expanded(
              child: Text(updated, style: Ds.t.caption.copyWith(color: kTextLo)),
            ),
            OutlinedButton.icon(
              onPressed: () => _resume(id, title),
              icon: Icon(Icons.play_arrow, size: Ds.space.x16, color: kBrand),
              label: Text(_lbl('resume_label', 'Resume'),
                  style: Ds.t.caption
                      .copyWith(color: kBrand, fontWeight: FontWeight.w600)),
              style: OutlinedButton.styleFrom(
                  side: BorderSide(color: kBrand),
                  padding: EdgeInsets.symmetric(
                      horizontal: Ds.space.x12, vertical: Ds.space.x8)),
            ),
          ]),
        ]),
      ),
    );
  }

  Widget _resultsView() {
    if (_results.isEmpty) {
      return Center(
        child: Padding(
          padding: EdgeInsets.all(Ds.space.x32),
          child: Text('No matches.',
              style: Ds.t.body.copyWith(color: kTextLo)),
        ),
      );
    }
    return ListView.builder(
      padding: EdgeInsets.fromLTRB(
          Ds.space.x16, Ds.space.x8, Ds.space.x16, Ds.space.x32),
      itemCount: _results.length,
      itemBuilder: (_, i) {
        final r = _results[i];
        final tid = (r['thread_id'] ?? '').toString();
        final tt = (r['thread_title'] ?? '').toString();
        final role = (r['role'] ?? '').toString();
        final snippet = (r['snippet'] ?? '').toString();
        final score = (r['score'] ?? '').toString();
        final time = (r['time_label'] ?? '').toString();
        return Padding(
          padding: EdgeInsets.only(bottom: Ds.space.x12),
          child: DqCard(
            onTap: () => _openThread(tid),
            child:
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                Expanded(
                  child: Text(tt,
                      style: Ds.t.body.copyWith(
                          fontWeight: FontWeight.w700, color: kTextHi)),
                ),
                ToneChip(
                    label: score, tone: toneByName('info'), icon: Icons.bolt),
              ]),
              SizedBox(height: Ds.space.x8),
              Text(snippet, style: Ds.t.caption.copyWith(color: kTextHi)),
              SizedBox(height: Ds.space.x4),
              Text('$role · $time',
                  style: Ds.t.caption.copyWith(color: kTextLo)),
            ]),
          ),
        );
      },
    );
  }

  Future<void> _resume(String id, String title) async {
    try {
      final r = await _svc.threadMarkResume(id);
      if (!mounted) return;
      showToast(context, (r['message'] ?? 'Resume queued').toString());
    } catch (_) {
      if (mounted) showToast(context, 'Could not queue resume', isError: true);
    }
  }

  Future<void> _openThread(String id) async {
    if (id.isEmpty) return;
    Map<String, dynamic> p = const {};
    try {
      p = await _svc.threadOpen(id);
    } catch (_) {}
    if (!mounted) return;
    Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => _ThreadDetail(payload: p, onResume: () => _resume(id, ''))));
  }
}

class _ThreadDetail extends StatelessWidget {
  final Map<String, dynamic> payload;
  final VoidCallback onResume;
  const _ThreadDetail({required this.payload, required this.onResume});

  @override
  Widget build(BuildContext context) {
    final thread = (payload['thread'] as Map?)?.cast<String, dynamic>() ?? const {};
    final messages = ((payload['messages'] as List?) ?? const [])
        .whereType<Map>()
        .map((e) => Map<String, dynamic>.from(e))
        .toList();
    final title = (thread['title'] ?? payload['title'] ?? 'Thread').toString();
    return Scaffold(
      backgroundColor: kPageBg,
      appBar: AppBar(
        backgroundColor: Colors.white,
        elevation: 0,
        iconTheme: const IconThemeData(color: kBrand),
        title: Text(title,
            style: Ds.t.subtitle
                .copyWith(fontWeight: FontWeight.w700, color: kTextHi)),
        actions: [
          IconButton(
            tooltip: 'Resume',
            icon: const Icon(Icons.play_arrow, color: kBrand),
            onPressed: () {
              onResume();
              Navigator.of(context).maybePop();
            },
          ),
        ],
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(1),
          child: Container(height: 1, color: kBorder),
        ),
      ),
      body: SafeArea(
        child: messages.isEmpty
            ? Center(
                child: Text('No turns in this thread.',
                    style: Ds.t.body.copyWith(color: kTextLo)))
            : ListView.builder(
                padding: EdgeInsets.all(Ds.space.x16),
                itemCount: messages.length,
                itemBuilder: (_, i) => _turn(messages[i]),
              ),
      ),
    );
  }

  Widget _turn(Map<String, dynamic> m) {
    final role = (m['role'] ?? '').toString();
    final content = (m['content'] ?? '').toString();
    final time = (m['time_label'] ?? '').toString();
    final isAgent = role == 'agent';
    final tone = role == 'user'
        ? toneByName('neutral')
        : (isAgent ? toneByName('success') : toneByName('info'));
    return Padding(
      padding: EdgeInsets.only(bottom: Ds.space.x12),
      child: DqCard(
        accent: isAgent ? Ds.c.brand : kBorder,
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            ToneChip(label: role, tone: tone, icon: Icons.person_outline),
            const Spacer(),
            Text(time, style: Ds.t.caption.copyWith(color: kTextLo)),
          ]),
          SizedBox(height: Ds.space.x8),
          Text(content, style: Ds.t.body.copyWith(color: kTextHi, height: 1.35)),
        ]),
      ),
    );
  }
}
