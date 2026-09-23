import 'package:flutter/material.dart';

/// Colors — pure black/white, following Mars design language
const COLOR_LIGHT_BACKGROUND = Colors.white;
const COLOR_LIGHT_PRIMARY = Colors.black;

const COLOR_DARK_BACKGROUND = Colors.black;
const COLOR_DARK_PRIMARY = Colors.white;

const COLOR_SECONDARY = Color(0xFF888888);
const COLOR_DELETE = Color(0xFFC9184A);

/// Mood scale — the one deliberate exception to Mars' pure black/white rule,
/// and only ever on the data line of the mood map. The base map underneath
/// is a real street map in its own colours; the mood ramp is what sits on
/// top of it, so color here carries meaning, never decoration.
///
/// Mood is polarity (bad ↔ good), so this is a diverging scale: two hues
/// meeting at a neutral midpoint, one step per mood point (0-1 … 9-10),
/// red = bad, blue = good.
///
/// Stepped separately per mode against the app's real surfaces (pure white /
/// pure black) — don't "flip" one list to get the other. Both were checked
/// with the dataviz validator: **contrast ≥ 3:1 for all ten steps in both
/// modes**, and lightness is monotonic along each arm, so the order reads
/// even where neighbouring hues are close.
///
/// The dark ramp's midpoint is a *darker* gray than the light one on purpose:
/// dark mode runs bright at the extremes and dims toward the middle, so
/// reusing the light midpoint put a bright step between two darker ones and
/// broke the monotonicity.
///
/// Ten steps is finer than colour alone can resolve — adjacent steps are not
/// reliably distinguishable (that's inherent, not a bug). They give the line
/// a readable gradient; the exact number stays in the text beside it.
const MOOD_SCALE_LIGHT = <Color>[
  Color(0xFF8F1D26),
  Color(0xFFA4282F),
  Color(0xFFCE3E40),
  Color(0xFFCD5956),
  Color(0xFFA07873),
  Color(0xFF718396),
  Color(0xFF427CC1),
  Color(0xFF246BC1),
  Color(0xFF175096),
  Color(0xFF104281),
];

const MOOD_SCALE_DARK = <Color>[
  Color(0xFFE66767),
  Color(0xFFDD5E60),
  Color(0xFFCA4B51),
  Color(0xFFA8484E),
  Color(0xFF775756),
  Color(0xFF536275),
  Color(0xFF3B6BAA),
  Color(0xFF4581CF),
  Color(0xFF70A4E4),
  Color(0xFF86B6EF),
];

/// Colour for a 0-10 mood [score] on the given theme. A null score (no entry
/// that day) has no place on the scale — callers render it as the neutral
/// midpoint *plus* a dashed stroke, so "no data" never reads as "middling
/// mood".
Color moodColor(double? score, {required bool isDark}) {
  final scale = isDark ? MOOD_SCALE_DARK : MOOD_SCALE_LIGHT;
  if (score == null) return scale[scale.length ~/ 2];
  final step = score.floor().clamp(0, scale.length - 1);
  return scale[step];
}

/// Font
const FONT_FAMILY = 'Outfit';

/// Text styles — fontFamily set via ThemeData, not per-style
const TEXT_STYLE_TITLE = TextStyle(
  fontSize: 28,
  fontWeight: FontWeight.w300,
);

const TEXT_STYLE_SCORE = TextStyle(
  fontSize: 36,
  fontWeight: FontWeight.w300,
  fontFeatures: [FontFeature.tabularFigures()],
  height: 1.1,
);

const TEXT_STYLE_DATE = TextStyle(
  fontSize: 14,
  fontWeight: FontWeight.w400,
  letterSpacing: 1.0,
  color: COLOR_SECONDARY,
);

const TEXT_STYLE_SUMMARY = TextStyle(
  fontSize: 16,
  fontWeight: FontWeight.w300,
  height: 1.4,
);

const TEXT_STYLE_BODY = TextStyle(
  fontSize: 16,
  fontWeight: FontWeight.w300,
  height: 1.5,
);

const TEXT_STYLE_LABEL = TextStyle(
  fontSize: 14,
  fontWeight: FontWeight.w400,
  letterSpacing: 1.0,
  color: COLOR_SECONDARY,
);

const TEXT_STYLE_STATUS = TextStyle(
  fontSize: 12,
  fontWeight: FontWeight.w300,
  color: COLOR_SECONDARY,
);

const TEXT_STYLE_SETTING = TextStyle(
  fontSize: 16,
  fontWeight: FontWeight.w300,
);

/// Shared settings-screen row styles (see Mars DESIGN.md)
const TEXT_STYLE_SETTINGS_TITLE = TextStyle(fontSize: 30, fontWeight: FontWeight.w300);
const TEXT_STYLE_SETTINGS_ITEM = TextStyle(fontSize: 19, fontWeight: FontWeight.w300);
const TEXT_STYLE_SETTINGS_DESCRIPTION = TextStyle(
  fontSize: 13,
  fontWeight: FontWeight.w300,
  color: COLOR_SECONDARY,
);
const TEXT_STYLE_SETTINGS_TRAILING = TextStyle(
  fontSize: 16,
  fontWeight: FontWeight.w300,
  color: COLOR_SECONDARY,
);

/// Theme builders
ThemeData buildLightTheme() => ThemeData(
      colorScheme: const ColorScheme.light(
        surface: COLOR_LIGHT_BACKGROUND,
        primary: COLOR_LIGHT_PRIMARY,
        brightness: Brightness.light,
      ),
      fontFamily: FONT_FAMILY,
      scaffoldBackgroundColor: COLOR_LIGHT_BACKGROUND,
      brightness: Brightness.light,
      iconTheme: const IconThemeData(color: COLOR_LIGHT_PRIMARY),
      textButtonTheme: TextButtonThemeData(
        style: ButtonStyle(
          foregroundColor: WidgetStateProperty.all<Color>(COLOR_LIGHT_PRIMARY),
          overlayColor: WidgetStateProperty.all<Color>(Colors.transparent),
        ),
      ),
    );

ThemeData buildDarkTheme() => ThemeData(
      colorScheme: const ColorScheme.dark(
        surface: COLOR_DARK_BACKGROUND,
        primary: COLOR_DARK_PRIMARY,
        brightness: Brightness.dark,
      ),
      fontFamily: FONT_FAMILY,
      scaffoldBackgroundColor: COLOR_DARK_BACKGROUND,
      brightness: Brightness.dark,
      iconTheme: const IconThemeData(color: COLOR_DARK_PRIMARY),
      textButtonTheme: TextButtonThemeData(
        style: ButtonStyle(
          foregroundColor: WidgetStateProperty.all<Color>(COLOR_DARK_PRIMARY),
          overlayColor: WidgetStateProperty.all<Color>(Colors.transparent),
        ),
      ),
    );
