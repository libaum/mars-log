import 'package:flutter/material.dart';
import 'package:mars_log/theme/theme_constants.dart';

/// German labels for the [kMoodDimensions] keys.
const dimensionLabels = {
  'positivity': 'Positivität',
  'energy': 'Energie',
  'calm': 'Ruhe',
  'stress': 'Stress',
  'focus': 'Fokus',
  'social': 'Sozialität',
};

/// One labeled 0..100 bar — used for a single entry's dimensions and for
/// a month's averaged dimensions alike.
class DimensionBar extends StatelessWidget {
  final String dimensionKey;
  final int value;
  final Color primary;
  const DimensionBar({
    super.key,
    required this.dimensionKey,
    required this.value,
    required this.primary,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(
        children: [
          SizedBox(
            width: 96,
            child: Text(dimensionLabels[dimensionKey] ?? dimensionKey,
                style: TEXT_STYLE_STATUS),
          ),
          Expanded(
            child: Stack(
              children: [
                Container(
                  height: 3,
                  decoration: BoxDecoration(
                    color: primary.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
                FractionallySizedBox(
                  widthFactor: (value / 100).clamp(0.0, 1.0),
                  child: Container(
                    height: 3,
                    decoration: BoxDecoration(
                      color: primary,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          SizedBox(
            width: 28,
            child: Text('$value',
                textAlign: TextAlign.right, style: TEXT_STYLE_STATUS),
          ),
        ],
      ),
    );
  }
}
