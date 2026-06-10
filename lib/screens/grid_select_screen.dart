import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:photo_manager/photo_manager.dart';
import 'dart:typed_data';

import '../models/swipe_item.dart';
import '../services/analytics_events.dart';
import '../services/analytics_service.dart';
import '../services/media_service.dart';
import 'review_screen.dart';

/// Displays all media for a given month as a tappable grid.
/// Users pick exactly which items to delete — no swiping required.
class GridSelectScreen extends StatefulWidget {
  final int month;
  final int year;

  const GridSelectScreen({
    super.key,
    required this.month,
    required this.year,
  });

  @override
  State<GridSelectScreen> createState() => _GridSelectScreenState();
}

class _GridSelectScreenState extends State<GridSelectScreen> {
  final _service = MediaService.instance;

  List<AssetEntity> _assets = [];
  final Set<String> _selectedIds = {};
  bool _loading = true;

  // Futures cached per asset-id so GridView rebuilds never re-fetch
  final Map<String, Future<Uint8List?>> _thumbFutures = {};
  final Map<String, int?> _fileSizes = {};

  static const _monthNames = [
    'January', 'February', 'March', 'April', 'May', 'June',
    'July', 'August', 'September', 'October', 'November', 'December',
  ];

  String get _monthLabel =>
      '${_monthNames[widget.month - 1]} ${widget.year}';

  @override
  void initState() {
    super.initState();
    unawaited(AnalyticsService.instance.screen('grid_select_screen'));
    _load();
  }

  // ─── Data ────────────────────────────────────────────────────────────────────

