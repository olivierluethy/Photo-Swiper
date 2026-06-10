import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'dart:typed_data';
import 'dart:ui' show ImageFilter;

import 'package:photo_manager/photo_manager.dart';

import '../models/swipe_item.dart';
import '../services/analytics_events.dart';
import '../services/analytics_service.dart';
import '../services/media_service.dart';
import '../services/preferences_service.dart';
import '../widgets/swipe_card.dart';
import '../widgets/video_preview_card.dart';
import 'review_screen.dart';

enum SwipeMode { month, today, random }

class SwipeScreen extends StatefulWidget {
  final SwipeMode mode;
  final int? month;
  final int? year;

  const SwipeScreen({
    super.key,
    required this.mode,
    this.month,
    this.year,
  });

  @override
  State<SwipeScreen> createState() => _SwipeScreenState();
}

class _SwipeScreenState extends State<SwipeScreen> {
  final _service = MediaService.instance;

  List<SwipeItem> _items = [];
  int _currentIndex = 0;
  bool _loading = true;
  String? _error;

  // Thumbnail + file-size caches
  final Map<String, Uint8List?> _thumbCache = {};
  final Map<String, Future<Uint8List?>> _thumbFutures = {};

  // Key for the SwipeCard widget — changes per item to reset gesture state
  int _cardKey = 0;

  // Read once at screen creation so the session stays consistent
  late final bool _leftHanded;

  // Tracks how many swipes the user has made this install; drives hint opacity.
  // Stored locally for immediate UI response; persisted async via prefs.
  late int _swipeHintCount;

  // Tracks the number of swipes made in this session and whether we've already
  // emitted cleanup_paused on dispose. We emit cleanup_paused only when the
  // user navigates away mid-session — not after they've reached the review
  // screen (which navigates via pushReplacement, dropping this state).
  int _swipesThisSession = 0;
  bool _sessionCompleted = false;

  // ─── Zoom state ───────────────────────────────────────────────────────────────
  // Shared between InteractiveViewer (inside the card) and SwipeCard (gesture
  // coordination). When _isZoomed is true SwipeCard disables its horizontal-drag
  // recognizers so InteractiveViewer's pan can win the gesture arena.
  final TransformationController _zoomController = TransformationController();
  bool _isZoomed = false;

  // ─── Thumbnail strip ──────────────────────────────────────────────────────────
  // Separate ScrollController and a compact-size thumb cache (160×160) for the
  // strip. If the high-res card thumb is already in _thumbCache we reuse it, so
  // visible items never load twice.
  final ScrollController _stripController = ScrollController();
  final Map<String, Future<Uint8List?>> _stripFutures = {};

  // Layout constants shared between builder and scroll helper
  static const double _stripItemWidth = 54;
  static const double _stripGap = 6;
  static const double _stripPad = 16;

  @override
  void initState() {
    super.initState();
    _leftHanded = PreferencesService.instance.isLeftHanded;
    _swipeHintCount = PreferencesService.instance.swipeHintCount;
    _zoomController.addListener(_onZoomChanged);
    unawaited(AnalyticsService.instance.screen('swipe_screen', properties: {
      'mode': widget.mode.name,
    }));
    _load();
  }

  @override
  void dispose() {
    if (!_sessionCompleted &&
        _items.isNotEmpty &&
        _currentIndex < _items.length) {
      unawaited(AnalyticsService.instance.track(
        AnalyticsEvents.cleanupPaused,
        properties: {
          'swipes_completed': _swipesThisSession,
          'photos_remaining_bucket':
              _bucketCount(_items.length - _currentIndex),
          'mode': widget.mode.name,
        },
      ));
    }
    _zoomController.removeListener(_onZoomChanged);
    _zoomController.dispose();
    _stripController.dispose();
    super.dispose();
  }

  void _onZoomChanged() {
    final scale = _zoomController.value.getMaxScaleOnAxis();
    final zoomed = scale > 1.005;
    if (zoomed != _isZoomed && mounted) {
      setState(() => _isZoomed = zoomed);
    }
  }

  void _resetZoom() {
    _zoomController.value = Matrix4.identity();
    _isZoomed = false;
  }

