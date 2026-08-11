import 'package:flutter/material.dart';
import 'package:mars_log/pages/widgets/double_tap_theme_toggle.dart';
import 'package:mars_log/theme/theme_constants.dart';
import 'package:url_launcher/url_launcher.dart';

// Shared across all Mars apps (single Play Console developer account).
const _MARS_DEV_PAGE = 'https://play.google.com/store/apps/dev?id=7784376568737667246';
const _SUPPORT_EMAIL = 'contact@catchingclouds.de';
// Not yet on the Play Store — add a "Rate Mars Log" link on publish
// (applicationId com.catchingclouds.marslog).

class AboutScreen extends StatelessWidget {
  const AboutScreen({super.key});

  Future<void> _open(String url) async {
    await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
  }

  @override
  Widget build(BuildContext context) {
    final primary = Theme.of(context).colorScheme.primary;

    return DoubleTapThemeToggle(
      child: Scaffold(
        body: SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(28, 20, 28, 20),
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Mars Log', style: TEXT_STYLE_TITLE.copyWith(color: primary)),
                  const SizedBox(height: 32),
                  // This app — personal "why" + the single idea.
                  Text(
                    'I always wanted to keep a journal and never stuck with one. Typing at the end of the day felt like work, so the habit never formed. Talking, I could do. So I built a journal I could just speak.',
                    style: TextStyle(fontSize: 15, fontWeight: FontWeight.w300, color: primary, height: 1.7),
                  ),
                  const SizedBox(height: 24),
                  Text(
                    'Tap once and talk. The entry writes itself: transcript, a short summary, mood and tags, all derived automatically. Your recording and your words stay the source of truth, and the rest can be recomputed anytime.',
                    style: TextStyle(fontSize: 15, fontWeight: FontWeight.w300, color: primary, height: 1.7),
                  ),
                  const SizedBox(height: 16),
                  // Honest disclosure: audio leaves the device for transcription.
                  const Text(
                    'Voice recordings are transcribed by Google Gemini.',
                    style: TextStyle(fontSize: 13, fontWeight: FontWeight.w300, color: COLOR_SECONDARY, height: 1.5),
                  ),
                  const SizedBox(height: 32),
                  const Text('—', style: TextStyle(fontSize: 15, color: COLOR_SECONDARY)),
                  const SizedBox(height: 32),
                  // About Mars — shared philosophy, identical across all apps.
                  const Text(
                    'Mars — Minimalist And Really Simple. A growing family of small, calm tools built around one idea: solve one problem well, and never fight for your attention. No ads, no tracking, nothing built to keep you hooked. Made by one person, out of conviction — tools that work for you, not on you.',
                    style: TextStyle(fontSize: 15, fontWeight: FontWeight.w300, color: COLOR_SECONDARY, height: 1.7),
                  ),
                  const SizedBox(height: 40),
                  _LinkRow(label: 'More Mars apps', onTap: () => _open(_MARS_DEV_PAGE)),
                  _LinkRow(label: 'Get in touch', onTap: () => _open('mailto:$_SUPPORT_EMAIL?subject=Mars%20Log%20feedback')),
                  const SizedBox(height: 20),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _LinkRow extends StatelessWidget {
  final String label;
  final VoidCallback onTap;

  const _LinkRow({required this.label, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final primary = Theme.of(context).colorScheme.primary;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 12),
        child: Row(
          children: [
            Expanded(
              child: Text(label, style: TextStyle(fontSize: 16, fontWeight: FontWeight.w300, color: primary)),
            ),
            Icon(Icons.north_east, size: 18, color: primary.withValues(alpha: 0.3)),
          ],
        ),
      ),
    );
  }
}
