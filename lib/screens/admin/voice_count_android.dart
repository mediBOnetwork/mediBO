// Android-only realtime voice-counting UI.
//
// The full Shop/Warehouse/Pack fulfillment dashboard is web-only (dart:html), so
// Android renders this lean surface instead of a stub. It reuses the SAME backend
// as the web tabs — one RPC per list, and the live voice_live_* RPCs via
// VoiceLiveController — so the two platforms can never disagree about a count.
//
// THE APP RENDERS. IT NEVER DECIDES: list rows are backend data (supplier /
// pharmacy names), every label is fw_ui_label copy, and every live string comes
// from the token (ready_label), the preview (hint/totals) and the commit
// (message). Nothing user-facing is authored here.
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../fulfill/fulfill_lookups.dart';
import '../../services/admin_date_scope.dart';
import '../../services/voice_live_service.dart';
import '../../services/voice_receive_service.dart';
import '../../utils/render_log.dart';

const Color _kGreen = Color(0xFF1B7A43);
const Color _kPage = Color(0xFFF5F6F8);
const Color _kCard = Color(0xFFFFFFFF);
const Color _kText = Color(0xFF111827);
const Color _kSub = Color(0xFF6B7280);
const Color _kBorder = Color(0xFFE5E7EB);

String _sessionKey(String entity, String stage) =>
    '$entity|$stage|${DateTime.now().millisecondsSinceEpoch}';

String _label(String key) {
  final v = FulfillLookups.instance.ui(key);
  return v.isEmpty ? key : v;
}

/// Android entry: pick what to count (Shop / Warehouse / Pack).
class VoiceCountAndroidHome extends StatefulWidget {
  const VoiceCountAndroidHome({super.key});
  @override
  State<VoiceCountAndroidHome> createState() => _VoiceCountAndroidHomeState();
}

class _VoiceCountAndroidHomeState extends State<VoiceCountAndroidHome> {
  @override
  void initState() {
    super.initState();
    FulfillLookups.instance.ensureLoaded().then((_) {
      if (mounted) setState(() {});
    });
    RenderLog.write('c668_va_home', 'android=y');
  }

  void _open(String stage, {required bool pack}) {
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => pack
          ? const _OrderPickerScreen()
          : _SupplierPickerScreen(stage: stage),
    ));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _kPage,
      appBar: AppBar(
        backgroundColor: _kCard,
        elevation: 0,
        foregroundColor: _kText,
        title: Text(_label('va_home_title'),
            style: const TextStyle(
                fontWeight: FontWeight.w700, fontSize: 20, color: _kText)),
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(_label('va_choose_mode'),
                  style: const TextStyle(
                      fontSize: 13, color: _kSub, fontWeight: FontWeight.w400)),
              const SizedBox(height: 16),
              _ModeButton(
                  label: _label('va_shop'),
                  icon: Icons.storefront_outlined,
                  onTap: () => _open('shop', pack: false)),
              const SizedBox(height: 12),
              _ModeButton(
                  label: _label('va_warehouse'),
                  icon: Icons.warehouse_outlined,
                  onTap: () => _open('warehouse', pack: false)),
              const SizedBox(height: 12),
              _ModeButton(
                  label: _label('va_pack'),
                  icon: Icons.inventory_2_outlined,
                  onTap: () => _open('pack', pack: true)),
            ],
          ),
        ),
      ),
    );
  }
}

class _ModeButton extends StatelessWidget {
  final String label;
  final IconData icon;
  final VoidCallback onTap;
  const _ModeButton(
      {required this.label, required this.icon, required this.onTap});
  @override
  Widget build(BuildContext context) {
    return Material(
      color: _kCard,
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: onTap,
        child: Container(
          height: 64,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: _kBorder),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 20),
          child: Row(children: [
            Icon(icon, color: _kGreen, size: 26),
            const SizedBox(width: 16),
            Expanded(
                child: Text(label,
                    style: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                        color: _kText))),
            const Icon(Icons.chevron_right, color: _kSub),
          ]),
        ),
      ),
    );
  }
}

/// Shop / Warehouse: pick the supplier to count against (fw_list_arrivals).
class _SupplierPickerScreen extends StatefulWidget {
  final String stage; // 'shop' | 'warehouse'
  const _SupplierPickerScreen({required this.stage});
  @override
  State<_SupplierPickerScreen> createState() => _SupplierPickerScreenState();
}

