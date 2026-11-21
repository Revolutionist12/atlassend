import 'package:flutter/material.dart';
import 'package:localsend_app/atlassend/atlas_identity.dart';

/// AtlasSend: the app icon (iOS squircle) instead of the upstream logo.
class LocalSendLogo extends StatelessWidget {
  final bool withText;

  const LocalSendLogo({required this.withText});

  @override
  Widget build(BuildContext context) {
    final logo = ClipRSuperellipse(
      borderRadius: BorderRadius.circular(200 * 0.225),
      child: Image.asset('assets/img/atlassend-512.png', width: 200, height: 200, filterQuality: FilterQuality.medium),
    );

    if (withText) {
      return Column(
        children: [
          logo,
          const SizedBox(height: 16),
          const Text(
            kAtlasAppName,
            style: TextStyle(fontSize: 34, fontWeight: FontWeight.w700, letterSpacing: -0.9),
            textAlign: TextAlign.center,
          ),
        ],
      );
    } else {
      return logo;
    }
  }
}
