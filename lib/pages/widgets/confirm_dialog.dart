import 'package:flutter/material.dart';
import 'package:mars_log/theme/theme_constants.dart';

/// Minimal yes/no confirmation, Mars-styled. Returns true only on confirm.
Future<bool> showConfirmDialog(
  BuildContext context, {
  required String title,
  String? message,
  String confirmLabel = 'Löschen',
  String cancelLabel = 'Abbrechen',
}) async {
  final result = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(title, style: TEXT_STYLE_SETTING),
      content: message == null ? null : Text(message, style: TEXT_STYLE_STATUS),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: Text(cancelLabel),
        ),
        TextButton(
          onPressed: () => Navigator.pop(context, true),
          child: Text(confirmLabel,
              style: const TextStyle(color: COLOR_SECONDARY)),
        ),
      ],
    ),
  );
  return result ?? false;
}
