import 'dart:async';

import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

import 'render_log.dart';

/// CMD #1950 — MOBILE-FIRST: the app audits its own phone layout.
///
/// 99% of mediBO users are on phones, and a Flutter web app paints to canvas —
/// no browser tool can measure a tap target or a clipped row from outside. So
/// the measuring happens INSIDE the app, over the semantics tree Flutter
/// already builds, and the answer is written to the render log where the
/// post-deploy sweep (`scripts/responsive_sweep.js`) and `rg_check` can read a
/// number instead of guessing from pixels.
///
/// It is inert unless the page was opened with `?responsive_audit=1`, so a real
/// visitor never pays for it: enabling semantics costs a tree build, and this
/// is a diagnostic, not a feature.
///
/// The minimum comes from the backend (`build_rules.mobile_first.min_touch_px`,
/// passed in by the sweep as `?min_touch=44`) — the number is never decided in
/// Dart.
class ResponsiveAudit {
  ResponsiveAudit._();

  static bool _enabled = false;
  static int _minTouchPx = 44;
  static SemanticsHandle? _handle;
  static bool _scheduled = false;
  static Timer? _repeat;
  static int _seenTappable = 0;
  static int _seenSmall = 0;

  /// Called once at boot with the page's query parameters. Returns quietly on
  /// anything unexpected: a diagnostic must never be the thing that stops a
  /// boot (boot resilience rule).
  static void configureFromQuery(Map<String, String> params) {
    try {
      if (params['responsive_audit'] != '1') return;
      _enabled = true;
      final min = int.tryParse(params['min_touch'] ?? '');
      if (min != null && min > 0) _minTouchPx = min;
      // Semantics are off on web until something asks for them. The audit is
      // that something; the handle is deliberately never released, because the
      // page is thrown away at the end of each sweep step.
      _handle ??= SemanticsBinding.instance.ensureSemantics();
      RenderLog.write('responsive_audit', 'on min_touch=$_minTouchPx');
      // A screen finishes arriving well after its first frame — its RPC has to
      // land first. So the audit re-measures for a while instead of trusting
      // one frame, and the highest count it ever saw is the one the sweep
      // reads. It stops on its own; the page is thrown away between steps.
      var passes = 0;
      _repeat?.cancel();
      _repeat = Timer.periodic(const Duration(seconds: 2), (t) {
        passes++;
        if (passes > 8) {
          t.cancel();
          return;
        }
        _measure();
      });
    } catch (_) {}
  }

  static bool get enabled => _enabled;

  /// Re-measures after the frame this was called in. Safe to call on every
  /// build: the work is collapsed to one pass per frame.
  static void schedule() {
    if (!_enabled || _scheduled) return;
    _scheduled = true;
    try {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _scheduled = false;
        _measure();
      });
    } catch (_) {
      _scheduled = false;
    }
  }

  static void _measure() {
    try {
      final root = WidgetsBinding
          .instance.rootPipelineOwner.semanticsOwner?.rootSemanticsNode;
      if (root == null) return;
      var small = 0;
      var tappable = 0;
      String? worst;
      var worstSide = double.infinity;

      void visit(SemanticsNode node) {
        final data = node.getSemanticsData();
        final isTap = (data.actions & SemanticsAction.tap.index) != 0;
        if (isTap) {
          tappable++;
          // The rect is in the node's own coordinates; the transform carries
          // the scale the ancestors applied, which is what the finger meets.
          final rect = MatrixUtils.transformRect(
              node.transform ?? Matrix4.identity(), node.rect);
          final side = rect.width < rect.height ? rect.width : rect.height;
          if (side > 0 && side < _minTouchPx) {
            small++;
            if (side < worstSide) {
              worstSide = side;
              final label = data.label.isEmpty ? '(unlabelled)' : data.label;
              worst = '${label.length > 40 ? label.substring(0, 40) : label} '
                  '${rect.width.round()}x${rect.height.round()}';
            }
          }
        }
        node.visitChildren((child) {
          visit(child);
          return true;
        });
      }

      visit(root);
      if (tappable > _seenTappable) {
        _seenTappable = tappable;
        RenderLog.write('tap_targets', tappable);
      }
      if (small > _seenSmall) {
        _seenSmall = small;
        RenderLog.write('tap_targets_small', small);
        if (worst != null) RenderLog.write('tap_target_worst', worst);
      }
    } catch (_) {
      // A failed measurement is silence, never a broken screen.
    }
  }
}