  Future<void> _load() async {
    setState(() => _loading = true);
    final startedAt = DateTime.now();
    unawaited(AnalyticsService.instance.track(
      AnalyticsEvents.galleryLoadStarted,
      properties: const {'mode': 'grid_select'},
    ));
    try {
      final assets =
          await _service.loadMonthMedia(widget.month, widget.year);
      unawaited(AnalyticsService.instance.track(
        AnalyticsEvents.galleryLoadCompleted,
        properties: {
          'mode': 'grid_select',
          'photo_count': assets.length,
          'load_time_ms': DateTime.now().difference(startedAt).inMilliseconds,
        },
      ));
      if (!mounted) return;
      setState(() {
        _assets = assets;
        _loading = false;
      });
      // Load file sizes in background — update cells as they arrive
      for (final asset in assets) {
        _service.getFileSize(asset).then((size) {
          if (mounted) setState(() => _fileSizes[asset.id] = size);
        });
      }
    } catch (e) {
      unawaited(AnalyticsService.instance.track(
        AnalyticsEvents.galleryLoadFailed,
        properties: {
          'mode': 'grid_select',
          'error_type': e.runtimeType.toString(),
        },
      ));
      unawaited(AnalyticsService.instance.track(
        AnalyticsEvents.errorOccurred,
        properties: {
          'error_type': e.runtimeType.toString(),
          'context': 'gallery_load_grid',
        },
      ));
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<Uint8List?> _thumb(AssetEntity asset) => _thumbFutures.putIfAbsent(
        asset.id,
        () => asset.thumbnailDataWithSize(ThumbnailSize(240, 240)),
      );

  // ─── Selection logic ─────────────────────────────────────────────────────────

  void _toggle(AssetEntity asset) {
    HapticFeedback.selectionClick();
    setState(() {
      if (_selectedIds.contains(asset.id)) {
        _selectedIds.remove(asset.id);
      } else {
        _selectedIds.add(asset.id);
      }
    });
  }

  void _toggleAll() {
    HapticFeedback.selectionClick();
    setState(() {
      if (_allSelected) {
        _selectedIds.clear();
      } else {
        _selectedIds.addAll(_assets.map((a) => a.id));
      }
    });
  }

  bool get _allSelected =>
      _assets.isNotEmpty && _selectedIds.length == _assets.length;

  int get _totalSelectedBytes => _assets
      .where((a) => _selectedIds.contains(a.id))
      .fold(0, (sum, a) => sum + (_fileSizes[a.id] ?? 0));

  String get _sizeDisplay {
    final b = _totalSelectedBytes;
    if (b == 0) return '';
    if (b < 1024 * 1024) return '${(b / 1024).toStringAsFixed(0)} KB';
    if (b < 1024 * 1024 * 1024) {
      return '${(b / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(b / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
  }

  // ─── Navigation ──────────────────────────────────────────────────────────────

  void _reviewSelected() {
    if (_selectedIds.isEmpty) return;
    HapticFeedback.mediumImpact();

    final toDelete = _assets
        .where((a) => _selectedIds.contains(a.id))
        .map((a) {
          final item = SwipeItem(asset: a)
            ..decision = SwipeDecision.delete
            ..fileSizeBytes = _fileSizes[a.id];
          return item;
        })
        .toList();

    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => ReviewScreen(
          toDelete: toDelete,
          laterItems: const [],
          entryPath: 'grid_select',
        ),
      ),
    );
  }

  // ─── Build ───────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0D0D0D),
      appBar: _buildAppBar(),
      body: _loading ? _buildLoader() : _buildGrid(),
      bottomNavigationBar: _buildBottomBar(),
    );
  }

  PreferredSizeWidget _buildAppBar() {
    return AppBar(
      backgroundColor: const Color(0xFF0D0D0D),
      surfaceTintColor: Colors.transparent,
      leading: IconButton(
        icon: const Icon(Icons.close_rounded, color: Colors.white),
        onPressed: () => Navigator.pop(context),
      ),
      title: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            _monthLabel,
            style: const TextStyle(
              color: Colors.white,
              fontWeight: FontWeight.w700,
              fontSize: 17,
            ),
          ),
          if (_selectedIds.isNotEmpty)
            Text(
              '${_selectedIds.length} selected',
              style: const TextStyle(
                color: Color(0xFFFF453A),
                fontSize: 12,
                fontWeight: FontWeight.w500,
              ),
            ),
        ],
      ),
      centerTitle: true,
      actions: [
        if (!_loading && _assets.isNotEmpty)
          TextButton(
            onPressed: _toggleAll,
            child: Text(
              _allSelected ? 'None' : 'All',
              style: const TextStyle(
                color: Color(0xFF6B4EFF),
                fontWeight: FontWeight.w600,
                fontSize: 15,
              ),
            ),
          ),
      ],
    );
  }

  Widget _buildLoader() {
    return const Center(
      child: CircularProgressIndicator(color: Color(0xFF6B4EFF)),
    );
  }

  Widget _buildGrid() {
    if (_assets.isEmpty) {
      return const Center(
        child: Text(
          'No photos found',
          style: TextStyle(color: Color(0xFF8E8E93), fontSize: 16),
        ),
      );
    }

    return GridView.builder(
      padding: const EdgeInsets.only(
          left: 2, right: 2, top: 2, bottom: 100),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 3,
        mainAxisSpacing: 2,
        crossAxisSpacing: 2,
      ),
      itemCount: _assets.length,
      itemBuilder: (_, i) {
        final asset = _assets[i];
        final selected = _selectedIds.contains(asset.id);
        return _GridCell(
          asset: asset,
          selected: selected,
          thumbFuture: _thumb(asset),
          fileSize: _fileSizes[asset.id],
          onTap: () => _toggle(asset),
        );
      },
    );
  }

  Widget? _buildBottomBar() {
    if (_selectedIds.isEmpty) return null;

    return Container(
      padding: EdgeInsets.fromLTRB(
        16,
        12,
        16,
        MediaQuery.of(context).padding.bottom + 12,
      ),
      decoration: const BoxDecoration(
        color: Color(0xFF1C1C1E),
        border: Border(top: BorderSide(color: Color(0xFF2C2C2E), width: 1)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (_sizeDisplay.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text(
                'Free up $_sizeDisplay',
                style: const TextStyle(
                    color: Color(0xFF8E8E93), fontSize: 13),
              ),
            ),
          SizedBox(
            width: double.infinity,
            height: 52,
            child: ElevatedButton(
              onPressed: _reviewSelected,
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFFFF453A),
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14)),
                elevation: 0,
              ),
              child: Text(
                'Review ${_selectedIds.length} '
                '${_selectedIds.length == 1 ? 'item' : 'items'}',
                style: const TextStyle(
                    fontSize: 16, fontWeight: FontWeight.w600),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ─── Grid cell ────────────────────────────────────────────────────────────────

class _GridCell extends StatelessWidget {
  final AssetEntity asset;
  final bool selected;
  final Future<Uint8List?> thumbFuture;
  final int? fileSize;
  final VoidCallback onTap;

  const _GridCell({
    required this.asset,
    required this.selected,
    required this.thumbFuture,
    required this.fileSize,
    required this.onTap,
  });

  String _sizeLabel(int bytes) {
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(0)}K';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)}M';
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Stack(
        fit: StackFit.expand,
        children: [
          // Thumbnail
          FutureBuilder<Uint8List?>(
            future: thumbFuture,
            builder: (_, snap) {
              if (snap.hasData && snap.data != null) {
                return Image.memory(snap.data!, fit: BoxFit.cover);
              }
              return Container(color: const Color(0xFF1C1C1E));
            },
          ),

          // Selection dim
          AnimatedContainer(
            duration: const Duration(milliseconds: 150),
            color: selected
                ? const Color(0xFFFF453A).withOpacity(0.25)
                : Colors.transparent,
          ),

          // Selected border
          if (selected)
            Positioned.fill(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  border:
                      Border.all(color: const Color(0xFFFF453A), width: 2.5),
                ),
              ),
            ),

          // Checkmark badge
          Positioned(
            top: 6,
            right: 6,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 150),
              width: 22,
              height: 22,
              decoration: BoxDecoration(
                color: selected
                    ? const Color(0xFFFF453A)
                    : Colors.black.withOpacity(0.45),
                shape: BoxShape.circle,
                border: Border.all(
                  color: selected
                      ? const Color(0xFFFF453A)
                      : Colors.white.withOpacity(0.6),
                  width: 1.5,
                ),
              ),
              child: selected
                  ? const Icon(Icons.check_rounded,
                      color: Colors.white, size: 13)
                  : null,
            ),
          ),

          // Video badge
          if (asset.type == AssetType.video)
            const Positioned(
              bottom: 4,
              left: 4,
              child: Icon(Icons.videocam_rounded,
                  color: Colors.white, size: 16),
            ),

          // File-size label (bottom-right)
          if (fileSize != null && fileSize! > 0)
            Positioned(
              bottom: 3,
              right: 4,
              child: Text(
                _sizeLabel(fileSize!),
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 10,
                  fontWeight: FontWeight.w600,
                  shadows: [
                    Shadow(blurRadius: 4, color: Colors.black),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}
