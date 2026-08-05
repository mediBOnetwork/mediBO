import 'package:flutter/material.dart';

/// Neutral placeholder shown on Android for screens whose web-only tooling
/// (browser file pickers, canvas OCR, SpeechSynthesis, Web Share) has no native
/// implementation in this build. It carries NO user-facing copy — per the repo
/// rule the app renders, it does not invent wording. These are admin/supplier
/// power tools; the full experience lives on the medibo.in web dashboard.
class PlatformUnavailableScreen extends StatelessWidget {
  const PlatformUnavailableScreen({super.key});
  @override
  Widget build(BuildContext context) => const Scaffold(
        body: Center(
          child: Icon(Icons.computer_outlined, size: 56, color: Color(0xFFBDBDBD)),
        ),
      );
}
