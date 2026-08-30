import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../services/analytics_events.dart';
import '../services/analytics_service.dart';
import '../services/media_service.dart';
import '../services/preferences_service.dart';
import 'swipe_screen.dart';
import 'grid_select_screen.dart';
import 'settings_screen.dart';

/// Picks which year the home screen opens on.
///
/// Precedence: the year the user last selected, then the current year, then
/// the earliest year with media. The remembered year is skipped when it no
/// longer appears in [availableYears] — e.g. the user deleted every photo in
/// it — so the last two branches preserve the original behaviour exactly.
///
/// [availableYears] must not be empty.
int resolveInitialYear({
  required List<int> availableYears,
  required int? rememberedYear,
  required int currentYear,
}) {
  if (rememberedYear != null && availableYears.contains(rememberedYear)) {
    return rememberedYear;
  }
  if (availableYears.contains(currentYear)) return currentYear;
  return availableYears.first;
}

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

  // month index 1–12 → total bytes (null = loading / not requested). Lives
  // per-state so a year switch resets the dictionary; the underlying
  // MediaService cache means actual recomputes are rare.
  final Map<int, int?> _monthSizes = {};
  bool _loadingSizes = false;

  // View preferences mirrored from PreferencesService. Re-read on resume
  // and on return from the Settings screen so toggle changes take effect
  // without a relaunch.
  MonthSort _sortMode = MonthSort.defaultOrder;
  bool _showCompleted = true;
  Set<String> _completed = const {};

  // One-shot animation flag: the year/month of the most recently completed
  // session. Set on first build, consumed (cleared in prefs + locally) so
  // the badge animation runs exactly once per completion event.
  String? _animateBadgeKey;

  static const _monthNames = [
    'January', 'February', 'March', 'April', 'May', 'June',
    'July', 'August', 'September', 'October', 'November', 'December',
  ];

  @override
  void initState() {
    super.initState();
    unawaited(AnalyticsService.instance.screen('home_screen'));
    final analytics = AnalyticsService.instance;
    unawaited(analytics.track(
      AnalyticsEvents.mainAppLoaded,
      properties: {
        'onboarding_completed':
            PreferencesService.instance.isOnboardingComplete,
      },
    ));
    unawaited(analytics.funnelStep(
      FunnelSteps.mainApp,
      event: AnalyticsEvents.funnelStepMainApp,
      status: 'accessed',
    ));
    _hydratePrefs();
    _init();
    _consumeNewlyCompleted();
  }

  void _hydratePrefs() {
    final prefs = PreferencesService.instance;
    _sortMode = prefs.monthSortMode;
    _showCompleted = prefs.showCompletedMonths;
    _completed = prefs.completedMonths;
  }

  Future<void> _consumeNewlyCompleted() async {
    final key = await PreferencesService.instance.consumeLastNewlyCompleted();
    if (!mounted || key == null) return;
    setState(() => _animateBadgeKey = key);
    // Clear after enough time for the entrance animation to finish.
    Future<void>.delayed(const Duration(milliseconds: 1200), () {
      if (mounted) setState(() => _animateBadgeKey = null);
    });
  }

  Future<void> _init() async {
    final years = await _service.getAvailableYears();
    if (!mounted) return;
    setState(() {
      _years = years;
      // Deliberately not written back to prefs: only an explicit tap records
      // a year, so falling back never overwrites a deliberate choice.
      _selectedYear = resolveInitialYear(
        availableYears: years,
        rememberedYear: PreferencesService.instance.lastSelectedYear,
        currentYear: DateTime.now().year,
      );
      _loadingYears = false;
    });
    _loadMonthCounts();
  }

  void _loadMonthCounts() {
    // Reset counts + sizes for the new year
    setState(() {
      for (int m = 1; m <= 12; m++) {
        _monthCounts[m] = null;
        _monthSizes[m] = null;
      }
    });

    // Load each month's count in parallel — cheap, returns instantly per month.
    for (int m = 1; m <= 12; m++) {
      final month = m;
      _service.getMonthCount(month, _selectedYear).then((count) {
        if (!mounted) return;
        setState(() => _monthCounts[month] = count);
      });
    }

    // Kick off size computation only when the active sort needs it.
    if (_sortMode == MonthSort.largestFirst ||
        _sortMode == MonthSort.smallestFirst) {
      _loadMonthSizes();
    }
  }

  Future<void> _loadMonthSizes() async {
    if (_loadingSizes) return;
    setState(() => _loadingSizes = true);
    final yearAtStart = _selectedYear;
    for (int m = 1; m <= 12; m++) {
      final month = m;
      // Sequential per month keeps the IO pressure predictable; MediaService
      // already parallelises within a month with a small concurrency cap.
      final size = await _service.getMonthTotalSize(month, yearAtStart);
      if (!mounted || yearAtStart != _selectedYear) return;
      setState(() => _monthSizes[month] = size);
    }
    if (mounted) setState(() => _loadingSizes = false);
  }

  void _selectYear(int year) {
    if (year == _selectedYear) return;
    HapticFeedback.selectionClick();
    setState(() => _selectedYear = year);
    unawaited(PreferencesService.instance.setLastSelectedYear(year));
    _loadMonthCounts();
  }

  void _setSortMode(MonthSort mode) {
    if (mode == _sortMode) {
      Navigator.of(context).maybePop();
      return;
    }
    HapticFeedback.selectionClick();
    setState(() => _sortMode = mode);
    unawaited(PreferencesService.instance.setMonthSortMode(mode));
    if ((mode == MonthSort.largestFirst ||
            mode == MonthSort.smallestFirst) &&
        _monthSizes.values.any((v) => v == null)) {
      _loadMonthSizes();
    }
    Navigator.of(context).maybePop();
  }

  /// Computed list of (month, count) tuples filtered + sorted per the
  /// current preferences. Months without any media are pushed to the end
  /// of size sorts so they don't dominate the smallest-first view at 0 B.
  List<_MonthEntry> _buildMonthEntries() {
    final showCompletedOnly = _sortMode == MonthSort.completedOnly;
    final hideCompleted = !showCompletedOnly && !_showCompleted;

    final entries = <_MonthEntry>[];
    for (int m = 1; m <= 12; m++) {
      final key = PreferencesService.monthKey(_selectedYear, m);
      final isCompleted = _completed.contains(key);
      if (showCompletedOnly && !isCompleted) continue;
      if (hideCompleted && isCompleted) continue;
      entries.add(_MonthEntry(
        month: m,
        count: _monthCounts[m],
        sizeBytes: _monthSizes[m],
        isCompleted: isCompleted,
        key: key,
      ));
    }

    switch (_sortMode) {
      case MonthSort.defaultOrder:
      case MonthSort.completedOnly:
        // Chronological: January → December for the selected year.
        entries.sort((a, b) => a.month.compareTo(b.month));
      case MonthSort.largestFirst:
        entries.sort((a, b) {
          final aSize = a.sizeBytes ?? -1;
          final bSize = b.sizeBytes ?? -1;
          return bSize.compareTo(aSize);
        });
      case MonthSort.smallestFirst:
        entries.sort((a, b) {
          // Push months with no media (count == 0) and "loading" entries to
          // the bottom so the user sees real candidates first.
          final aLoaded = a.sizeBytes != null && (a.count ?? 0) > 0;
          final bLoaded = b.sizeBytes != null && (b.count ?? 0) > 0;
          if (aLoaded && !bLoaded) return -1;
          if (!aLoaded && bLoaded) return 1;
          final aSize = a.sizeBytes ?? 0;
          final bSize = b.sizeBytes ?? 0;
          return aSize.compareTo(bSize);
        });
    }
    return entries;
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
        'FlickClean',
        style: TextStyle(
          color: Colors.white,
          fontWeight: FontWeight.w700,
          fontSize: 22,
        ),
      ),
      actions: [
        _FilterIconButton(
          active: _sortMode != MonthSort.defaultOrder,
          loading: _loadingSizes &&
              (_sortMode == MonthSort.largestFirst ||
                  _sortMode == MonthSort.smallestFirst),
          onPressed: _showFilterSheet,
        ),
        IconButton(
          icon: const Icon(Icons.settings_rounded,
              color: Color(0xFF8E8E93)),
          onPressed: () async {
            await Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const SettingsScreen()),
            );
            if (!mounted) return;
            // Settings may have toggled "show completed" — re-read prefs and
            // rebuild so the change reflects without a relaunch.
            setState(() {
              _hydratePrefs();
            });
          },
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
    return SliverToBoxAdapter(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 28, 20, 12),
        child: Row(
          children: [
            const Expanded(
              child: Text(
                'Browse by Month',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 20,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            AnimatedSwitcher(
              duration: const Duration(milliseconds: 200),
              child: _sortMode == MonthSort.defaultOrder
                  ? const SizedBox.shrink(key: ValueKey('no-chip'))
                  : _SortBadge(
                      key: ValueKey(_sortMode),
                      label: _sortLabel(_sortMode),
                      onClear: () => _setSortMode(MonthSort.defaultOrder),
                    ),
            ),
          ],
        ),
      ),
    );
  }

  String _sortLabel(MonthSort mode) {
    switch (mode) {
      case MonthSort.defaultOrder:
        return 'Default';
      case MonthSort.largestFirst:
        return 'Largest first';
      case MonthSort.smallestFirst:
        return 'Smallest first';
      case MonthSort.completedOnly:
        return 'Completed only';
    }
  }

  Widget _buildMonthGrid() {
    final entries = _buildMonthEntries();
    if (entries.isEmpty) {
      return const SliverToBoxAdapter(
        child: Padding(
          padding: EdgeInsets.fromLTRB(20, 16, 20, 32),
          child: _EmptyFilterState(),
        ),
      );
    }

    return SliverPadding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      sliver: SliverGrid(
        delegate: SliverChildBuilderDelegate(
          (context, index) {
            final entry = entries[index];
            final hasMedia = (entry.count ?? 0) > 0;
            final isLoading = entry.count == null;
            final shouldAnimateBadge =
                entry.isCompleted && _animateBadgeKey == entry.key;

            return _MonthCard(
              // Key by (year, month) so the framework reuses the same
              // element instance across reorders — animations & state
              // (like the badge fade) keep their context.
              key: ValueKey('${_selectedYear}-${entry.month}'),
              name: _monthNames[entry.month - 1],
              count: entry.count,
              sizeBytes: entry.sizeBytes,
              showSize: _sortMode == MonthSort.largestFirst ||
                  _sortMode == MonthSort.smallestFirst,
              isLoading: isLoading,
              hasMedia: hasMedia,
              isCompleted: entry.isCompleted,
              animateBadge: shouldAnimateBadge,
              onTap: hasMedia ? () => _openMonth(entry.month) : null,
              onGridTap:
                  hasMedia ? () => _openGridSelect(entry.month) : null,
            );
          },
          childCount: entries.length,
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

  // ─── Filter sheet ──────────────────────────────────────────────────────────
  Future<void> _showFilterSheet() async {
    HapticFeedback.selectionClick();
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: const Color(0xFF1C1C1E),
      barrierColor: Colors.black.withOpacity(0.45),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
      ),
      builder: (_) {
        return SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(8, 8, 8, 14),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Center(
                  child: Container(
                    width: 36,
                    height: 4,
                    margin: const EdgeInsets.only(top: 6, bottom: 14),
                    decoration: BoxDecoration(
                      color: const Color(0xFF3A3A3C),
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
                const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 16),
                  child: Text(
                    'Sort & Filter',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 16,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                _FilterRow(
                  icon: Icons.calendar_today_rounded,
                  label: 'Default order',
                  subtitle: 'Chronological by month',
                  selected: _sortMode == MonthSort.defaultOrder,
                  onTap: () => _setSortMode(MonthSort.defaultOrder),
                ),
                _FilterRow(
                  icon: Icons.south_rounded,
                  label: 'Largest month first',
                  subtitle: 'By total file size',
                  selected: _sortMode == MonthSort.largestFirst,
                  onTap: () => _setSortMode(MonthSort.largestFirst),
                ),
                _FilterRow(
                  icon: Icons.north_rounded,
                  label: 'Smallest month first',
                  subtitle: 'By total file size',
                  selected: _sortMode == MonthSort.smallestFirst,
                  onTap: () => _setSortMode(MonthSort.smallestFirst),
                ),
                _FilterRow(
                  icon: Icons.check_circle_outline_rounded,
                  label: 'Completed only',
                  subtitle: 'Months you’ve already finished',
                  selected: _sortMode == MonthSort.completedOnly,
                  onTap: () => _setSortMode(MonthSort.completedOnly),
                ),
              ],
            ),
          ),
        );
      },
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

class _MonthEntry {
  final int month;
  final int? count;
  final int? sizeBytes;
  final bool isCompleted;
  final String key;
  const _MonthEntry({
    required this.month,
    required this.count,
    required this.sizeBytes,
    required this.isCompleted,
    required this.key,
  });
}

class _MonthCard extends StatelessWidget {
  final String name;
  final int? count;
  final int? sizeBytes;
  final bool showSize;
  final bool isLoading;
  final bool hasMedia;
  final bool isCompleted;
  final bool animateBadge;
  final VoidCallback? onTap;
  final VoidCallback? onGridTap;

  const _MonthCard({
    super.key,
    required this.name,
    required this.count,
    required this.sizeBytes,
    required this.showSize,
    required this.isLoading,
    required this.hasMedia,
    required this.isCompleted,
    required this.animateBadge,
    this.onTap,
    this.onGridTap,
  });

  static const Color _check = Color(0xFF30D158);

  @override
  Widget build(BuildContext context) {
    final active = hasMedia;

    return GestureDetector(
      onTap: onTap,
      child: AnimatedOpacity(
        duration: const Duration(milliseconds: 250),
        opacity: isLoading ? 0.6 : (active ? 1.0 : 0.35),
        child: Stack(
          children: [
            Container(
              decoration: BoxDecoration(
                color: const Color(0xFF1C1C1E),
                borderRadius: BorderRadius.circular(16),
                border: Border.all(
                  color: isCompleted
                      ? _check.withOpacity(0.45)
                      : active
                          ? const Color(0xFF6B4EFF).withOpacity(0.3)
                          : Colors.transparent,
                  width: 1,
                ),
              ),
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  // Top row: photo icon + grid-select button. The
                  // completion badge sits as a separate Positioned overlay
                  // so it can animate independently without disturbing
                  // this row.
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
                          onTap: onGridTap,
                          behavior: HitTestBehavior.opaque,
                          child: Padding(
                            // Push the grid icon down + left so the badge
                            // has room in the top-right corner without
                            // overlapping the tap target.
                            padding: const EdgeInsets.only(top: 22, right: 4),
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

                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        name,
                        style: TextStyle(
                          color: active
                              ? Colors.white
                              : const Color(0xFF8E8E93),
                          fontSize: 15,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 2),
                      _buildSubtitle(active),
                    ],
                  ),
                ],
              ),
            ),
            if (isCompleted)
              Positioned(
                top: 10,
                right: 10,
                child: _CompletionBadge(animate: animateBadge),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildSubtitle(bool active) {
    final mutedColor = active
        ? const Color(0xFF8E8E93)
        : const Color(0xFF3A3A3C);

    if (isLoading) {
      return Container(
        width: 40,
        height: 10,
        decoration: BoxDecoration(
          color: const Color(0xFF3A3A3C),
          borderRadius: BorderRadius.circular(5),
        ),
      );
    }

    final countLabel = (count ?? 0) == 0
        ? 'No photos'
        : '$count ${count == 1 ? 'item' : 'items'}';

    if (showSize && active) {
      final sizeLabel = _formatSize(sizeBytes);
      return Text(
        sizeBytes == null ? '$countLabel · …' : '$countLabel · $sizeLabel',
        style: TextStyle(color: mutedColor, fontSize: 12),
        overflow: TextOverflow.ellipsis,
      );
    }

    return Text(
      countLabel,
      style: TextStyle(color: mutedColor, fontSize: 12),
    );
  }

  String _formatSize(int? bytes) {
    if (bytes == null) return '—';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(0)} KB';
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(0)} MB';
    }
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
  }
}

/// Small elegant check badge for completed months.
///
/// When [animate] is true (i.e. the month was *just* completed and we're
/// returning from the review screen) the badge runs a one-shot scale +
/// fade entrance. On every other render — including re-renders triggered
/// by sort changes — the badge is steady, never re-animating.
class _CompletionBadge extends StatelessWidget {
  final bool animate;
  const _CompletionBadge({required this.animate});

  static const Color _check = Color(0xFF30D158);

  @override
  Widget build(BuildContext context) {
    final badge = Container(
      width: 22,
      height: 22,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: _check.withOpacity(0.95),
        boxShadow: [
          BoxShadow(
            color: _check.withOpacity(0.45),
            blurRadius: 10,
            spreadRadius: 1,
          ),
        ],
      ),
      child: const Icon(Icons.check_rounded, color: Colors.white, size: 14),
    );

    if (!animate) return badge;

    // Single tween from 0.6× / opacity 0 → 1.0× / opacity 1 with an
    // overshoot for a subtle pop. TweenAnimationBuilder runs once per
    // build and the parent only sets animate=true for the moment after
    // a session completes, so this fires exactly once.
    return TweenAnimationBuilder<double>(
      duration: const Duration(milliseconds: 520),
      curve: Curves.easeOutBack,
      tween: Tween(begin: 0.0, end: 1.0),
      builder: (_, t, child) {
        return Opacity(
          opacity: t.clamp(0.0, 1.0),
          child: Transform.scale(scale: 0.6 + (t * 0.4), child: child),
        );
      },
      child: badge,
    );
  }
}

/// Filter bottom-sheet row. iOS-style checkmark on the active option.
class _FilterRow extends StatelessWidget {
  final IconData icon;
  final String label;
  final String subtitle;
  final bool selected;
  final VoidCallback onTap;

  const _FilterRow({
    required this.icon,
    required this.label,
    required this.subtitle,
    required this.selected,
    required this.onTap,
  });

  static const Color _accent = Color(0xFF6B4EFF);

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Row(
          children: [
            Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(
                color: _accent.withOpacity(selected ? 0.18 : 0.10),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Icon(icon,
                  color: selected ? _accent : const Color(0xFF8B7BFF),
                  size: 18),
            ),
            const SizedBox(width: 13),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    label,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 1),
                  Text(
                    subtitle,
                    style: const TextStyle(
                      color: Color(0xFF8E8E93),
                      fontSize: 12,
                    ),
                  ),
                ],
              ),
            ),
            AnimatedSwitcher(
              duration: const Duration(milliseconds: 200),
              child: selected
                  ? const Icon(Icons.check_rounded,
                      key: ValueKey('on'), color: _accent, size: 22)
                  : const SizedBox(key: ValueKey('off'), width: 22),
            ),
          ],
        ),
      ),
    );
  }
}

