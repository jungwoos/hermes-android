// The brand hero — plasma orb over the HERMES wordmark — used as the
// centrepiece of empty states on the home screen and the split-view detail
// pane.
import 'package:flutter/material.dart';

import '../theme.dart';
import 'plasma_orb.dart';

class HermesHeader extends StatelessWidget {
  const HermesHeader({super.key, this.subtitle, this.orbSize = 148});

  final String? subtitle;
  final double orbSize;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        PlasmaOrb(size: orbSize),
        const SizedBox(height: 28),
        Text(
          'HERMES',
          style: hermesBrandTextStyle(
            fontSize: 24,
            fontWeight: FontWeight.w700,
            letterSpacing: 10,
            color: theme.colorScheme.onSurface,
          ),
        ),
        if (subtitle != null) ...[
          const SizedBox(height: 10),
          Text(
            subtitle!,
            textAlign: TextAlign.center,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
              height: 1.5,
            ),
          ),
        ],
      ],
    );
  }
}
