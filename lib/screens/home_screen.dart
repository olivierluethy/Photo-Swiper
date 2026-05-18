import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../services/analytics_service.dart';
import '../services/media_service.dart';
import 'swipe_screen.dart';
import 'grid_select_screen.dart';
import 'settings_screen.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final _service = MediaService.instance;

  List<int> _years = [];
  int _selectedYear = DateTime.now().year;
  bool _loadingYears = true;

  // month index 1–12 → count (null = loading)
  final Map<int, int?> _monthCounts = {};

  static const _monthNames = [
    'January', 'February', 'March', 'April', 'May', 'June',
    'July', 'August', 'September', 'October', 'November', 'December',
  ];

  @override
  void initState() {
    super.initState();
    unawaited(AnalyticsService.instance.screen('home_screen'));
    _init();
  }

  Future<void> _init() async {
    final years = await _service.getAvailableYears();
    if (!mounted) return;
    setState(() {
      _years = years;
      _selectedYear = years.contains(DateTime.now().year)
          ? DateTime.now().year
          : years.first;
      _loadingYears = false;
    });
    _loadMonthCounts();
  }

  void _loadMonthCounts() {
    // Reset
    setState(() {
      for (int m = 1; m <= 12; m++) {
        _monthCounts[m] = null;
      }
    });

    // Load each month in parallel
    for (int m = 1; m <= 12; m++) {
      final month = m;
      _service.getMonthCount(month, _selectedYear).then((count) {
        if (!mounted) return;
        setState(() => _monthCounts[month] = count);
      });
    }
  }

  void _selectYear(int year) {
    if (year == _selectedYear) return;
    HapticFeedback.selectionClick();
    setState(() => _selectedYear = year);
    _loadMonthCounts();
  }

  void _openMonth(int month) {
    final count = _monthCounts[month];
    if (count == 0) return; // nothing to swipe
    HapticFeedback.lightImpact();
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => SwipeScreen(
          month: month,
          year: _selectedYear,
          mode: SwipeMode.month,
        ),
      ),
    );
  }

  void _openGridSelect(int month) {
    HapticFeedback.lightImpact();
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) =>
            GridSelectScreen(month: month, year: _selectedYear),
      ),
    );
  }

  void _openToday() {
    HapticFeedback.lightImpact();
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => const SwipeScreen(mode: SwipeMode.today),
      ),
    );
  }

  void _openRandom() {
    HapticFeedback.lightImpact();
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => SwipeScreen(
          mode: SwipeMode.random,
          year: _selectedYear,
        ),
      ),
    );
  }

  // ─── Build ──────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0D0D0D),
      body: CustomScrollView(
        slivers: [
          _buildAppBar(),
          if (_loadingYears)
            const SliverFillRemaining(
              child: Center(
                child: CircularProgressIndicator(
                  color: Color(0xFF6B4EFF),
                ),
              ),
            )
          else ...[
            _buildYearSelector(),
            _buildQuickAccess(),
            _buildMonthsHeader(),
            _buildMonthGrid(),
            const SliverPadding(padding: EdgeInsets.only(bottom: 32)),
          ],
        ],
      ),
    );
  }

  Widget _buildAppBar() {
    return SliverAppBar(
      pinned: true,
      backgroundColor: const Color(0xFF0D0D0D),
      surfaceTintColor: Colors.transparent,
      title: const Text(
        'Photo Swiper',
        style: TextStyle(
          color: Colors.white,
          fontWeight: FontWeight.w700,
          fontSize: 22,
        ),
      ),
      actions: [
        IconButton(
          icon: const Icon(Icons.settings_rounded,
              color: Color(0xFF8E8E93)),
          onPressed: () => Navigator.push(
            context,
            MaterialPageRoute(builder: (_) => const SettingsScreen()),
          ),
        ),
        IconButton(
          icon: const Icon(Icons.info_outline_rounded,
              color: Color(0xFF8E8E93)),
          onPressed: _showInfo,
        ),
      ],
    );
  }

  Widget _buildYearSelector() {
    return SliverToBoxAdapter(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 0),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            _YearArrowButton(
              icon: Icons.chevron_left_rounded,
              enabled: _years.indexOf(_selectedYear) < _years.length - 1,
              onTap: () {
                final idx = _years.indexOf(_selectedYear);
                if (idx < _years.length - 1) _selectYear(_years[idx + 1]);
              },
            ),
            const SizedBox(width: 4),
            GestureDetector(
              onTap: _showYearPicker,
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
                decoration: BoxDecoration(
                  color: const Color(0xFF1C1C1E),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Text(
                  '$_selectedYear',
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 22,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ),
            const SizedBox(width: 4),
            _YearArrowButton(
              icon: Icons.chevron_right_rounded,
              enabled: _years.indexOf(_selectedYear) > 0,
              onTap: () {
                final idx = _years.indexOf(_selectedYear);
                if (idx > 0) _selectYear(_years[idx - 1]);
              },
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildQuickAccess() {
    return SliverToBoxAdapter(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 24, 20, 0),
        child: Row(
          children: [
            Expanded(
              child: _QuickAccessCard(
                icon: Icons.today_rounded,
                label: 'Today',
                color: const Color(0xFF6B4EFF),
                onTap: _openToday,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: _QuickAccessCard(
                icon: Icons.shuffle_rounded,
                label: 'Random',
                color: const Color(0xFF0A84FF),
                onTap: _openRandom,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildMonthsHeader() {
    return const SliverToBoxAdapter(
      child: Padding(
        padding: EdgeInsets.fromLTRB(20, 28, 20, 12),
        child: Text(
          'Browse by Month',
          style: TextStyle(
            color: Colors.white,
            fontSize: 20,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
    );
  }

  Widget _buildMonthGrid() {
    return SliverPadding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      sliver: SliverGrid(
        delegate: SliverChildBuilderDelegate(
          (context, index) {
            final month = index + 1;
            final count = _monthCounts[month];
            final hasMedia = count != null && count > 0;
            final isLoading = count == null;

            return _MonthCard(
              name: _monthNames[index],
              count: count,
              isLoading: isLoading,
              hasMedia: hasMedia,
              onTap: hasMedia ? () => _openMonth(month) : null,
              onGridTap: hasMedia ? () => _openGridSelect(month) : null,
            );
          },
          childCount: 12,
        ),
        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: 2,
          mainAxisSpacing: 12,
          crossAxisSpacing: 12,
          childAspectRatio: 1.45,
        ),
      ),
    );
  }

  void _showYearPicker() {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: const Color(0xFF1C1C1E),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) {
        return ListView(
          shrinkWrap: true,
          children: [
            const Padding(
              padding: EdgeInsets.all(20),
              child: Text(
                'Select Year',
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 18,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            ..._years.map((y) => ListTile(
                  title: Text(
                    '$y',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: y == _selectedYear
                          ? const Color(0xFF6B4EFF)
                          : Colors.white,
                      fontWeight: y == _selectedYear
                          ? FontWeight.w700
                          : FontWeight.normal,
                      fontSize: 17,
                    ),
                  ),
                  onTap: () {
                    Navigator.pop(context);
                    _selectYear(y);
                  },
                )),
            const SizedBox(height: 20),
          ],
        );
      },
    );
  }

  void _showInfo() {
    showDialog<void>(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: const Color(0xFF1C1C1E),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(20),
        ),
        title: const Text('How it works',
            style: TextStyle(color: Colors.white, fontWeight: FontWeight.w700)),
        content: const Text(
          '• Swipe RIGHT to keep a photo\n'
          '• Swipe LEFT to mark for deletion\n'
          '• Tap CENTER to review later\n\n'
          'Nothing is deleted until you confirm on the Review screen.',
          style: TextStyle(color: Color(0xFF8E8E93), height: 1.6),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Got it',
                style: TextStyle(color: Color(0xFF6B4EFF))),
          ),
        ],
      ),
    );
  }
}

// ─── Supporting widgets ───────────────────────────────────────────────────────

class _YearArrowButton extends StatelessWidget {
  final IconData icon;
  final bool enabled;
  final VoidCallback onTap;

  const _YearArrowButton({
    required this.icon,
    required this.enabled,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: enabled ? onTap : null,
      child: Container(
        width: 44,
        height: 44,
        decoration: BoxDecoration(
          color: const Color(0xFF1C1C1E),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Icon(
          icon,
          color: enabled ? Colors.white : const Color(0xFF3A3A3C),
          size: 28,
        ),
      ),
    );
  }
}

class _QuickAccessCard extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color color;
  final VoidCallback onTap;

  const _QuickAccessCard({
    required this.icon,
    required this.label,
    required this.color,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        height: 76,
        decoration: BoxDecoration(
          color: color.withOpacity(0.12),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: color.withOpacity(0.2), width: 1),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, color: color, size: 26),
            const SizedBox(width: 10),
            Text(
              label,
              style: TextStyle(
                color: color,
                fontSize: 17,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _MonthCard extends StatelessWidget {
  final String name;
  final int? count;
  final bool isLoading;
  final bool hasMedia;
  final VoidCallback? onTap;
  final VoidCallback? onGridTap;

  const _MonthCard({
    required this.name,
    required this.count,
    required this.isLoading,
    required this.hasMedia,
    this.onTap,
    this.onGridTap,
  });

  @override
  Widget build(BuildContext context) {
    final active = hasMedia;

    return GestureDetector(
      onTap: onTap,
      child: AnimatedOpacity(
        duration: const Duration(milliseconds: 250),
        opacity: isLoading ? 0.6 : (active ? 1.0 : 0.35),
        child: Container(
          decoration: BoxDecoration(
            color: const Color(0xFF1C1C1E),
            borderRadius: BorderRadius.circular(16),
            border: active
                ? Border.all(
                    color: const Color(0xFF6B4EFF).withOpacity(0.3),
                    width: 1,
                  )
                : null,
          ),
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              // Top row: photo icon + grid-select button
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Icon(
                    Icons.photo_library_rounded,
                    color: active
                        ? const Color(0xFF6B4EFF)
                        : const Color(0xFF3A3A3C),
                    size: 22,
                  ),
                  if (onGridTap != null)
                    GestureDetector(
                      // Use a separate tap target so it doesn't
                      // trigger the card's swipe-mode onTap
                      onTap: onGridTap,
                      behavior: HitTestBehavior.opaque,
                      child: Padding(
                        padding: const EdgeInsets.all(2),
                        child: Tooltip(
                          message: 'Select items',
                          child: Icon(
                            Icons.checklist_rounded,
                            color: active
                                ? const Color(0xFF8E8E93)
                                : const Color(0xFF3A3A3C),
                            size: 18,
                          ),
                        ),
                      ),
                    ),
                ],
              ),

              // Month name + count
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    name,
                    style: TextStyle(
                      color: active ? Colors.white : const Color(0xFF8E8E93),
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 2),
                  if (isLoading)
                    Container(
                      width: 40,
                      height: 10,
                      decoration: BoxDecoration(
                        color: const Color(0xFF3A3A3C),
                        borderRadius: BorderRadius.circular(5),
                      ),
                    )
                  else
                    Text(
                      count == 0
                          ? 'No photos'
                          : '$count ${count == 1 ? 'item' : 'items'}',
                      style: TextStyle(
                        color: active
                            ? const Color(0xFF8E8E93)
                            : const Color(0xFF3A3A3C),
                        fontSize: 12,
                      ),
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
