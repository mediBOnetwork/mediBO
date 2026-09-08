import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../design_tokens.dart';
import '../../../services/ui_copy.dart';
import '../../../utils/render_log.dart';
import 'dev_queue_common.dart';
import 'dev_queue_service.dart';

/// CHANGE #275 — Sign-in diagnostics.
///
/// Google sign-in died silently on the Play Store build: the account sheet
/// appeared, an account was picked, and nothing happened — no error, no
/// session, and ZERO attempts in the Supabase auth log because the flow never
/// reached the network. There was nowhere to read what the device actually
/// said: the app swallowed the platform exception, and the render-log
/// breadcrumbs were wiped by the next web deploy.
///
/// This screen is the place where the device speaks. Every failed attempt is a
/// row in `auth_diag` carrying the real platform error code, the description,
/// the app version, and the SIGNING CERTIFICATE SHA-1 of the running build —
/// which is the one fact that separates a sideloaded APK from a Play-re-signed
/// one, and therefore the fact that settles an OAuth-client mismatch.
///
/// Every visible word comes from `auth_diag_list()`: the title, the subtitle,
/// each row's labels, each code's hint and every tone. This screen computes
/// nothing and renders the payload in the order the backend sent it.
class SignInDiagScreen extends StatefulWidget {
  final DevQueueService? service;
  const SignInDiagScreen({super.key, this.service});

  @override
  State<SignInDiagScreen> createState() => _SignInDiagScreenState();
}

