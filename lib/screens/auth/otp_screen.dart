import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class OtpScreen extends StatefulWidget {
  final String phone; // E.164 format: +91XXXXXXXXXX
  const OtpScreen({super.key, required this.phone});

  @override
  State<OtpScreen> createState() => _OtpScreenState();
}

class _OtpScreenState extends State<OtpScreen> {
  final List<TextEditingController> _ctrls =
      List.generate(6, (_) => TextEditingController());
  final List<FocusNode> _fNodes = List.generate(6, (_) => FocusNode());

  bool _loading = false;
  String? _error;
  int _countdown = 30;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _startCountdown();
    WidgetsBinding.instance
        .addPostFrameCallback((_) => _fNodes[0].requestFocus());
  }

  @override
  void dispose() {
    for (final c in _ctrls) c.dispose();
    for (final f in _fNodes) f.dispose();
    _timer?.cancel();
    super.dispose();
  }

  void _startCountdown() {
    _timer?.cancel();
    setState(() => _countdown = 30);
    _timer = Timer.periodic(const Duration(seconds: 1), (t) {
      if (!mounted) {
        t.cancel();
        return;
      }
      if (_countdown <= 1) {
        t.cancel();
        setState(() => _countdown = 0);
      } else {
        setState(() => _countdown--);
      }
    });
  }

  String get _otp => _ctrls.map((c) => c.text).join();

  void _onDigitChanged(int index, String value) {
    if (value.isEmpty) {
      if (index > 0) {
        _fNodes[index - 1].requestFocus();
      }
      return;
    }
    // Keep only last character if more than 1 was somehow entered
    final digit = value[value.length - 1];
    _ctrls[index].text = digit;
    _ctrls[index].selection =
        TextSelection.collapsed(offset: 1);

    if (index < 5) {
      _fNodes[index + 1].requestFocus();
    } else {
      _fNodes[index].unfocus();
      _verify();
    }
  }

  void _onBackspace(int index) {
    if (_ctrls[index].text.isEmpty && index > 0) {
      _ctrls[index - 1].clear();
      _fNodes[index - 1].requestFocus();
    }
  }

  Future<void> _resend() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      await Supabase.instance.client.auth
          .signInWithOtp(phone: widget.phone);
      for (final c in _ctrls) c.clear();
      if (mounted) {
        _fNodes[0].requestFocus();
        _startCountdown();
      }
    } catch (_) {
      if (mounted) setState(() => _error = 'Could not resend OTP. Try again.');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _verify() async {
    final otp = _otp;
    if (otp.length < 6) {
      setState(() => _error = 'Enter all 6 digits');
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      await Supabase.instance.client.auth.verifyOTP(
        phone: widget.phone,
        token: otp,
        type: OtpType.sms,
      );
      // Auth state change fires → AuthNotifier loads profile → root rebuilds.
      if (!mounted) return;
      Navigator.of(context).popUntil((r) => r.isFirst);
    } on AuthException catch (e) {
      if (mounted) setState(() {
        _error = e.message;
        _loading = false;
      });
    } catch (_) {
      if (mounted) setState(() {
        _error = 'Verification failed. Check the OTP and try again.';
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    // Mask phone: +91 98765•••••
    final raw = widget.phone.replaceFirst('+91', '');
    final maskedPhone =
        '+91 ${raw.substring(0, 5)}${'•' * (raw.length - 5)}';

    return Scaffold(
      backgroundColor: Colors.white,
      appBar: AppBar(
        backgroundColor: Colors.white,
        elevation: 0,
        scrolledUnderElevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_ios_new,
              size: 20, color: Color(0xFF111827)),
          onPressed: () => Navigator.pop(context),
        ),
        title: const Text(
          'Verify OTP',
          style: TextStyle(
            fontSize: 18,
            fontWeight: FontWeight.w700,
            color: Color(0xFF111827),
          ),
        ),
      ),
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding:
                const EdgeInsets.symmetric(horizontal: 28, vertical: 32),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const SizedBox(height: 8),
                  Text(
                    'OTP sent to $maskedPhone',
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      fontSize: 15,
                      color: Color(0xFF6B7280),
                      height: 1.5,
                    ),
                  ),
                  const SizedBox(height: 40),
                  // 6-digit boxes
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: List.generate(
                      6,
                      (i) => _OtpBox(
                        controller: _ctrls[i],
                        focusNode: _fNodes[i],
                        onChanged: (v) => _onDigitChanged(i, v),
                        onBackspace: () => _onBackspace(i),
                      ),
                    ),
                  ),
                  if (_error != null) ...[
                    const SizedBox(height: 14),
                    Text(
                      _error!,
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                          fontSize: 13, color: Color(0xFFDC2626)),
                    ),
                  ],
                  const SizedBox(height: 36),
                  // Verify button
                  SizedBox(
                    height: 52,
                    child: FilledButton(
                      onPressed: _loading ? null : _verify,
                      style: FilledButton.styleFrom(
                        backgroundColor: const Color(0xFF1B5E20),
                        disabledBackgroundColor:
                            const Color(0xFF1B5E20).withValues(alpha: 0.5),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(10),
                        ),
                        textStyle: const TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      child: _loading
                          ? const SizedBox(
                              width: 22,
                              height: 22,
                              child: CircularProgressIndicator(
                                color: Colors.white,
                                strokeWidth: 2.5,
                              ),
                            )
                          : const Text('Verify OTP'),
                    ),
                  ),
                  const SizedBox(height: 24),
                  // Resend
                  Center(
                    child: _countdown > 0
                        ? Text(
                            'Resend OTP in ${_countdown}s',
                            style: const TextStyle(
                                fontSize: 13, color: Color(0xFF9CA3AF)),
                          )
                        : TextButton(
                            onPressed: _loading ? null : _resend,
                            style: TextButton.styleFrom(
                              foregroundColor: const Color(0xFF1B5E20),
                            ),
                            child: const Text(
                              'Resend OTP',
                              style: TextStyle(fontWeight: FontWeight.w700),
                            ),
                          ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// ─── Single OTP digit box ─────────────────────────────────────────────────────

class _OtpBox extends StatefulWidget {
  final TextEditingController controller;
  final FocusNode focusNode;
  final ValueChanged<String> onChanged;
  final VoidCallback onBackspace;

  const _OtpBox({
    required this.controller,
    required this.focusNode,
    required this.onChanged,
    required this.onBackspace,
  });

  @override
  State<_OtpBox> createState() => _OtpBoxState();
}

class _OtpBoxState extends State<_OtpBox> {
  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onCtrlChange);
  }

  void _onCtrlChange() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onCtrlChange);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final filled = widget.controller.text.isNotEmpty;
    return SizedBox(
      width: 46,
      height: 58,
      child: Focus(
        onKeyEvent: (_, event) {
          if (event is KeyDownEvent &&
              event.logicalKey == LogicalKeyboardKey.backspace &&
              widget.controller.text.isEmpty) {
            widget.onBackspace();
            return KeyEventResult.handled;
          }
          return KeyEventResult.ignored;
        },
        child: TextField(
          controller: widget.controller,
          focusNode: widget.focusNode,
          textAlign: TextAlign.center,
          keyboardType: TextInputType.number,
          inputFormatters: [
            FilteringTextInputFormatter.digitsOnly,
            LengthLimitingTextInputFormatter(2),
          ],
          onChanged: widget.onChanged,
          style: const TextStyle(
            fontSize: 24,
            fontWeight: FontWeight.w800,
            color: Color(0xFF111827),
            height: 1,
          ),
          decoration: InputDecoration(
            isDense: true,
            contentPadding: EdgeInsets.zero,
            filled: true,
            fillColor: filled
                ? const Color(0xFFECFDF5)
                : const Color(0xFFF9FAFB),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(10),
              borderSide: const BorderSide(color: Color(0xFFE5E7EB)),
            ),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(10),
              borderSide: BorderSide(
                color: filled
                    ? const Color(0xFF16A34A)
                    : const Color(0xFFE5E7EB),
              ),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(10),
              borderSide: const BorderSide(
                  color: Color(0xFF1B5E20), width: 2),
            ),
          ),
        ),
      ),
    );
  }
}