class _SupplierPickerScreenState extends State<_SupplierPickerScreen> {
  bool _loading = true;
  List<String> _suppliers = const [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final res =
          await Supabase.instance.client.rpc('fw_list_arrivals') as Map;
      final key =
          widget.stage == 'warehouse' ? 'warehouse_suppliers' : 'suppliers';
      final raw = (res[key] as List? ?? const []);
      final names = <String>[];
      for (final r in raw) {
        if (r is Map) {
          final n = (r['supplier'] ?? r['supplier_name'])?.toString() ?? '';
          if (n.isNotEmpty && !names.contains(n)) names.add(n);
        }
      }
      if (!mounted) return;
      setState(() {
        _suppliers = names;
        _loading = false;
      });
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return _PickerScaffold(
      title: widget.stage == 'warehouse'
          ? _label('va_warehouse')
          : _label('va_shop'),
      loading: _loading,
      emptyLabel: _label('va_no_suppliers'),
      empty: _suppliers.isEmpty,
      itemCount: _suppliers.length,
      itemBuilder: (i) {
        final name = _suppliers[i];
        return _PickerTile(
          title: name,
          onTap: () => Navigator.of(context).push(MaterialPageRoute(
            builder: (_) => LiveCountScreen.supplier(
                supplier: name, stage: widget.stage),
          )),
        );
      },
    );
  }
}

/// Pack: pick the customer order (pack_list_orders). The token supplier is any
/// supplier the user may count for (the token is not order-specific).
class _OrderPickerScreen extends StatefulWidget {
  const _OrderPickerScreen();
  @override
  State<_OrderPickerScreen> createState() => _OrderPickerScreenState();
}

class _OrderPickerScreenState extends State<_OrderPickerScreen> {
  bool _loading = true;
  List<Map<String, dynamic>> _orders = const [];
  String _tokenSupplier = '';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final results = await Future.wait<dynamic>([
        Supabase.instance.client.rpc('pack_list_orders'),
        Supabase.instance.client.rpc('fw_list_arrivals'),
      ]);
      final res = results[0];
      final orders = ((res is Map ? res['orders'] : null) as List? ?? const [])
          .whereType<Map>()
          .map((m) => Map<String, dynamic>.from(m))
          .toList();
      // Any supplier with open items works for minting the token.
      final arr = results[1];
      var tokenSupplier = '';
      final sup = (arr is Map ? arr['suppliers'] : null) as List? ?? const [];
      for (final r in sup) {
        if (r is Map) {
          final n = (r['supplier'] ?? r['supplier_name'])?.toString() ?? '';
          if (n.isNotEmpty) {
            tokenSupplier = n;
            break;
          }
        }
      }
      if (!mounted) return;
      setState(() {
        _orders = orders;
        _tokenSupplier = tokenSupplier;
        _loading = false;
      });
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return _PickerScaffold(
      title: _label('va_pack'),
      loading: _loading,
      emptyLabel: _label('va_no_orders'),
      empty: _orders.isEmpty,
      itemCount: _orders.length,
      itemBuilder: (i) {
        final o = _orders[i];
        final oid = o['order_id']?.toString() ?? '';
        final name = o['pharmacy_name']?.toString() ?? oid;
        return _PickerTile(
          title: name,
          onTap: oid.isEmpty
              ? null
              : () => Navigator.of(context).push(MaterialPageRoute(
                    builder: (_) => LiveCountScreen.pack(
                        orderId: oid, tokenSupplier: _tokenSupplier),
                  )),
        );
      },
    );
  }
}

class _PickerScaffold extends StatelessWidget {
  final String title;
  final bool loading;
  final bool empty;
  final String emptyLabel;
  final int itemCount;
  final Widget Function(int) itemBuilder;
  const _PickerScaffold({
    required this.title,
    required this.loading,
    required this.empty,
    required this.emptyLabel,
    required this.itemCount,
    required this.itemBuilder,
  });
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _kPage,
      appBar: AppBar(
        backgroundColor: _kCard,
        elevation: 0,
        foregroundColor: _kText,
        title: Text(title,
            style: const TextStyle(
                fontWeight: FontWeight.w700, fontSize: 20, color: _kText)),
      ),
      body: SafeArea(
        child: loading
            ? const Center(child: CircularProgressIndicator(color: _kGreen))
            : empty
                ? Center(
                    child: Text(emptyLabel,
                        style: const TextStyle(color: _kSub, fontSize: 14)))
                : ListView.separated(
                    padding: const EdgeInsets.all(16),
                    itemCount: itemCount,
                    separatorBuilder: (_, __) => const SizedBox(height: 10),
                    itemBuilder: (_, i) => itemBuilder(i),
                  ),
      ),
    );
  }
}

