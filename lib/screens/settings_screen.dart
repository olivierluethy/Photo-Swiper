import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:photo_manager/photo_manager.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:in_app_review/in_app_review.dart';
import '../services/analytics_service.dart';
import '../services/preferences_service.dart';
import '../services/purchase_service.dart';
import 'paywall_screen.dart';

// Replace with real values before shipping
// Aktualisierte Werte für FlickClean
const _kAppStoreId = '6761820156';
const _kSupportEmail = 'business.promptin@gmail.com'; // Prüfe, ob diese Adresse korrekt ist
const _kShareText =
    'Check out FlickClean – the fastest way to clean up your photo library! 📷\n'
    'https://apps.apple.com/app/id$_kAppStoreId';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen>
    with WidgetsBindingObserver {
  late bool _leftHanded;
  late bool _showCompleted;
  PermissionState? _permissionStatus;
  String _version = '';

  @override
  void initState() {
    super.initState();
    _leftHanded = PreferencesService.instance.isLeftHanded;
    _showCompleted = PreferencesService.instance.showCompletedMonths;
    WidgetsBinding.instance.addObserver(this);
    unawaited(AnalyticsService.instance.screen('settings_screen'));
    _loadPermissionStatus();
    _loadVersion();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  // Refresh permission badge whenever the user returns from System Settings
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _loadPermissionStatus();
    }
  }

  Future<void> _loadPermissionStatus() async {
    final status = await PhotoManager.requestPermissionExtend();
    if (mounted) setState(() => _permissionStatus = status);
  }

  Future<void> _loadVersion() async {
    try {
      final info = await PackageInfo.fromPlatform();
      if (mounted) setState(() => _version = info.version);
    } catch (_) {}
  }

  // ─── Actions ─────────────────────────────────────────────────────────────────

  Future<void> _setLeftHanded(bool value) async {
    HapticFeedback.selectionClick();
    setState(() => _leftHanded = value);
    await PreferencesService.instance.setLeftHanded(value);
  }

  Future<void> _setShowCompleted(bool value) async {
    HapticFeedback.selectionClick();
    setState(() => _showCompleted = value);
    await PreferencesService.instance.setShowCompletedMonths(value);
  }

  Future<void> _rateApp() async {
    HapticFeedback.lightImpact();
    try {
      final review = InAppReview.instance;
      if (await review.isAvailable()) {
        await review.requestReview();
      } else {
        await review.openStoreListing(appStoreId: _kAppStoreId);
      }
    } catch (_) {
      // Silently ignore: review dialog not available in dev / TestFlight builds
    }
  }

  Future<void> _shareApp() async {
    HapticFeedback.lightImpact();
    await Share.share(_kShareText, subject: 'Photo Swiper');
  }

  Future<void> _contactSupport() async {
    HapticFeedback.lightImpact();
    final uri = Uri(
      scheme: 'mailto',
      path: _kSupportEmail,
      queryParameters: {
        'subject': 'Photo Swiper Support',
        'body':
            'Hi,\n\nI need help with...\n\n'
            '---\nApp version: ${_version.isNotEmpty ? _version : 'unknown'}',
      },
    );
    if (!await launchUrl(uri)) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('No email client found'),
            backgroundColor: Color(0xFF2C2C2E),
          ),
        );
      }
    }
  }

  void _openPermissionSettings() {
    HapticFeedback.lightImpact();
    PhotoManager.openSetting();
  }

  // ─── Permission badge helpers ─────────────────────────────────────────────────

  String get _permissionLabel {
    if (_permissionStatus == null) return 'Checking…';
    if (_permissionStatus!.isAuth) return 'Full Access';
    if (_permissionStatus == PermissionState.limited) return 'Limited';
    return 'No Access';
  }

  Color get _permissionColor {
    if (_permissionStatus == null) return const Color(0xFF8E8E93);
    if (_permissionStatus!.isAuth) return const Color(0xFF30D158);
    if (_permissionStatus == PermissionState.limited) return const Color(0xFFFFD60A);
    return const Color(0xFFFF453A);
  }

  // ─── Build ───────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0D0D0D),
      appBar: AppBar(
        backgroundColor: const Color(0xFF0D0D0D),
        surfaceTintColor: Colors.transparent,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_ios_rounded, color: Colors.white),
          onPressed: () => Navigator.pop(context),
        ),
        title: const Text(
          'Settings',
          style: TextStyle(
            color: Colors.white,
            fontWeight: FontWeight.w700,
            fontSize: 20,
          ),
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 48),
        children: [
          // ── SUBSCRIPTION ───────────────────────────────────────────────────
          const _SectionLabel('SUBSCRIPTION'),
          _SubscriptionCard(
            isPro: PurchaseService.instance.isPro,
            onTap: () {
              HapticFeedback.lightImpact();
              Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => const PaywallScreen(
                    source: PaywallSource.settings,
                  ),
                ),
              );
            },
          ),
          const SizedBox(height: 28),

          // ── SWIPE GESTURES ─────────────────────────────────────────────────
          const _SectionLabel('SWIPE GESTURES'),
          Container(
            decoration: _kCard,
            child: SwitchListTile(
              contentPadding: const EdgeInsets.fromLTRB(16, 6, 12, 6),
              secondary: _IconChip(
                icon: Icons.back_hand_rounded,
                color: const Color(0xFF6B4EFF),
              ),
              title: const Text(
                'Left-handed mode',
                style: TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.w600,
                  fontSize: 16,
                ),
              ),
              subtitle: const Text(
                'Swipe right to delete, left to keep',
                style: TextStyle(color: Color(0xFF8E8E93), fontSize: 13),
              ),
              value: _leftHanded,
              onChanged: _setLeftHanded,
              activeColor: const Color(0xFF6B4EFF),
            ),
          ),
          const SizedBox(height: 14),
          const _SectionLabel('PREVIEW'),
          AnimatedSwitcher(
            duration: const Duration(milliseconds: 300),
            transitionBuilder: (c, a) => FadeTransition(opacity: a, child: c),
            child: _SwipePreview(
              key: ValueKey(_leftHanded),
              leftHanded: _leftHanded,
            ),
          ),
          const SizedBox(height: 12),
          _TipBox(
            _leftHanded
                ? 'Left-handed mode is on. Swipe right to delete, left to keep.'
                : 'Default mode. Swipe right to keep, left to delete.',
          ),
          const SizedBox(height: 28),

          // ── VIEW ───────────────────────────────────────────────────────────
          const _SectionLabel('VIEW'),
          Container(
            decoration: _kCard,
            child: SwitchListTile(
              contentPadding: const EdgeInsets.fromLTRB(16, 6, 12, 6),
              secondary: _IconChip(
                icon: Icons.check_circle_outline_rounded,
                color: const Color(0xFF30D158),
              ),
              title: const Text(
                'Show completed months',
                style: TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.w600,
                  fontSize: 16,
                ),
              ),
              subtitle: const Text(
                'Keep finished months in the list. Turn off to hide them by default.',
                style: TextStyle(color: Color(0xFF8E8E93), fontSize: 13),
              ),
              value: _showCompleted,
              onChanged: _setShowCompleted,
              activeColor: const Color(0xFF30D158),
            ),
          ),
          const SizedBox(height: 28),

          // ── PERMISSIONS ────────────────────────────────────────────────────
          const _SectionLabel('PERMISSIONS'),
          _SettingsGroup(
            children: [
              _SettingsRow(
                icon: Icons.photo_library_rounded,
                iconColor: const Color(0xFF0A84FF),
                title: 'Photo Library',
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _StatusPill(
                      label: _permissionLabel,
                      color: _permissionColor,
                    ),
                    const SizedBox(width: 8),
                    const Icon(Icons.chevron_right_rounded,
                        color: Color(0xFF48484A), size: 20),
                  ],
                ),
                onTap: _openPermissionSettings,
              ),
            ],
          ),
          const SizedBox(height: 28),

          // ── FEEDBACK ───────────────────────────────────────────────────────
          const _SectionLabel('FEEDBACK'),
          _SettingsGroup(
            children: [
              _SettingsRow(
                icon: Icons.star_rounded,
                iconColor: const Color(0xFFFFD60A),
                title: 'Rate Photo Swiper',
                onTap: _rateApp,
              ),
              _SettingsRow(
                icon: Icons.share_rounded,
                iconColor: const Color(0xFF30D158),
                title: 'Share App',
                onTap: _shareApp,
              ),
            ],
          ),
          const SizedBox(height: 28),

          // ── SUPPORT ────────────────────────────────────────────────────────
          const _SectionLabel('SUPPORT'),
          _SettingsGroup(
            children: [
              _SettingsRow(
                icon: Icons.mail_outline_rounded,
                iconColor: const Color(0xFF6B4EFF),
                title: 'Contact Support',
                subtitle: _kSupportEmail,
                onTap: _contactSupport,
              ),
            ],
          ),
          const SizedBox(height: 28),

          // ── ABOUT ──────────────────────────────────────────────────────────
          const _SectionLabel('ABOUT'),
          _SettingsGroup(
            children: [
              _SettingsRow(
                icon: Icons.info_outline_rounded,
                iconColor: const Color(0xFF8E8E93),
                title: 'Version',
                trailing: Text(
                  _version.isNotEmpty ? _version : '—',
                  style: const TextStyle(
                    color: Color(0xFF8E8E93),
                    fontSize: 15,
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

// ─── Shared decoration ────────────────────────────────────────────────────────

const _kCard = BoxDecoration(
  color: Color(0xFF1C1C1E),
  borderRadius: BorderRadius.all(Radius.circular(16)),
);

// ─── _SectionLabel ────────────────────────────────────────────────────────────

class _SectionLabel extends StatelessWidget {
  final String text;
  const _SectionLabel(this.text);

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(left: 4, bottom: 10),
        child: Text(
          text,
          style: const TextStyle(
            color: Color(0xFF8E8E93),
            fontSize: 12,
            fontWeight: FontWeight.w600,
            letterSpacing: 0.8,
          ),
        ),
      );
}

// ─── _SettingsGroup ───────────────────────────────────────────────────────────
// Groups multiple rows in one card with hairline dividers between them.

class _SettingsGroup extends StatelessWidget {
  final List<Widget> children;
  const _SettingsGroup({required this.children});

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: _kCard,
      clipBehavior: Clip.hardEdge,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (int i = 0; i < children.length; i++) ...[
            children[i],
            if (i < children.length - 1)
              const Divider(
                height: 1,
                thickness: 1,
                color: Color(0xFF2C2C2E),
                indent: 70,
              ),
          ],
        ],
      ),
    );
  }
}