  // Motion nudge is active for the first 7 swipes; after that the user has
  // built muscle memory and the idle-nudge animation is suppressed.
  double get _hintOpacity {
    if (_swipeHintCount >= 7) return 0.0;
    return 1.0 - _swipeHintCount / 7.0;
  }

  // ─── Loading ─────────────────────────────────────────────────────────────────

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });

    final startedAt = DateTime.now();
    unawaited(AnalyticsService.instance.track(
      AnalyticsEvents.galleryLoadStarted,
      properties: {'mode': widget.mode.name},
    ));

    try {
      List<AssetEntity> assets;
      switch (widget.mode) {
        case SwipeMode.month:
          assets = await _service.loadMonthMedia(
              widget.month!, widget.year!);
        case SwipeMode.today:
          assets = await _service.loadTodayMedia();
        case SwipeMode.random:
          assets = await _service.loadRandomMedia(limit: 50);
      }

      final items = assets.map((a) => SwipeItem(asset: a)).toList();

      unawaited(AnalyticsService.instance.track(
        AnalyticsEvents.galleryLoadCompleted,
        properties: {
          'mode': widget.mode.name,
          'load_time_ms':
              DateTime.now().difference(startedAt).inMilliseconds,
          // Coarse bucket only — actual photo count is treated as
          // user-identifying / sensitive and is intentionally not logged.
          'photo_count_bucket': _bucketCount(assets.length),
        },
      ));

      if (!mounted) return;
      setState(() {
        _items = items;
        _loading = false;
      });

      if (items.isNotEmpty) {
        final cleanupProps = <String, Object>{
          'mode': widget.mode.name,
          'photos_in_session_bucket': _bucketCount(items.length),
        };
        if (widget.mode == SwipeMode.month &&
            widget.month != null &&
            widget.year != null) {
          cleanupProps['month'] =
              '${widget.year}-${widget.month!.toString().padLeft(2, '0')}';
        }
        unawaited(AnalyticsService.instance.track(
          AnalyticsEvents.cleanupStarted,
          properties: cleanupProps,
        ));
      }

      // Preload thumbnails for first 3 items
      for (int i = 0; i < items.length && i < 3; i++) {
        _preloadThumb(i);
      }
      // Load file sizes for first 2
      for (int i = 0; i < items.length && i < 2; i++) {
        _loadFileSize(i);
      }
    } catch (e) {
      unawaited(AnalyticsService.instance.track(
        AnalyticsEvents.galleryLoadFailed,
        properties: {
          'mode': widget.mode.name,
          'error_type': e.runtimeType.toString(),
        },
      ));
      unawaited(AnalyticsService.instance.track(
        AnalyticsEvents.errorOccurred,
        properties: {
          'error_type': e.runtimeType.toString(),
          'context': 'gallery_load_swipe',
        },
      ));
      if (!mounted) return;
      setState(() {
        _error = 'Could not load media. Please check permissions.';
        _loading = false;
      });
    }
  }

  void _preloadThumb(int index) {
    if (index >= _items.length) return;
    final id = _items[index].asset.id;
    if (_thumbCache.containsKey(id)) return;
    if (_thumbFutures.containsKey(id)) return;

    final future = _items[index].asset.thumbnailDataWithSize(
      ThumbnailSize(900, 1200),
      quality: 92,
    );
    _thumbFutures[id] = future;
    future.then((bytes) {
      if (mounted) {
        _thumbCache[id] = bytes;
        _thumbFutures.remove(id);
        if (mounted) setState(() {});
      }
    });
  }

  void _loadFileSize(int index) {
    if (index >= _items.length) return;
    final item = _items[index];
    if (item.fileSizeBytes != null) return;

    _service.getFileSize(item.asset).then((size) {
      if (!mounted || index >= _items.length) return;
      setState(() => _items[index].fileSizeBytes = size);
    });
  }

  // ─── Swipe decision ───────────────────────────────────────────────────────────

  void _decide(SwipeDecision decision) {
    if (_currentIndex >= _items.length) return;

    HapticFeedback.selectionClick();
    _resetZoom();

    final positionBeforeSwipe = _currentIndex;

    setState(() {
      _items[_currentIndex].decision = decision;
      _currentIndex++;
      _cardKey++;
      // Increment locally for immediate opacity update; persist async below.
      if (_swipeHintCount < 7) _swipeHintCount++;
    });

    _swipesThisSession++;
    unawaited(AnalyticsService.instance.track(
      AnalyticsEvents.swipePerformed,
      properties: {
        // 'direction' is the key the dashboard reads; 'decision' is kept
        // alongside as a back-compat alias for any chart that already
        // queried it.
        'direction': decision.name,
        'decision': decision.name,
        'position_in_session': positionBeforeSwipe,
        'mode': widget.mode.name,
      },
    ));

    PreferencesService.instance.incrementSwipeHintCount();

    if (_currentIndex >= _items.length) {
      _sessionCompleted = true;
      _onSessionComplete();
      return;
    }

    // Keep the strip centred on the new card
    _scrollStripToIndex(_currentIndex);

    // Preload ahead
    _preloadThumb(_currentIndex + 2);
    _loadFileSize(_currentIndex);
    _loadFileSize(_currentIndex + 1);
  }

  /// Jump directly to [index] without swiping through intermediate cards.
  /// Works for both forward and backward navigation from the thumbnail strip.
  void _jumpToIndex(int index) {
    if (index == _currentIndex || index >= _items.length) return;
    HapticFeedback.selectionClick();
    _resetZoom();
    setState(() {
      _currentIndex = index;
      _cardKey++;
    });
    _scrollStripToIndex(index);
    _preloadThumb(index + 1);
    _loadFileSize(index);
    _loadFileSize(index + 1);
  }

  /// Smoothly scrolls the thumbnail strip so that [index] is centred in the
  /// viewport. Safe to call before the ListView has attached its first frame.
  void _scrollStripToIndex(int index) {
    if (!_stripController.hasClients) return;
    final double viewW = MediaQuery.of(context).size.width;
    const double itemStep = _stripItemWidth + _stripGap;
    // Centre of the target item in scroll-content coordinates
    final double itemCentre = _stripPad + index * itemStep + _stripItemWidth / 2;
    final double target = (itemCentre - viewW / 2).clamp(0.0, double.infinity);
    _stripController.animateTo(
      target,
      duration: const Duration(milliseconds: 280),
      curve: Curves.easeOut,
    );
  }

  /// Called when the user taps "Review marked" mid-session.
  /// Navigates immediately without requiring all cards to be swiped.
  void _reviewNow() {
    _sessionCompleted = true;
    final toDelete =
        _items.where((i) => i.decision == SwipeDecision.delete).toList();
    final laterItems =
        _items.where((i) => i.decision == SwipeDecision.later).toList();
    HapticFeedback.mediumImpact();
    Navigator.pushReplacement(
      context,
      MaterialPageRoute(
        builder: (_) => ReviewScreen(
          toDelete: toDelete,
          laterItems: laterItems,
          sessionSwipeCount: _swipesThisSession,
          entryPath: 'swipe',
        ),
      ),
    );
  }

  void _onSessionComplete() {
    final toDelete =
        _items.where((i) => i.decision == SwipeDecision.delete).toList();
    final laterItems =
        _items.where((i) => i.decision == SwipeDecision.later).toList();

    // A month is "completed" the moment the user has decided every photo
    // in it. This is independent per year/month — completing October 2024
    // does not mark October 2023. Today/Random sessions don't map to a
    // specific month and are intentionally skipped.
    if (widget.mode == SwipeMode.month &&
        widget.month != null &&
        widget.year != null) {
      unawaited(PreferencesService.instance
          .markMonthCompleted(widget.year!, widget.month!));
    }

    Navigator.pushReplacement(
      context,
      MaterialPageRoute(
        builder: (_) => ReviewScreen(
          toDelete: toDelete,
          laterItems: laterItems,
          sessionSwipeCount: _swipesThisSession,
          entryPath: 'swipe',
        ),
      ),
    );
  }

  // ─── Build ────────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0D0D0D),
      appBar: _buildAppBar(),
      body: _buildBody(),
    );
  }

  PreferredSizeWidget _buildAppBar() {
    String title;
    switch (widget.mode) {
      case SwipeMode.month:
        const months = [
          'January', 'February', 'March', 'April', 'May', 'June',
          'July', 'August', 'September', 'October', 'November', 'December',
        ];
        title =
            '${months[widget.month! - 1]} ${widget.year}';
      case SwipeMode.today:
        title = 'Today';
      case SwipeMode.random:
        title = 'Random';
    }

    return AppBar(
      backgroundColor: const Color(0xFF0D0D0D),
      surfaceTintColor: Colors.transparent,
      leading: IconButton(
        icon: const Icon(Icons.close_rounded, color: Colors.white),
        onPressed: () => Navigator.pop(context),
      ),
      title: Text(title,
          style: const TextStyle(
              color: Colors.white,
              fontWeight: FontWeight.w600,
              fontSize: 18)),
      centerTitle: true,
      actions: [
        if (!_loading && _items.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(right: 16),
            child: Center(
              child: Text(
                '${_currentIndex + 1} / ${_items.length}',
                style: const TextStyle(
                  color: Color(0xFF8E8E93),
                  fontSize: 14,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
          ),
      ],
    );
  }

  Widget _buildBody() {
    if (_loading) {
      return const Center(
        child: CircularProgressIndicator(color: Color(0xFF6B4EFF)),
      );
    }
    if (_error != null) {
      return _ErrorView(message: _error!, onRetry: _load);
    }
    if (_items.isEmpty) {
      return const _EmptyView();
    }
    if (_currentIndex >= _items.length) {
      return const Center(
        child: CircularProgressIndicator(color: Color(0xFF6B4EFF)),
      );
    }

    return SafeArea(
      child: Column(
        children: [
          // Progress bar
          _ProgressBar(
            current: _currentIndex,
            total: _items.length,
          ),

          // Card area
          Expanded(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
              child: SwipeCard(
                key: ValueKey(_cardKey),
                leftHandedMode: _leftHanded,
                isZoomed: _isZoomed,
                hintOpacity: _hintOpacity,
                onSwipeLeft: () => _decide(
                    _leftHanded ? SwipeDecision.keep : SwipeDecision.delete),
                onSwipeRight: () => _decide(
                    _leftHanded ? SwipeDecision.delete : SwipeDecision.keep),
                child: _buildMediaCard(_items[_currentIndex]),
              ),
            ),
          ),

          // Meta info
          _buildMeta(_items[_currentIndex]),

          // Horizontal thumbnail strip — tap any cell to jump to that item
          _buildThumbnailStrip(),

          // "Review marked" shortcut — appears as soon as ≥1 item is marked
          _buildReviewBar(),

          // Action buttons
          _buildActionButtons(),
        ],
      ),
    );
  }

  Widget _buildMediaCard(SwipeItem item) {
    final isVideo = item.asset.type == AssetType.video;
    return ClipRRect(
      borderRadius: BorderRadius.circular(20),
      child: Stack(
        fit: StackFit.expand,
        children: [
          if (isVideo)
            // VideoPreviewCard is self-contained: loads the file, auto-plays
            // muted + looping, fades from thumbnail to live video, handles
            // tap to pause/resume. No InteractiveViewer — zoom makes no sense
            // for video, and omitting it keeps swipe gestures unambiguous.
            VideoPreviewCard(
              asset: item.asset,
              thumbBytes: _thumbCache[item.asset.id],
            )
          else
            _buildImageLayer(item),

          if (isVideo)
            Positioned(
              top: 12,
              left: 12,
              child: _buildVideoBadge(item.asset),
            ),
        ],
      ),
    );
  }

  // ── Image layer: blurred fill + scrim + contain foreground + zoom ────────────

  Widget _buildImageLayer(SwipeItem item) {
    final id = item.asset.id;
    final cached = _thumbCache[id];

    // Blurred background + contain foreground: image is never cropped, and
    // the soft blurred fill hides letterbox/pillarbox bars (same as Google
    // Photos / Apple Photos). The scrim keeps the foreground image legible.
    Widget imageLayer(Uint8List bytes) => Stack(
      fit: StackFit.expand,
      children: [
        ImageFiltered(
          imageFilter: ImageFilter.blur(sigmaX: 26, sigmaY: 26),
          child: Image.memory(bytes, fit: BoxFit.cover, gaplessPlayback: true),
        ),
        Container(color: Colors.black.withOpacity(0.40)),
        Image.memory(bytes, fit: BoxFit.contain, gaplessPlayback: true),
      ],
    );

    Widget imageWidget;
    if (cached != null) {
      imageWidget = imageLayer(cached);
    } else {
      imageWidget = FutureBuilder<Uint8List?>(
        future: _thumbFutures[id] ??
            item.asset.thumbnailDataWithSize(
              ThumbnailSize(900, 1200),
              quality: 92,
            ),
        builder: (_, snap) {
          if (snap.hasData && snap.data != null) {
            _thumbCache[id] = snap.data;
            return imageLayer(snap.data!);
          }
          return Container(
            color: const Color(0xFF1C1C1E),
            child: const Center(
              child: CircularProgressIndicator(
                color: Color(0xFF6B4EFF),
                strokeWidth: 2,
              ),
            ),
          );
        },
      );
    }

    // panEnabled mirrors _isZoomed:
    //   • false at scale 1 → single-finger drag reaches SwipeCard's recognizer
    //   • true when zoomed  → SwipeCard nulls its callbacks, IV wins the arena
    return InteractiveViewer(
      transformationController: _zoomController,
      minScale: 1.0,
      maxScale: 5.0,
      panEnabled: _isZoomed,
      clipBehavior: Clip.none,
      child: imageWidget,
    );
  }

  // ── Video badge: camera icon + duration + muted indicator ────────────────────

  Widget _buildVideoBadge(AssetEntity asset) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: Colors.black.withOpacity(0.65),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.videocam_rounded, color: Colors.white, size: 14),
          const SizedBox(width: 4),
          Text(
            _formatDuration(asset.videoDuration),
            style: const TextStyle(color: Colors.white, fontSize: 12),
          ),
          const SizedBox(width: 6),
          const Icon(Icons.volume_off_rounded, color: Colors.white, size: 12),
        ],
      ),
    );
  }

  Widget _buildMeta(SwipeItem item) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Row(
            children: [
              const Icon(Icons.calendar_today_rounded,
                  color: Color(0xFF8E8E93), size: 14),
              const SizedBox(width: 6),
              Text(
                item.formattedDate,
                style: const TextStyle(
                    color: Color(0xFF8E8E93), fontSize: 13),
              ),
            ],
          ),
          if (item.fileSizeBytes != null)
            Row(
              children: [
                const Icon(Icons.storage_rounded,
                    color: Color(0xFF8E8E93), size: 14),
                const SizedBox(width: 4),
                Text(
                  item.fileSizeDisplay,
                  style: const TextStyle(
                      color: Color(0xFF8E8E93), fontSize: 13),
                ),
              ],
            )
          else
            const SizedBox(
              width: 12,
              height: 12,
              child: CircularProgressIndicator(
                strokeWidth: 1.5,
                color: Color(0xFF3A3A3C),
              ),
            ),
        ],
      ),
    );
  }

  // ─── Thumbnail strip ──────────────────────────────────────────────────────────

  Widget _buildThumbnailStrip() {
    // Not worth showing a strip for a single item
    if (_items.length <= 1) return const SizedBox.shrink();

    return Padding(
      padding: const EdgeInsets.only(top: 10),
      child: SizedBox(
        height: 64,
        child: ListView.builder(
          controller: _stripController,
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: _stripPad),
          // addRepaintBoundaries keeps scroll smooth on large lists
          addRepaintBoundaries: true,
          itemCount: _items.length,
          itemBuilder: (_, index) {
            final isActive = index == _currentIndex;
            final decision = _items[index].decision;

            // Colour-coded decision indicator shown as a bottom bar
            final Color? barColor = switch (decision) {
              SwipeDecision.delete => const Color(0xFFFF453A),
              SwipeDecision.keep   => const Color(0xFF30D158),
              SwipeDecision.later  => const Color(0xFFFFD60A),
              SwipeDecision.pending => null,
            };

            return GestureDetector(
              onTap: () => _jumpToIndex(index),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 200),
                width: _stripItemWidth,
                margin: const EdgeInsets.only(right: _stripGap),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(
                    color: isActive
                        ? const Color(0xFF6B4EFF)
                        : Colors.transparent,
                    width: 2.5,
                  ),
                ),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(6),
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      // Thumbnail — reuses card cache when available
                      FutureBuilder<Uint8List?>(
                        future: _getStripThumb(index),
                        builder: (_, snap) {
                          if (snap.hasData && snap.data != null) {
                            return Image.memory(
                              snap.data!,
                              fit: BoxFit.cover,
                              gaplessPlayback: true,
                            );
                          }
                          return Container(color: const Color(0xFF2C2C2E));
                        },
                      ),

                      // Dim non-active items slightly so the active one pops
                      if (!isActive)
                        Container(
                          color: Colors.black.withOpacity(0.28),
                        ),

                      // Video indicator in the top-right corner
                      if (_items[index].asset.type == AssetType.video)
                        Positioned(
                          top: 3,
                          right: 3,
                          child: Icon(
                            Icons.play_circle_filled_rounded,
                            color: Colors.white.withOpacity(0.85),
                            size: 14,
                          ),
                        ),

                      // Decision colour bar at the bottom edge
                      if (barColor != null)
                        Positioned(
                          bottom: 0,
                          left: 0,
                          right: 0,
                          child: Container(height: 3, color: barColor),
                        ),
                    ],
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }

  /// Returns a thumb for the strip.
  /// Reuses the already-loaded high-res card thumb when present;
  /// otherwise fetches a compact 160×160 thumbnail to keep memory low.
  Future<Uint8List?> _getStripThumb(int index) {
    final id = _items[index].asset.id;
    // High-res already in cache → free reuse, no extra fetch
    if (_thumbCache.containsKey(id) && _thumbCache[id] != null) {
      return Future.value(_thumbCache[id]);
    }
    return _stripFutures.putIfAbsent(
      id,
      () => _items[index].asset.thumbnailDataWithSize(
            ThumbnailSize(160, 160),
          ),
    );
  }

  Widget _buildReviewBar() {
    final count =
        _items.where((i) => i.decision == SwipeDecision.delete).length;

    return AnimatedSize(
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeInOut,
      child: count == 0
          ? const SizedBox.shrink()
          : Padding(
              padding: const EdgeInsets.fromLTRB(20, 10, 20, 0),
              child: GestureDetector(
                onTap: _reviewNow,
                child: Container(
                  width: double.infinity,
                  padding: const EdgeInsets.symmetric(
                      vertical: 11, horizontal: 16),
                  decoration: BoxDecoration(
                    color: const Color(0xFFFF453A).withOpacity(0.10),
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(
                      color: const Color(0xFFFF453A).withOpacity(0.35),
                      width: 1,
                    ),
                  ),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Row(
                        children: [
                          const Icon(Icons.delete_outline_rounded,
                              color: Color(0xFFFF453A), size: 16),
                          const SizedBox(width: 7),
                          Text(
                            '$count ${count == 1 ? 'item' : 'items'} marked',
                            style: const TextStyle(
                              color: Color(0xFFFF453A),
                              fontSize: 13,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ],
                      ),
                      const Row(
                        children: [
                          Text(
                            'Review now',
                            style: TextStyle(
                              color: Color(0xFFFF453A),
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          SizedBox(width: 3),
                          Icon(Icons.arrow_forward_rounded,
                              color: Color(0xFFFF453A), size: 13),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ),
    );
  }

  Widget _buildActionButtons() {
    // Default:      [Delete]  [Later]  [Keep]
    // Left-handed:  [Keep]    [Later]  [Delete]
    final leftButton = _leftHanded
        ? _ActionButton(
            icon: Icons.favorite_rounded,
            color: const Color(0xFF30D158),
            label: 'Keep',
            onTap: () => _decide(SwipeDecision.keep),
          )
        : _ActionButton(
            icon: Icons.delete_outline_rounded,
            color: const Color(0xFFFF453A),
            label: 'Delete',
            onTap: () => _decide(SwipeDecision.delete),
          );

    final rightButton = _leftHanded
        ? _ActionButton(
            icon: Icons.delete_outline_rounded,
            color: const Color(0xFFFF453A),
            label: 'Delete',
            onTap: () => _decide(SwipeDecision.delete),
          )
        : _ActionButton(
            icon: Icons.favorite_rounded,
            color: const Color(0xFF30D158),
            label: 'Keep',
            onTap: () => _decide(SwipeDecision.keep),
          );

    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 20, 24, 28),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: [
          leftButton,
          _ActionButton(
            icon: Icons.access_time_rounded,
            color: const Color(0xFFFFD60A),
            label: 'Later',
            size: 52,
            onTap: () => _decide(SwipeDecision.later),
          ),
          rightButton,
        ],
      ),
    );
  }

  String _formatDuration(Duration d) {
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  /// Coarse photo-count bucket. Avoids logging exact counts (which can be
  /// near-identifying for power users) while still giving the dashboard
  /// useful segmentation.
  String _bucketCount(int n) {
    if (n <= 0) return '0';
    if (n < 10) return '1-9';
    if (n < 50) return '10-49';
    if (n < 200) return '50-199';
    if (n < 1000) return '200-999';
    if (n < 5000) return '1000-4999';
    return '5000+';
  }
}

// ─── Progress bar ─────────────────────────────────────────────────────────────

class _ProgressBar extends StatelessWidget {
  final int current;
  final int total;

  const _ProgressBar({required this.current, required this.total});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      child: Column(
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(3),
            child: LinearProgressIndicator(
              value: total > 0 ? current / total : 0,
              backgroundColor: const Color(0xFF2C2C2E),
              valueColor: const AlwaysStoppedAnimation(Color(0xFF6B4EFF)),
              minHeight: 4,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            '${current + 1} of $total',
            style: const TextStyle(color: Color(0xFF8E8E93), fontSize: 12),
          ),
        ],
      ),
    );
  }
}

// ─── Action button ────────────────────────────────────────────────────────────

class _ActionButton extends StatelessWidget {
  final IconData icon;
  final Color color;
  final String label;
  final double size;
  final VoidCallback onTap;

  const _ActionButton({
    required this.icon,
    required this.color,
    required this.label,
    required this.onTap,
    this.size = 60,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: size,
            height: size,
            decoration: BoxDecoration(
              color: color.withOpacity(0.12),
              shape: BoxShape.circle,
              border: Border.all(color: color.withOpacity(0.4), width: 1.5),
            ),
            child: Icon(icon, color: color, size: size * 0.43),
          ),
          const SizedBox(height: 6),
          Text(
            label,
            style: TextStyle(
              color: color.withOpacity(0.8),
              fontSize: 11,
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
      ),
    );
  }
}

// ─── Empty / Error views ──────────────────────────────────────────────────────

class _EmptyView extends StatelessWidget {
  const _EmptyView();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.photo_library_outlined,
              color: Color(0xFF3A3A3C), size: 72),
          const SizedBox(height: 20),
          const Text(
            'No photos found',
            style: TextStyle(
                color: Colors.white,
                fontSize: 20,
                fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 8),
          const Text(
            'There are no photos in this period.',
            style: TextStyle(color: Color(0xFF8E8E93), fontSize: 15),
          ),
          const SizedBox(height: 32),
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text(
              'Go back',
              style: TextStyle(color: Color(0xFF6B4EFF), fontSize: 16),
            ),
          ),
        ],
      ),
    );
  }
}

class _ErrorView extends StatelessWidget {
  final String message;
  final VoidCallback onRetry;

  const _ErrorView({required this.message, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.error_outline_rounded,
                color: Color(0xFFFF453A), size: 64),
            const SizedBox(height: 20),
            Text(
              message,
              textAlign: TextAlign.center,
              style: const TextStyle(color: Color(0xFF8E8E93), fontSize: 15),
            ),
            const SizedBox(height: 28),
            ElevatedButton(
              onPressed: onRetry,
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF6B4EFF),
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12)),
              ),
              child: const Text('Retry'),
            ),
          ],
        ),
      ),
    );
  }
}
