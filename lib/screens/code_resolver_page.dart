import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../utils/render_log.dart';

const _kGreen       = Color(0xFF1B7A43);
const _kBg          = Color(0xFFF5F6F8);
const _kCard        = Color(0xFFFFFFFF);
const _kBorder      = Color(0xFFE5E7EB);
const _kTextPrimary = Color(0xFF111827);
const _kTextMuted   = Color(0xFF6B7280);

/// Resolves a short tracking code (e.g. SPO300626SAG100O1) to a full token
/// and redirects to the appropriate viewer page.
class CodeResolverPage extends StatefulWidget {
  final String code;
  const CodeResolverPage({super.key, required this.code});

  @override
  State<CodeResolverPage> createState() => _CodeResolverPageState();
}

class _CodeResolverPageState extends State<CodeResolverPage> {
  bool _resolved = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    RenderLog.write('c317_code_route_built', 'code=${widget.code}');
    _resolve();
  }

  Future<void> _resolve() async {
    RenderLog.write('c317_resolve_called', 'code=${widget.code}');
    try {
      final result = await Supabase.instance.client
          .rpc('resolve_code', params: {'p_code': widget.code.toUpperCase().trim()});
      if (!mounted) return;

      final data = result is Map
          ? Map<String, dynamic>.from(result)
          : <String, dynamic>{};

      final kind  = data['kind']  as String? ?? '';
      final token = data['token'] as String? ?? '';

      if (kind.isEmpty || token.isEmpty) {
        setState(() { _error = 'notfound'; _resolved = true; });
        return;
      }

      if (kind == 'order') {
        Navigator.of(context).pushReplacementNamed('/order/$token');
      } else if (kind == 'inquiry') {
        Navigator.of(context).pushReplacementNamed('/inquiry/$token');
      } else if (kind == 'dispute') {
        Navigator.of(context).pushReplacementNamed('/dispute/$token');
      } else {
        setState(() { _error = 'notfound'; _resolved = true; });
      }
    } catch (_) {
      if (!mounted) return;
      setState(() { _error = 'notfound'; _resolved = true; });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _kBg,
      appBar: AppBar(
        backgroundColor: _kGreen,
        elevation: 0,
        automaticallyImplyLeading: false,
        title: const Text('mediBO',
            style: TextStyle(color: Colors.white, fontWeight: FontWeight.w700, fontSize: 18)),
      ),
      body: Center(
        child: _resolved && _error != null
            ? _buildNotFound(context)
            : _buildLoading(),
      ),
    );
  }

  Widget _buildLoading() {
    return const Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        CircularProgressIndicator(color: _kGreen, strokeWidth: 2.5),
        SizedBox(height: 16),
        Text('Opening your link…',
            style: TextStyle(fontSize: 15, color: _kTextMuted)),
      ],
    );
  }

  Widget _buildNotFound(BuildContext ctx) {
    return Padding(
      padding: const EdgeInsets.all(32),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 72,
            height: 72,
            decoration: BoxDecoration(
              color: const Color(0xFFF3F4F6),
              borderRadius: BorderRadius.circular(20),
            ),
            child: const Icon(Icons.link_off_outlined,
                size: 36, color: Color(0xFF9CA3AF)),
          ),
          const SizedBox(height: 20),
          const Text(
            'Link not found or expired',
            style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.w700,
                color: _kTextPrimary),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 8),
          const Text(
            'Please contact mediBO for assistance.',
            style: TextStyle(fontSize: 14, color: _kTextMuted),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 28),
          Container(
            decoration: BoxDecoration(
              color: _kCard,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: _kBorder),
            ),
            child: InkWell(
              borderRadius: BorderRadius.circular(10),
              onTap: () => Navigator.of(ctx).pushReplacementNamed('/'),
              child: const Padding(
                padding: EdgeInsets.symmetric(horizontal: 24, vertical: 14),
                child: Text('Go to mediBO',
                    style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        color: _kGreen)),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