// ─── _SettingsRow ─────────────────────────────────────────────────────────────

class _SettingsRow extends StatelessWidget {
  final IconData icon;
  final Color iconColor;
  final String title;
  final String? subtitle;
  // Custom trailing widget; when null and onTap != null a chevron is shown.
  final Widget? trailing;
  final VoidCallback? onTap;

  const _SettingsRow({
    required this.icon,
    required this.iconColor,
    required this.title,
    this.subtitle,
    this.trailing,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final content = Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 13),
      child: Row(
        children: [
          _IconChip(icon: icon, color: iconColor),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  title,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 16,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                if (subtitle != null) ...[
                  const SizedBox(height: 2),
                  Text(
                    subtitle!,
                    style: const TextStyle(
                      color: Color(0xFF8E8E93),
                      fontSize: 12,
                    ),
                  ),
                ],
              ],
            ),
          ),
          if (trailing != null)
            trailing!
          else if (onTap != null)
            const Icon(Icons.chevron_right_rounded,
                color: Color(0xFF48484A), size: 20),
        ],
      ),
    );

    if (onTap == null) return content;
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: content,
    );
  }
}

// ─── _IconChip ────────────────────────────────────────────────────────────────

class _IconChip extends StatelessWidget {
  final IconData icon;
  final Color color;
  const _IconChip({required this.icon, required this.color});

