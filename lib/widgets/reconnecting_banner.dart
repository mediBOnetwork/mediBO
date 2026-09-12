// lib/widgets/reconnecting_banner.dart — CHANGE #1149
//
// The thin strip every screen shares while the backend is not answering. It
// draws only while Reconnecting.instance.down is true, prints the backend's
// own copy (ui_copy 'app.reconnecting'), and disappears the moment a request
// lands. It never blocks the page under it: the cached payload stays visible.
import 'package:flutter/material.dart';

import '../design_tokens.dart';
import '../services/resilient_http.dart';
import '../services/ui_copy.dart';
import '../utils/render_log.dart';

class ReconnectingBanner extends StatelessWidget {
  const ReconnectingBanner({super.key, this.flag});

  /// Injected in tests; the app uses the singleton.
  final Reconnecting? flag;

  @override
  Widget build(BuildContext context) {
    final f = flag ?? Reconnecting.instance;
    return AnimatedBuilder(
      animation: f,
      builder: (context, _) {
        if (!f.down) return const SizedBox.shrink();
        RenderLog.write('c1149_reconnecting', f.reason);
        return Material(
          color: Ds.c.warningSoft,
          child: SafeArea(
            bottom: false,
            child: Padding(
              padding: EdgeInsets.symmetric(
                  horizontal: Ds.space.x16, vertical: Ds.space.x8),
              child: Row(children: [
                SizedBox(
                  width: Ds.space.x12,
                  height: Ds.space.x12,
                  child: CircularProgressIndicator(
                      strokeWidth: 2, color: Ds.c.warning),
                ),
                SizedBox(width: Ds.space.x8),
                Expanded(
                  child: Text(c('app.reconnecting'),
                      style: Ds.t.caption.copyWith(
                          color: Ds.c.warning, fontWeight: FontWeight.w600),
                      overflow: TextOverflow.ellipsis),
                ),
              ]),
            ),
          ),
        );
      },
    );
  }
}