class _PickerTile extends StatelessWidget {
  final String title;
  final VoidCallback? onTap;
  const _PickerTile({required this.title, this.onTap});
  @override
  Widget build(BuildContext context) {
    return Material(
      color: _kCard,
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onTap,
        child: Container(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: _kBorder),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 18),
          child: Row(children: [
            Expanded(
                child: Text(title,
                    style: const TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w500,
                        color: _kText))),
            const Icon(Icons.chevron_right, color: _kSub),
          ]),
        ),
      ),
    );
  }
}

/// The live counting screen — one VoiceLiveController for the whole mic-on →
/// Stop lifecycle. Start streams to Speech-to-Text; totals refresh as the person
/// speaks; Stop commits once and shows the backend's message.
class LiveCountScreen extends StatefulWidget {
  final bool pack;
  final String? supplier;
  final String? stage;
  final String? orderId;
  final String? tokenSupplier;

  const LiveCountScreen._({
    required this.pack,
    this.supplier,
    this.stage,
    this.orderId,
    this.tokenSupplier,
  });

  factory LiveCountScreen.supplier(
          {required String supplier, required String stage}) =>
      LiveCountScreen._(pack: false, supplier: supplier, stage: stage);

  factory LiveCountScreen.pack(
          {required String orderId, required String tokenSupplier}) =>
      LiveCountScreen._(
          pack: true, orderId: orderId, tokenSupplier: tokenSupplier);

  @override
  State<LiveCountScreen> createState() => _LiveCountScreenState();
}

class _LiveCountScreenState extends State<LiveCountScreen> {
  VoiceLiveController? _controller;
  bool _listening = false;
  bool _processing = false;
  String _ready = '';
  String _caption = '';
  String _hint = '';
  String _error = '';
  String _message = '';
  List<Map<String, dynamic>> _totals = const [];

  /// Rows the backend clamped because they exceeded what was ordered. Shown as a
  /// warning; the ledger itself is already clamped server-side.
  List<Map<String, dynamic>> _overCounted = const [];

  /// Render-ready bag label straight from the commit payload — '' where the
  /// stage has no bag condition (shop, pack), so no chip is drawn there.
  String _activeBag = '';

  /// Mentions the backend could not attribute to a bag. Surfaced so they can be
  /// reviewed, never silently dropped.
  List<Map<String, dynamic>> _needsBagReview = const [];

  /// True once a commit has landed. From then on the screen shows only what the
  /// backend persisted, never an in-flight preview.
  bool _persisted = false;

  /// The clip-path session running instead of the live stream, if any. Non-null
  /// means live streaming could not be held and the fallback took over.
  ContinuousVoiceSession? _clipSession;

  String get _title => widget.pack
      ? _label('va_pack')
      : (widget.stage == 'warehouse'
          ? _label('va_warehouse')
          : _label('va_shop'));

  VoiceLiveBackend _buildBackend() {
    if (widget.pack) {
      return PackVoiceBackend(
        orderId: widget.orderId!,
        tokenSupplier: widget.tokenSupplier ?? '',
      );
    }
    return SupplierVoiceBackend(
      supplier: widget.supplier!,
      stage: widget.stage!,
      date: AdminDateScope.instance.dateYmd,
    );
  }

  Future<void> _start() async {
    if (_listening || _processing) return;
    final entity = widget.pack ? widget.orderId! : widget.supplier!;
    final stage = widget.pack ? 'pack' : widget.stage!;
    final c = VoiceLiveController(
      backend: _buildBackend(),
      sessionKey: _sessionKey(entity, stage),
      onReady: (l) {
        if (mounted) setState(() => _ready = l);
      },
      onCaption: (t) {
        if (mounted) setState(() => _caption = t);
      },
      onSnapshot: (s) {
        if (!mounted) return;
        // A preview must never overwrite a persisted count: once the backend has
        // told us what it SAVED, only another commit may change the number.
        if (_persisted && !s.authoritative) return;
        setState(() {
          _totals = s.totals;
          _hint = s.hint;
          _overCounted = s.overCounted;
          _needsBagReview = s.needsBagReview;
          _activeBag = s.activeBagLabel;
          if (s.authoritative) _persisted = true;
        });
      },
      onMessage: (m) {
        if (mounted) setState(() => _message = m);
      },
      onError: (m) {
        if (mounted) setState(() => _error = m);
      },
      onFallback: (why) {
        if (!mounted) return;
        setState(() {
          _error = FulfillLookups.instance.message('voice_live_fallback') ?? why;
        });
        _startClipFallback();
      },
    );
    setState(() {
      _listening = true;
      _error = '';
      _message = '';
      _caption = '';
      _persisted = false;
      _overCounted = const [];
      _activeBag = '';
    });
    try {
      final ok = await c.start();
      if (!ok) {
        if (mounted) setState(() => _listening = false);
        return;
      }
      _controller = c;
    } catch (e) {
      if (mounted) {
        setState(() {
          _listening = false;
          _error =
              FulfillLookups.instance.message('mic_permission') ?? e.toString();
        });
      }
    }
  }

