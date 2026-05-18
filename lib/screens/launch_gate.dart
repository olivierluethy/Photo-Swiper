import 'dart:async';
import 'package:flutter/material.dart';

import '../services/purchase_service.dart';
import 'paywall_screen.dart';

/// Splash gate shown on returning cold launches. While the RevenueCat SDK
/// finishes warming up we hold the user on a dark screen, then route to
/// `/home` if their entitlement is active or to the mandatory paywall
/// otherwise. The user can never end up on `/home` without an entitlement —
/// even if their previous session left the paywall up, the next cold launch
/// re-routes them through here.
class LaunchGate extends StatefulWidget {
  const LaunchGate({super.key});

  @override
  State<LaunchGate> createState() => _LaunchGateState();
}

class _LaunchGateState extends State<LaunchGate> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _route());
  }

  Future<void> _route() async {
    await PurchaseService.instance.waitForInit();
    if (!mounted) return;

    if (PurchaseService.instance.isPro) {
      Navigator.of(context).pushReplacementNamed('/home');
      return;
    }

    // Non-subscriber returning launch → straight to the mandatory paywall.
    // PaywallSource.launchGate keeps the no-close / no-back behaviour while
    // tagging telemetry so we can split conversion by entry point.
    Navigator.of(context).pushReplacement(
      PageRouteBuilder(
        pageBuilder: (_, __, ___) =>
            const PaywallScreen(source: PaywallSource.launchGate),
        transitionDuration: const Duration(milliseconds: 320),
        transitionsBuilder: (_, anim, __, child) {
          final fade =
              CurvedAnimation(parent: anim, curve: Curves.easeOut);
          return FadeTransition(opacity: fade, child: child);
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return const Scaffold(backgroundColor: Color(0xFF0D0D0D));
  }
}