  @override
  Widget build(BuildContext context) => Container(
        width: 40,
        height: 40,
        decoration: BoxDecoration(
          color: color.withOpacity(0.14),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Icon(icon, color: color, size: 20),
      );
}

// ─── _StatusPill ──────────────────────────────────────────────────────────────

class _StatusPill extends StatelessWidget {
  final String label;
  final Color color;
  const _StatusPill({required this.label, required this.color});

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration: BoxDecoration(
          color: color.withOpacity(0.14),
          borderRadius: BorderRadius.circular(20),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: color,
            fontSize: 12,
            fontWeight: FontWeight.w600,
          ),
        ),
      );
}

// ─── _TipBox ──────────────────────────────────────────────────────────────────

class _TipBox extends StatelessWidget {
  final String text;
  const _TipBox(this.text);

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.all(16),
        decoration: _kCard,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Icon(Icons.lightbulb_outline_rounded,
                color: Color(0xFFFFD60A), size: 18),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                text,
                style: const TextStyle(
                  color: Color(0xFF8E8E93),
                  fontSize: 13,
                  height: 1.5,
                ),
              ),
            ),
          ],
        ),
      );
}

// ─── Swipe direction preview ──────────────────────────────────────────────────

class _SwipePreview extends StatelessWidget {
  final bool leftHanded;
  const _SwipePreview({super.key, required this.leftHanded});