  /// Live streaming could not be held for this session. Shop and Warehouse can
  /// carry on through the clip recorder: it needs no gRPC, and every spoken name
  /// is resolved server-side by voice_match_product, so an empty local item list
  /// costs nothing.
  ///
  /// Pack is deliberately NOT auto-switched — PackVoiceSession resolves product
  /// names against the order's own item list, which this lean Android screen
  /// never loads. Starting it here would record audio and silently match nothing,
  /// which is worse than telling the operator the live path is down.
  Future<void> _startClipFallback() async {
    if (widget.pack || _clipSession != null) return;
    try {
      final s = ContinuousVoiceSession(
        supplierName: widget.supplier!,
        stage: widget.stage!,
        dateYmd: AdminDateScope.instance.dateYmd ?? '',
        orderItemsProvider: () => const [],
        onWindowError: (e, st) {
          if (!mounted) return;
          setState(() => _error =
              FulfillLookups.instance.message('window_save_failed') ?? '');
        },
      );
      await s.start();
      if (!mounted) {
        await s.stopAndFinalize();
        return;
      }
      setState(() {
        _clipSession = s;
        _listening = true;
      });
      RenderLog.write('c_voice_live_fallback',
          'supplier=${widget.supplier};stage=${widget.stage}');
    } catch (e) {
      if (mounted) {
        setState(() {
          _listening = false;
          _error = FulfillLookups.instance.message('voice_error') ?? e.toString();
        });
      }
    }
  }

  /// Totals after a clip-path session: re-read what the backend persisted rather
  /// than trusting anything held on screen.
  Future<void> _refreshPersistedTotals() async {
    try {
      final res = await Supabase.instance.client
          .rpc('voice_mention_product_totals', params: {
        'p_supplier_name': widget.supplier,
        'p_stage': widget.stage,
        'p_date': AdminDateScope.instance.dateYmd,
      });
      if (!mounted || res is! List) return;
      setState(() {
        _totals = res
            .whereType<Map>()
            .map((e) => Map<String, dynamic>.from(e))
            .toList();
        _persisted = true;
      });
    } catch (_) {
      // Best-effort refresh — the counts are already saved either way.
    }
  }

  Future<void> _stop() async {
    final clip = _clipSession;
    if (clip != null) {
      setState(() {
        _listening = false;
        _processing = true;
        _caption = '';
      });
      try {
        final r = await clip.stopAndFinalize();
        if (mounted) {
          final m = (r['message'] ?? '').toString();
          if (m.isNotEmpty) setState(() => _message = m);
        }
        await _refreshPersistedTotals();
      } catch (e) {
        if (mounted) {
          setState(() => _error =
              FulfillLookups.instance.message('voice_session_error') ??
                  e.toString());
        }
      } finally {
        _clipSession = null;
        if (mounted) setState(() => _processing = false);
      }
      return;
    }

    final c = _controller;
    if (c == null) return;
    setState(() {
      _listening = false;
      _processing = true;
      _caption = '';
    });
    try {
      await c.stop();
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      _controller = null;
      if (mounted) setState(() => _processing = false);
    }
  }