/// Tunable app-bar filter button. Shows a small accent dot when a non-
/// default sort is active, and an inline spinner while sizes load.
class _FilterIconButton extends StatelessWidget {
  final bool active;
  final bool loading;
  final VoidCallback onPressed;
  const _FilterIconButton({
    required this.active,
    required this.loading,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    return IconButton(
      onPressed: onPressed,
      tooltip: 'Sort & filter',
      icon: Stack(
        clipBehavior: Clip.none,
        children: [
          Icon(
            Icons.tune_rounded,
            color: active
                ? const Color(0xFF8B7BFF)
                : const Color(0xFF8E8E93),
          ),
          if (loading)
            const Positioned(
              right: -4,
              bottom: -4,
              child: SizedBox(
                width: 10,
                height: 10,
                child: CircularProgressIndicator(
                  strokeWidth: 1.6,
                  valueColor:
                      AlwaysStoppedAnimation(Color(0xFF8B7BFF)),
                ),
              ),
            )
          else if (active)
            Positioned(
              right: -1,
              top: -1,
              child: Container(
                width: 7,
                height: 7,
                decoration: const BoxDecoration(
                  color: Color(0xFF8B7BFF),
                  shape: BoxShape.circle,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// Small inline chip displayed under the section header when a non-
/// default sort is active. Tapping it returns the user to chronological
/// order — saves a trip back into the bottom sheet.
class _SortBadge extends StatelessWidget {
  final String label;
  final VoidCallback onClear;
  const _SortBadge({super.key, required this.label, required this.onClear});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onClear,
      behavior: HitTestBehavior.opaque,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          color: const Color(0xFF6B4EFF).withOpacity(0.14),
          borderRadius: BorderRadius.circular(999),
          border: Border.all(
            color: const Color(0xFF6B4EFF).withOpacity(0.35),
            width: 1,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              label,
              style: const TextStyle(
                color: Color(0xFF8B7BFF),
                fontSize: 11.5,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(width: 4),
            const Icon(Icons.close_rounded,
                color: Color(0xFF8B7BFF), size: 13),
          ],
        ),
      ),
    );
  }
}

class _EmptyFilterState extends StatelessWidget {
  const _EmptyFilterState();
  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        color: const Color(0xFF1C1C1E),
        borderRadius: BorderRadius.circular(16),
        border:
            Border.all(color: const Color(0xFF2C2C2E), width: 1),
      ),
      child: const Column(
        children: [
          Icon(Icons.filter_alt_off_rounded,
              color: Color(0xFF6E6E73), size: 32),
          SizedBox(height: 10),
          Text(
            'No months match this filter',
            style: TextStyle(
              color: Colors.white,
              fontSize: 14.5,
              fontWeight: FontWeight.w600,
            ),
          ),
          SizedBox(height: 4),
          Text(
            'Try a different sort or finish a month to mark it as completed.',
            textAlign: TextAlign.center,
            style: TextStyle(
              color: Color(0xFF8E8E93),
              fontSize: 12.5,
              height: 1.4,
            ),
          ),
        ],
      ),
    );
  }
}