class _SignInDiagScreenState extends State<SignInDiagScreen> {
  late final DevQueueService _svc = widget.service ?? DevQueueService();
  Map<String, dynamic> _data = const {};
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final d = await _svc.authDiagList();
      if (!mounted) return;
      setState(() {
        _data = d;
        _loading = false;
        // ok:false is the BACKEND refusing (not a crash) and it ships its own
        // sentence — render that, never a locally worded one.
        _error = d['ok'] == true ? null : ((d['error'] as String?) ?? '');
      });
      try {
        final rows = (d['rows'] as List?) ?? const [];
        RenderLog.write('c275_signin_diag', 'rows=${rows.length}');
      } catch (_) {}
    } catch (_) {
      // Never print e.toString(): a Dart-formatted exception is a display
      // string written in Dart. The transport failed, so the only copy left is
      // the cached backend sentence for exactly that case.
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = c('dev_queue.signin_diag_unreachable');
      });
      try {
        RenderLog.write('c275_signin_diag', 'error');
      } catch (_) {}
    }
  }

  @override
  Widget build(BuildContext context) {
    final rows = (_data['rows'] as List?) ?? const [];
    final refresh =
        (_data['refresh_label'] as String?) ?? c('dev_queue.signin_diag_nav_label');

    return Scaffold(
      backgroundColor: kPageBg,
      appBar: AppBar(
        backgroundColor: Colors.white,
        elevation: 0,
        iconTheme: const IconThemeData(color: kBrand),
        title: Text(
          (_data['title'] as String?) ?? c('dev_queue.signin_diag_nav_label'),
          style:
              Ds.t.subtitle.copyWith(fontWeight: FontWeight.w700, color: kTextHi),
        ),
        actions: [
          IconButton(
            tooltip: refresh,
            icon: const Icon(Icons.refresh, color: kBrand),
            onPressed: _loading ? null : _load,
          ),
        ],
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(1),
          child: Container(height: 1, color: kBorder),
        ),
      ),
      body: _loading
          ? _skeleton()
          : RefreshIndicator(
              onRefresh: _load,
              child: ListView(
                padding: EdgeInsets.all(Ds.space.x16),
                children: [
                  if (_error != null) ...[
                    DqCard(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(_error!,
                              style: Ds.t.body.copyWith(color: Ds.c.danger)),
                          SizedBox(height: Ds.space.x12),
                          OutlinedButton(
                            onPressed: _load,
                            child: Text(refresh),
                          ),
                        ],
                      ),
                    ),
                  ] else ...[
                    _header(),
                    SizedBox(height: Ds.space.x16),
                    if (rows.isEmpty)
                      DqCard(
                        child: Text(
                          (_data['empty_label'] as String?) ?? '',
                          style: Ds.t.body.copyWith(color: kTextLo),
                        ),
                      )
                    else
                      for (final r in rows) ...[
                        _row((r as Map).cast<String, dynamic>()),
                        SizedBox(height: Ds.space.x12),
                      ],
                  ],
                  SizedBox(height: Ds.space.x32),
                ],
              ),
            ),
    );
  }

  Widget _header() => DqCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text((_data['subtitle'] as String?) ?? '',
                style: Ds.t.body
                    .copyWith(fontWeight: FontWeight.w600, color: kTextHi)),
            SizedBox(height: Ds.space.x8),
            Text((_data['count_label'] as String?) ?? '',
                style: Ds.t.caption.copyWith(color: kTextLo)),
          ],
        ),
      );

  Widget _row(Map<String, dynamic> r) {
    final details = (r['details'] as String?) ?? '';
    final hint = (r['hint'] as String?) ?? '';
    final sha1 = (r['signing_label'] as String?) ?? '—';
    final facts = ((r['facts'] as List?) ?? const [])
        .map((e) => (e as Map).cast<String, dynamic>())
        .toList();
    return DqCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              ToneChip(
                label: (r['code_label'] as String?) ?? '',
                tone: toneByName((r['tone'] as String?) ?? 'neutral'),
              ),
              SizedBox(width: Ds.space.x8),
              Expanded(
                child: Text(
                  (r['when_label'] as String?) ?? '',
                  textAlign: TextAlign.right,
                  overflow: TextOverflow.ellipsis,
                  style: Ds.t.caption.copyWith(color: kTextLo),
                ),
              ),
            ],
          ),
          SizedBox(height: Ds.space.x12),
          Text((r['description'] as String?) ?? '',
              style: Ds.t.body.copyWith(color: kTextHi)),
          if (hint.isNotEmpty) ...[
            SizedBox(height: Ds.space.x8),
            Text(hint, style: Ds.t.caption.copyWith(color: kTextLo)),
          ],
          if (details.isNotEmpty) ...[
            SizedBox(height: Ds.space.x8),
            Text(details, style: Ds.t.caption.copyWith(color: kTextLo)),
          ],
          SizedBox(height: Ds.space.x12),
          Wrap(
            spacing: Ds.space.x8,
            runSpacing: Ds.space.x8,
            children: [
              _fact((r['platform_label'] as String?) ?? ''),
              _fact((r['stage_label'] as String?) ?? ''),
              _fact((r['build_label'] as String?) ?? ''),
              _fact((r['elapsed_label'] as String?) ?? ''),
              _fact((r['package_label'] as String?) ?? ''),
            ],
          ),
          SizedBox(height: Ds.space.x12),
          // The signing fingerprint is the whole point of this screen, so it is
          // one tap to copy into the Google Cloud OAuth client.
          InkWell(
            borderRadius: Ds.r.rButton,
            onTap: sha1 == '—'
                ? null
                : () => Clipboard.setData(ClipboardData(text: sha1)),
            child: Container(
              width: double.infinity,
              constraints: const BoxConstraints(minHeight: 44),
              alignment: Alignment.centerLeft,
              padding: EdgeInsets.symmetric(
                  horizontal: Ds.space.x12, vertical: Ds.space.x8),
              decoration: BoxDecoration(
                color: kPageBg,
                borderRadius: Ds.r.rButton,
                border: Border.all(color: kBorder),
              ),
              child: Text(sha1,
                  style: Ds.t.caption.copyWith(color: kTextHi)),
            ),
          ),
          // CHANGE #279 — every other fact the device reported, in the order
          // the backend sent them, each one tap-to-copy. Labels and values are
          // the payload's own strings; absent facts are simply not in the list.
          for (final f in facts) ...[
            SizedBox(height: Ds.space.x8),
            _factRow(
              (f['label'] as String?) ?? '',
              (f['value'] as String?) ?? '',
            ),
          ],
        ],
      ),
    );
  }

  Widget _factRow(String label, String value) => InkWell(
        borderRadius: Ds.r.rButton,
        onTap: value.isEmpty
            ? null
            : () => Clipboard.setData(ClipboardData(text: value)),
        child: Container(
          width: double.infinity,
          constraints: const BoxConstraints(minHeight: 44),
          alignment: Alignment.centerLeft,
          padding: EdgeInsets.symmetric(
              horizontal: Ds.space.x12, vertical: Ds.space.x8),
          decoration: BoxDecoration(
            color: kPageBg,
            borderRadius: Ds.r.rButton,
            border: Border.all(color: kBorder),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(label, style: Ds.t.caption.copyWith(color: kTextLo)),
              SizedBox(height: Ds.space.x4),
              Text(value, style: Ds.t.caption.copyWith(color: kTextHi)),
            ],
          ),
        ),
      );

  Widget _fact(String v) => Container(
        constraints: const BoxConstraints(minHeight: 28),
        alignment: Alignment.center,
        padding: EdgeInsets.symmetric(
            horizontal: Ds.space.x12, vertical: Ds.space.x4),
        decoration: BoxDecoration(
          color: kPageBg,
          borderRadius: Ds.r.rButton,
          border: Border.all(color: kBorder),
        ),
        child: Text(v, style: Ds.t.caption.copyWith(color: kTextLo)),
      );

  Widget _skeleton() => ListView(
        padding: EdgeInsets.all(Ds.space.x16),
        children: [
          for (var i = 0; i < 4; i++) ...[
            Container(
              height: 96,
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: Ds.r.rCard,
                border: Border.all(color: kBorder),
              ),
            ),
            SizedBox(height: Ds.space.x12),
          ],
        ],
      );
}
