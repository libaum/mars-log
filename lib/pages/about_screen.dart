import 'package:flutter/material.dart';
import 'package:mars_log/pages/widgets/double_tap_theme_toggle.dart';
import 'package:mars_log/theme/theme_constants.dart';

class AboutScreen extends StatelessWidget {
  const AboutScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return DoubleTapThemeToggle(
      child: Scaffold(
        body: SafeArea(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(32, 32, 32, 48),
            children: const [
              Text('About', style: TEXT_STYLE_TITLE),
              SizedBox(height: 40),
              Text('ABOUT MARS', style: TEXT_STYLE_LABEL),
              SizedBox(height: 12),
              Text(
                'Mars is a collection of simple tools designed to reduce '
                'friction and focus on what matters. No ads. No unnecessary '
                'features. Just useful software.',
                style: TEXT_STYLE_BODY,
              ),
              SizedBox(height: 32),
              Text('THIS APP', style: TEXT_STYLE_LABEL),
              SizedBox(height: 12),
              Text(
                'Mars Log is a voice journal. Tap once, talk, and the entry '
                'writes itself — transcript, summary, mood and tags are '
                'derived automatically. Your audio and words stay the source '
                'of truth; the interpretation can be recomputed anytime.',
                style: TEXT_STYLE_BODY,
              ),
              SizedBox(height: 32),
              Text('OTHER MARS APPS', style: TEXT_STYLE_LABEL),
              SizedBox(height: 12),
              Text(
                'Mars FX · Mars Timer · Mars Launcher · Mars Thoughts · '
                'Mars Sky · Mars North',
                style: TEXT_STYLE_BODY,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
