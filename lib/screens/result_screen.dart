import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../services/analytics_service.dart';

class ResultScreen extends StatefulWidget {
  final int deletedCount;
  final int attemptedCount;
  final int freedBytes;
  final int laterCount;

  const ResultScreen({
    super.key,
    required this.deletedCount,
    required this.attemptedCount,
    required this.freedBytes,
    required this.laterCount,
  });

  @override
  State<ResultScreen> createState() => _ResultScreenState();
}

class _ResultScreenState extends State<ResultScreen>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;
  late final Animation<double> _scaleAnim;
  late final Animation<double> _fadeAnim;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 600));
    _scaleAnim = CurvedAnimation(parent: _ctrl, curve: Curves.elasticOut);
    _fadeAnim = CurvedAnimation(parent: _ctrl, curve: Curves.easeIn);

    unawaited(AnalyticsService.instance.screen('result_screen', properties: {
      'deleted_count': widget.deletedCount,
      'freed_bytes': widget.freedBytes,
    }));

    WidgetsBinding.instance.addPostFrameCallback((_) {
      _ctrl.forward();
      if (widget.deletedCount > 0) HapticFeedback.heavyImpact();
    });
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  String get _freedDisplay {
    final bytes = widget.freedBytes;
    if (bytes == 0) return '0 KB';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(0)} KB';
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
  }

  bool get _hasResult => widget.deletedCount > 0;

  void _goHome() {
    Navigator.pushNamedAndRemoveUntil(
      context,
      '/home',
      (route) => false,
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0D0D0D),
      body: SafeArea(
        child: FadeTransition(
          opacity: _fadeAnim,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 32),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Spacer(),

                // Icon
                ScaleTransition(
                  scale: _scaleAnim,
                  child: Container(
                    width: 130,
                    height: 130,
                    decoration: BoxDecoration(
                      color: (_hasResult
                              ? const Color(0xFF30D158)
                              : const Color(0xFF6B4EFF))
                          .withOpacity(0.12),
                      shape: BoxShape.circle,
                    ),
                    child: Icon(
                      _hasResult
                          ? Icons.check_circle_outline_rounded
                          : Icons.favorite_border_rounded,
                      color: _hasResult
                          ? const Color(0xFF30D158)
                          : const Color(0xFF6B4EFF),
                      size: 64,
                    ),
                  ),
                ),
                const SizedBox(height: 36),

                // Headline
                Text(
                  _hasResult ? 'All Cleaned Up!' : 'All Kept!',
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 34,
                    fontWeight: FontWeight.w700,
                    letterSpacing: -0.5,
                  ),
                ),
                const SizedBox(height: 10),
                Text(
                  _hasResult
                      ? 'Your gallery is looking great.'
                      : 'No photos were deleted.',
                  style: const TextStyle(
                      color: Color(0xFF8E8E93), fontSize: 16),
                ),
                const SizedBox(height: 48),

                // Stats cards
                if (_hasResult) ...[
                  _StatsRow(
                    items: [
                      _StatItem(
                        icon: Icons.delete_outline_rounded,
                        color: const Color(0xFFFF453A),
                        value: '${widget.deletedCount}',
                        label: 'Deleted',
                      ),
                      _StatItem(
                        icon: Icons.storage_rounded,
                        color: const Color(0xFF30D158),
                        value: _freedDisplay,
                        label: 'Freed',
                      ),
                    ],
                  ),
                  if (widget.laterCount > 0) ...[
                    const SizedBox(height: 12),
                    _StatsRow(
                      items: [
                        _StatItem(
                          icon: Icons.access_time_rounded,
                          color: const Color(0xFFFFD60A),
                          value: '${widget.laterCount}',
                          label: 'Deferred',
                        ),
                      ],
                    ),
                  ],
                ] else if (widget.laterCount > 0)
                  _StatsRow(
                    items: [
                      _StatItem(
                        icon: Icons.access_time_rounded,
                        color: const Color(0xFFFFD60A),
                        value: '${widget.laterCount}',
                        label: 'Deferred',
                      ),
                    ],
                  ),

                const Spacer(),

                // CTA
                SizedBox(
                  width: double.infinity,
                  height: 56,
                  child: ElevatedButton(
                    onPressed: _goHome,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF6B4EFF),
                      foregroundColor: Colors.white,
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(16)),
                      elevation: 0,
                    ),
                    child: const Text(
                      'Back to Home',
                      style: TextStyle(
                          fontSize: 17, fontWeight: FontWeight.w600),
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                TextButton(
                  onPressed: () => Navigator.pushNamedAndRemoveUntil(
                      context, '/home', (r) => false),
                  child: const Text(
                    'Clean another month',
                    style: TextStyle(
                        color: Color(0xFF8E8E93), fontSize: 15),
                  ),
                ),
                const SizedBox(height: 16),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ─── Stat widgets ─────────────────────────────────────────────────────────────

class _StatsRow extends StatelessWidget {
  final List<_StatItem> items;
  const _StatsRow({required this.items});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: items
          .map((item) => Expanded(child: _StatCard(item: item)))
          .toList(),
    );
  }
}

class _StatItem {
  final IconData icon;
  final Color color;
  final String value;
  final String label;

  const _StatItem({
    required this.icon,
    required this.color,
    required this.value,
    required this.label,
  });
}

class _StatCard extends StatelessWidget {
  final _StatItem item;
  const _StatCard({required this.item});

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 4),
      padding: const EdgeInsets.symmetric(vertical: 20),
      decoration: BoxDecoration(
        color: item.color.withOpacity(0.08),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: item.color.withOpacity(0.2), width: 1),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(item.icon, color: item.color, size: 28),
          const SizedBox(height: 10),
          Text(
            item.value,
            style: TextStyle(
              color: item.color,
              fontSize: 24,
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            item.label,
            style: const TextStyle(
                color: Color(0xFF8E8E93),
                fontSize: 12,
                fontWeight: FontWeight.w500),
          ),
        ],
      ),
    );
  }
}
