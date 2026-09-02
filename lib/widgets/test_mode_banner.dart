import 'package:flutter/material.dart';

import '../design_tokens.dart';
import '../services/test_session.dart';

/// CHANGE #573 — the unmissable TEST MODE strip.
///
/// It is mounted once, in `MaterialApp.builder`, above every route of every
/// role, exactly like the update bar. That placement is the point: Om walks
/// the flow from an admin, a customer, a supplier, a partner and a rider
/// login, and none of those screens has to know test mode exists.
///
/// The host reflows the page (SafeArea + Column) rather than floating over it,
/// because a banner that can be scrolled behind is a banner he can forget.
class TestModeBannerHost extends StatelessWidget {
  const TestModeBannerHost({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<Map<String, dynamic>>(
      valueListenable: TestSessionState.instance.banner,
      builder: (context, payload, _) {
        if (payload['on'] != true) return child;
        return Column(
          children: [
            TestModeBanner(payload: payload),
            Expanded(child: child),
          ],
        );
      },
    );
  }
}

/// The strip itself — pure presentation, so a widget test mounts it with a
/// fixture payload and no network, no timer and no service singleton.
class TestModeBanner extends StatelessWidget {
  const TestModeBanner({super.key, required this.payload});

  final Map<String, dynamic> payload;

  String _s(String key) {
    final v = payload[key];
    return v is String ? v : '';
  }

  @override
  Widget build(BuildContext context) {
    final label = _s('label');
    final ends = _s('ends_label');
    return Material(
      color: Ds.c.danger,
      child: SafeArea(
        bottom: false,
        child: Padding(
          padding: EdgeInsets.symmetric(
            horizontal: Ds.space.x16,
            vertical: Ds.space.x8,
          ),
          child: Row(
            children: [
              Container(
                padding: EdgeInsets.symmetric(
                  horizontal: Ds.space.x8,
                  vertical: Ds.space.x4,
                ),
                decoration: BoxDecoration(
                  color: Ds.c.surface,
                  borderRadius: Ds.r.rChip,
                ),
                child: Text(
                  _s('badge'),
                  style: Ds.t.caption.copyWith(
                    color: Ds.c.danger,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              SizedBox(width: Ds.space.x12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      _s('text'),
                      style: Ds.t.body.copyWith(
                        color: Ds.c.surface,
                        fontWeight: FontWeight.w700,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    if (label.isNotEmpty || ends.isNotEmpty)
                      Text(
                        [label, ends].where((s) => s.isNotEmpty).join('  ·  '),
                        style: Ds.t.caption.copyWith(color: Ds.c.surface),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