  @override
  void dispose() {
    _controller?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _kPage,
      appBar: AppBar(
        backgroundColor: _kCard,
        elevation: 0,
        foregroundColor: _kText,
        title: Text(_title,
            style: const TextStyle(
                fontWeight: FontWeight.w700, fontSize: 20, color: _kText)),
      ),
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Status line: ready label / caption / hint (all backend-owned).
            Container(
              width: double.infinity,
              color: _kCard,
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (_ready.isNotEmpty)
                    Text(_ready,
                        style: const TextStyle(
                            fontSize: 13,
                            color: _kGreen,
                            fontWeight: FontWeight.w600)),
                  if (_caption.isNotEmpty) ...[
                    const SizedBox(height: 6),
                    Text(_caption,
                        style: const TextStyle(fontSize: 15, color: _kText)),
                  ],
                  if (_caption.isEmpty && _hint.isNotEmpty) ...[
                    const SizedBox(height: 6),
                    Text(_hint,
                        style: const TextStyle(fontSize: 13, color: _kSub)),
                  ],
                  if (_error.isNotEmpty) ...[
                    const SizedBox(height: 6),
                    Text(_error,
                        style: const TextStyle(
                            fontSize: 13, color: Color(0xFF991B1B))),
                  ],
                  if (_message.isNotEmpty) ...[
                    const SizedBox(height: 6),
                    Text(_message,
                        style: const TextStyle(
                            fontSize: 13,
                            color: Color(0xFF065F46),
                            fontWeight: FontWeight.w600)),
                  ],
                ],
              ),
            ),
            const SizedBox(height: 8),
            // Bag the backend is currently attributing words to. Only the
            // warehouse has a bag condition, and active_bag comes back empty
            // everywhere else, so no chip is drawn on Shop or Pack.
            if (_activeBag.isNotEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 10, vertical: 4),
                    decoration: BoxDecoration(
                      color: const Color(0xFFEFF6FF),
                      borderRadius: BorderRadius.circular(999),
                      border: Border.all(color: const Color(0xFFBFDBFE)),
                    ),
                    child: Text(
                      _activeBag,
                      style: const TextStyle(
                          fontSize: 12,
                          color: Color(0xFF1D4ED8),
                          fontWeight: FontWeight.w600),
                    ),
                  ),
                ),
              ),
            // Over-count is a WARNING, not a block: the backend has already
            // clamped the ledger, so the count on screen stays correct. The
            // wording is the backend's.
            if (_overCounted.isNotEmpty || _needsBagReview.isNotEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    for (final o in _overCounted)
                      Text(
                        (o['message'] ?? '').toString(),
                        style: const TextStyle(
                            fontSize: 12, color: Color(0xFF92400E)),
                      ),
                    for (final r in _needsBagReview)
                      Text(
                        '${r['name'] ?? ''} ${r['qty'] ?? ''} — ${_label('va_needs_bag')}',
                        style: const TextStyle(
                            fontSize: 12, color: Color(0xFF92400E)),
                      ),
                  ],
                ),
              ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Text(_label('va_totals'),
                  style: const TextStyle(
                      fontSize: 13,
                      color: _kSub,
                      fontWeight: FontWeight.w600)),
            ),
            const SizedBox(height: 6),
            Expanded(
              child: _totals.isEmpty
                  ? const SizedBox.shrink()
                  : ListView.separated(
                      padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                      itemCount: _totals.length,
                      separatorBuilder: (_, _) =>
                          const Divider(height: 1, color: _kBorder),
                      itemBuilder: (_, i) {
                        final t = _totals[i];
                        return Padding(
                          padding: const EdgeInsets.symmetric(vertical: 12),
                          child: Row(children: [
                            Expanded(
                                child: Text(t['name']?.toString() ?? '',
                                    style: const TextStyle(
                                        fontSize: 15, color: _kText))),
                            Text('${t['qty'] ?? ''}',
                                style: const TextStyle(
                                    fontSize: 15,
                                    fontWeight: FontWeight.w600,
                                    color: _kText)),
                          ]),
                        );
                      },
                    ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
              child: SizedBox(
                height: 52,
                child: _processing
                    ? const Center(
                        child: CircularProgressIndicator(color: _kGreen))
                    : ElevatedButton.icon(
                        style: ElevatedButton.styleFrom(
                          backgroundColor: _listening
                              ? const Color(0xFF991B1B)
                              : _kGreen,
                          foregroundColor: Colors.white,
                          shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(10)),
                        ),
                        icon: Icon(_listening
                            ? Icons.stop_rounded
                            : Icons.mic_rounded),
                        label: Text(
                            _listening ? _label('va_stop') : _label('va_start'),
                            style: const TextStyle(
                                fontSize: 16, fontWeight: FontWeight.w600)),
                        onPressed: _listening ? _stop : _start,
                      ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