  @override
  Widget build(BuildContext context) {
    final leftAction = leftHanded ? _Action.keep : _Action.delete;
    final rightAction = leftHanded ? _Action.delete : _Action.keep;

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: _kCard,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _MockCard(leftAction: leftAction, rightAction: rightAction),
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                child: _DirectionTile(arrow: '← Left', action: leftAction),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _DirectionTile(arrow: 'Right →', action: rightAction),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

enum _Action { keep, delete }

extension _ActionStyle on _Action {
  String get label => this == _Action.keep ? 'KEEP' : 'DELETE';
  Color get color =>
      this == _Action.keep ? const Color(0xFF30D158) : const Color(0xFFFF453A);
  IconData get icon =>
      this == _Action.keep ? Icons.favorite_rounded : Icons.delete_outline_rounded;
}

class _MockCard extends StatelessWidget {
  final _Action leftAction;
  final _Action rightAction;
  const _MockCard({required this.leftAction, required this.rightAction});

  @override
  Widget build(BuildContext context) => Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Icon(Icons.arrow_back_ios_rounded, color: leftAction.color, size: 22),
          Container(
            width: 100,
            height: 130,
            decoration: BoxDecoration(
              color: const Color(0xFF2C2C2E),
              borderRadius: BorderRadius.circular(14),
            ),
            child: const Icon(Icons.photo_rounded,
                color: Color(0xFF48484A), size: 40),
          ),
          Icon(Icons.arrow_forward_ios_rounded, color: rightAction.color, size: 22),
        ],
      );
}

// ─── Subscription card ───────────────────────────────────────────────────────

class _SubscriptionCard extends StatelessWidget {
  final bool isPro;
  final VoidCallback onTap;
  const _SubscriptionCard({required this.isPro, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final accent = const Color(0xFF6B4EFF);
    final accentSoft = const Color(0xFF8B7BFF);
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Container(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
        decoration: BoxDecoration(
          gradient: LinearGradient(
            colors: [
              accent.withOpacity(isPro ? 0.10 : 0.20),
              accent.withOpacity(0.06),
            ],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
          borderRadius: BorderRadius.circular(18),
          border: Border.all(
            color: accent.withOpacity(isPro ? 0.35 : 0.55),
            width: 1.2,
          ),
        ),
        child: Row(
          children: [
            Container(
              width: 42,
              height: 42,
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  colors: [accent, accentSoft],
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                ),
                borderRadius: BorderRadius.circular(12),
              ),
              child: const Icon(Icons.auto_awesome_rounded,
                  color: Colors.white, size: 22),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    isPro ? 'FlickClean Pro' : 'Try FlickClean Pro',
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 16,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    isPro
                        ? 'Premium is active. Manage in App Store settings.'
                        : 'Unlock unlimited swiping · 3-day free trial.',
                    style: const TextStyle(
                      color: Color(0xFFB7B9BD),
                      fontSize: 12.5,
                      height: 1.4,
                    ),
                  ),
                ],
              ),
            ),
            const Icon(Icons.chevron_right_rounded,
                color: Color(0xFF8E8E93), size: 22),
          ],
        ),
      ),
    );
  }
}

class _DirectionTile extends StatelessWidget {
  final String arrow;
  final _Action action;
  const _DirectionTile({required this.arrow, required this.action});

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 14),
        decoration: BoxDecoration(
          color: action.color.withOpacity(0.09),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: action.color.withOpacity(0.22), width: 1),
        ),
        child: Column(
          children: [
            Icon(action.icon, color: action.color, size: 26),
            const SizedBox(height: 6),
            Text(
              action.label,
              style: TextStyle(
                color: action.color,
                fontSize: 14,
                fontWeight: FontWeight.w800,
                letterSpacing: 0.5,
              ),
            ),
            const SizedBox(height: 3),
            Text(
              arrow,
              style: const TextStyle(
                color: Color(0xFF8E8E93),
                fontSize: 12,
              ),
            ),
          ],
        ),
      );
}
