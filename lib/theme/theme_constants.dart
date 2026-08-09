import 'package:flutter/material.dart';

/// Colors — pure black/white, following Mars design language
const COLOR_LIGHT_BACKGROUND = Colors.white;
const COLOR_LIGHT_PRIMARY = Colors.black;

const COLOR_DARK_BACKGROUND = Colors.black;
const COLOR_DARK_PRIMARY = Colors.white;

const COLOR_SECONDARY = Color(0xFF888888);
const COLOR_DELETE = Color(0xFFC9184A);

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
