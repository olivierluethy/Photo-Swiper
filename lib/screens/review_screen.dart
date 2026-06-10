import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:photo_manager/photo_manager.dart';
import 'dart:typed_data';

import '../models/swipe_item.dart';
import '../services/analytics_events.dart';
import '../services/analytics_service.dart';
import '../services/media_service.dart';
import '../services/review_prompt_service.dart';
import 'result_screen.dart';

class ReviewScreen extends StatefulWidget {
  final List<SwipeItem> toDelete;
  final List<SwipeItem> laterItems;

  /// Number of swipes the user performed in the upstream SwipeScreen
  /// session, or null when entry was via grid-select (no swiping).
  /// Surfaced on cleanup_completed so the funnel can correlate effort
  /// with completion.
  final int? sessionSwipeCount;

  /// Which UI path led the user into review. Tagged on every cleanup
  /// event the screen emits so the swipe and grid-select funnels can be
  /// segmented in dashboards.
  final String entryPath;

  const ReviewScreen({
    super.key,
    required this.toDelete,
    required this.laterItems,
    this.sessionSwipeCount,
    this.entryPath = 'swipe',
  });

  @override
  State<ReviewScreen> createState() => _ReviewScreenState();
}

class _ReviewScreenState extends State<ReviewScreen> {
  final _service = MediaService.instance;
  bool _deleting = false;

  List<SwipeItem> get _selected =>
      widget.toDelete.where((i) => i.isSelectedForDeletion).toList();

  @override
  void initState() {
    super.initState();
    unawaited(AnalyticsService.instance.screen('review_screen'));
    final estimatedBytes = widget.toDelete
        .where((i) => i.isSelectedForDeletion)
        .fold<int>(0, (sum, i) => sum + (i.fileSizeBytes ?? 0));
    unawaited(AnalyticsService.instance.track(
      AnalyticsEvents.cleanupReviewOpened,
      properties: {
        'items_to_delete': widget.toDelete.length,
        'estimated_bytes_freed': estimatedBytes,
      },
    ));
  }

  int get _totalBytes =>
      _selected.fold(0, (sum, i) => sum + (i.fileSizeBytes ?? 0));

  String get _totalSizeDisplay {
    final bytes = _totalBytes;
    if (bytes == 0) return '0 KB';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(0)} KB';
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
  }

  void _toggleItem(SwipeItem item) {
    HapticFeedback.selectionClick();
    setState(() => item.isSelectedForDeletion = !item.isSelectedForDeletion);
  }

  Future<void> _confirmDelete() async {
    if (_selected.isEmpty) {
      _finishWithoutDeletion();
      return;
    }

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: const Color(0xFF1C1C1E),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(20),
        ),
        title: const Text(
          'Delete Photos?',
          style: TextStyle(
              color: Colors.white, fontWeight: FontWeight.w700),
        ),
        content: Text(
          'This will permanently delete ${_selected.length} '
          '${_selected.length == 1 ? 'item' : 'items'} '
          '(${_totalSizeDisplay}). This cannot be undone.',
          style: const TextStyle(color: Color(0xFF8E8E93), height: 1.5),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel',
                style: TextStyle(color: Color(0xFF8E8E93))),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Delete',
                style: TextStyle(
                    color: Color(0xFFFF453A),
                    fontWeight: FontWeight.w600)),
          ),
        ],
      ),
    );

    if (confirmed != true) {
      unawaited(AnalyticsService.instance.track(
        AnalyticsEvents.cleanupCanceled,
        properties: {
          'items_pending': _selected.length,
          'cancel_source': 'in_app_dialog',
        },
      ));
      return;
    }

    setState(() => _deleting = true);
    HapticFeedback.mediumImpact();

    final countBefore = _selected.length;
    final bytesBefore = _totalBytes;

    // Mark the moment we hand off to the OS — this is the last point in
    // the funnel under our control; everything after it is the iOS
    // PHPhotoLibrary system delete sheet, which is otherwise invisible
    // to analytics.
    unawaited(AnalyticsService.instance.track(
      AnalyticsEvents.cleanupSystemDialogInvoked,
      properties: {
        'items_to_delete': countBefore,
        'entry_path': widget.entryPath,
      },
    ));

    // deleteAssets now propagates native errors so the caller can tell
    // "user dismissed the system sheet" (empty list, no throw) apart from
    // "the native call failed" (throw). Catch here so the existing
    // success / no-delete navigation flow is preserved. The
    // [deleteThrew] flag lets the analytics branching below skip the
    // cancel events when the empty result was actually an error.
    List<String> deleted = const [];
    bool deleteThrew = false;
    try {
      deleted = await _service
          .deleteAssets(_selected.map((i) => i.asset).toList());
    } catch (e) {
      deleteThrew = true;
      unawaited(AnalyticsService.instance.track(
        AnalyticsEvents.cleanupDeleteFailed,
        properties: {
          'items_pending': countBefore,
          'error_type': e.runtimeType.toString(),
          'entry_path': widget.entryPath,
        },
      ));
    }

    if (deleted.isNotEmpty) {
      final deletedIds = deleted.toSet();
      final actualFreedBytes = _selected
          .where((i) => deletedIds.contains(i.asset.id))
          .fold<int>(0, (sum, i) => sum + (i.fileSizeBytes ?? 0));
      await ReviewPromptService.instance.recordCleanupCompleted(
        freedBytes: actualFreedBytes,
      );
      // Legacy success event — kept firing so existing dashboards that
      // query cleanup_confirmed continue to work unchanged.
      unawaited(AnalyticsService.instance.track(
        AnalyticsEvents.cleanupConfirmed,
        properties: {
          'items_deleted': deleted.length,
          'bytes_freed': actualFreedBytes,
        },
      ));
      // Canonical completion event — this is what the dashboard's
      // "cleanup_completed" query reads. session_swipe_count is omitted
      // when the user entered review via grid-select (no swipe session).
      final completedProps = <String, Object>{
        'photos_deleted_count': deleted.length,
        'bytes_freed': actualFreedBytes,
        'entry_path': widget.entryPath,
      };
      if (widget.sessionSwipeCount != null) {
        completedProps['session_swipe_count'] = widget.sessionSwipeCount!;
      }
      unawaited(AnalyticsService.instance.track(
        AnalyticsEvents.cleanupCompleted,
        properties: completedProps,
      ));
    } else if (!deleteThrew) {
      // Empty result with no thrown error == user dismissed the iOS
      // system delete sheet. The legacy cleanup_canceled (cancel_source=
      // 'system_dialog') is preserved for back-compat alongside the new,
      // distinctly-named event. When deleteThrew is true the error event
      // already fired above and we deliberately do NOT also record a
      // cancel — that's exactly the conflation this change fixes.
      unawaited(AnalyticsService.instance.track(
        AnalyticsEvents.cleanupCanceled,
        properties: {
          'items_pending': countBefore,
          'cancel_source': 'system_dialog',
        },
      ));
      unawaited(AnalyticsService.instance.track(
        AnalyticsEvents.cleanupSystemDialogCancelled,
        properties: {
          'items_pending': countBefore,
          'entry_path': widget.entryPath,
        },
      ));
    }

    if (!mounted) return;
    setState(() => _deleting = false);

    Navigator.pushReplacement(
      context,
      MaterialPageRoute(
        builder: (_) => ResultScreen(
          deletedCount: deleted.length,
          attemptedCount: countBefore,
          freedBytes: bytesBefore,
          laterCount: widget.laterItems.length,
        ),
      ),
    );
  }

  void _finishWithoutDeletion() {
    // Fires for every exit-without-deletion: 'Keep everything' button,
    // 'Nothing to Delete' continue, the close button when toDelete is
    // empty, and the "selected zero items then tapped delete" branch in
    // _confirmDelete. items_finally_selected==0 with
    // items_originally_marked>0 means the user actively deselected
    // everything; equal counts means they reached this exit while
    // leaving the default selection alone.
    unawaited(AnalyticsService.instance.track(
      AnalyticsEvents.cleanupReviewFinishedNoDelete,
      properties: {
        'items_originally_marked': widget.toDelete.length,
        'items_finally_selected': _selected.length,
        'entry_path': widget.entryPath,
      },
    ));
    Navigator.pushReplacement(
      context,
      MaterialPageRoute(
        builder: (_) => ResultScreen(
          deletedCount: 0,
          attemptedCount: 0,
          freedBytes: 0,
          laterCount: widget.laterItems.length,
        ),
      ),
    );
  }

  // ─── Build ────────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0D0D0D),
      body: Stack(
        children: [
          CustomScrollView(
            slivers: [
              _buildAppBar(),
              if (widget.toDelete.isEmpty)
                SliverFillRemaining(
                  child: _NothingToDeleteView(
                    laterCount: widget.laterItems.length,
                    onContinue: _finishWithoutDeletion,
                  ),
                )
              else ...[
                _buildStats(),
                _buildToggleAllButton(),
                _buildGrid(),
                const SliverPadding(padding: EdgeInsets.only(bottom: 120)),
              ],
            ],
          ),
          if (widget.toDelete.isNotEmpty)
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: _buildBottomBar(),
            ),
          if (_deleting)
            Container(
              color: Colors.black.withOpacity(0.75),
              child: const Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    CircularProgressIndicator(color: Color(0xFFFF453A)),
                    SizedBox(height: 20),
                    Text('Deleting...',
                        style: TextStyle(color: Colors.white, fontSize: 16)),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildAppBar() {
    return SliverAppBar(
      pinned: true,
      backgroundColor: const Color(0xFF0D0D0D),
      surfaceTintColor: Colors.transparent,
      leading: widget.toDelete.isEmpty
          ? IconButton(
              icon: const Icon(Icons.close_rounded, color: Colors.white),
              onPressed: _finishWithoutDeletion,
            )
          : null,
      title: const Text(
        'Review',
        style: TextStyle(
            color: Colors.white, fontWeight: FontWeight.w700, fontSize: 20),
      ),
      centerTitle: true,
    );
  }

  Widget _buildStats() {
    return SliverToBoxAdapter(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 0),
        child: Row(
          children: [
            _StatChip(
              icon: Icons.delete_outline_rounded,
              color: const Color(0xFFFF453A),
              value: '${_selected.length}',
              label: 'selected',
            ),
            const SizedBox(width: 12),
            _StatChip(
              icon: Icons.storage_rounded,
              color: const Color(0xFF6B4EFF),
              value: _totalSizeDisplay,
              label: 'to free',
            ),
            if (widget.laterItems.isNotEmpty) ...[
              const SizedBox(width: 12),
              _StatChip(
                icon: Icons.access_time_rounded,
                color: const Color(0xFFFFD60A),
                value: '${widget.laterItems.length}',
                label: 'deferred',
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildToggleAllButton() {
    final allSelected = widget.toDelete.every((i) => i.isSelectedForDeletion);
    return SliverToBoxAdapter(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(
              '${widget.toDelete.length} marked for deletion',
              style: const TextStyle(
                  color: Color(0xFF8E8E93), fontSize: 14),
            ),
            GestureDetector(
              onTap: () {
                HapticFeedback.selectionClick();
                setState(() {
                  for (final item in widget.toDelete) {
                    item.isSelectedForDeletion = !allSelected;
                  }
                });
              },
              child: Text(
                allSelected ? 'Deselect all' : 'Select all',
                style: const TextStyle(
                    color: Color(0xFF6B4EFF),
                    fontSize: 14,
                    fontWeight: FontWeight.w500),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildGrid() {
    return SliverPadding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      sliver: SliverGrid(
        delegate: SliverChildBuilderDelegate(
          (context, index) {
            final item = widget.toDelete[index];
            return _ReviewThumbnail(
              item: item,
              onToggle: () => _toggleItem(item),
            );
          },
          childCount: widget.toDelete.length,
        ),
        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: 3,
          mainAxisSpacing: 3,
          crossAxisSpacing: 3,
          childAspectRatio: 1,
        ),
      ),
    );
  }

  Widget _buildBottomBar() {
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.bottomCenter,
          end: Alignment.topCenter,
          colors: [Color(0xFF0D0D0D), Colors.transparent],
          stops: [0.6, 1.0],
        ),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (_selected.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text(
                'Free up $_totalSizeDisplay',
                style: const TextStyle(
                    color: Color(0xFF8E8E93), fontSize: 13),
              ),
            ),
          SizedBox(
            width: double.infinity,
            height: 54,
            child: ElevatedButton(
              onPressed: _selected.isEmpty ? null : _confirmDelete,
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFFFF453A),
                foregroundColor: Colors.white,
                disabledBackgroundColor: const Color(0xFF3A3A3C),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(16)),
                elevation: 0,
              ),
              child: Text(
                _selected.isEmpty
                    ? 'Nothing selected'
                    : 'Delete ${_selected.length} ${_selected.length == 1 ? 'item' : 'items'}',
                style: const TextStyle(
                    fontSize: 16, fontWeight: FontWeight.w600),
              ),
            ),
          ),
          const SizedBox(height: 10),
          TextButton(
            onPressed: _finishWithoutDeletion,
            child: const Text(
              'Keep everything',
              style: TextStyle(color: Color(0xFF8E8E93), fontSize: 14),
            ),
          ),
        ],
      ),
    );
  }
}

// ─── Review thumbnail cell ─────────────────────────────────────────────────────

class _ReviewThumbnail extends StatelessWidget {
  final SwipeItem item;
  final VoidCallback onToggle;

  const _ReviewThumbnail({required this.item, required this.onToggle});

  @override
  Widget build(BuildContext context) {
    final selected = item.isSelectedForDeletion;

    return GestureDetector(
      onTap: onToggle,
      child: Stack(
        fit: StackFit.expand,
        children: [
          // Thumbnail
          FutureBuilder<Uint8List?>(
            future: item.asset.thumbnailDataWithSize(
              ThumbnailSize(300, 300),
            ),
            builder: (_, snap) {
              if (snap.hasData && snap.data != null) {
                return Image.memory(snap.data!, fit: BoxFit.cover);
              }
              return Container(color: const Color(0xFF1C1C1E));
            },
          ),

          // Deselected dimmer
          if (!selected)
            Container(color: Colors.black.withOpacity(0.55)),

          // Checkmark overlay
          Positioned(
            top: 6,
            right: 6,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 180),
              width: 22,
              height: 22,
              decoration: BoxDecoration(
                color: selected
                    ? const Color(0xFFFF453A)
                    : Colors.transparent,
                shape: BoxShape.circle,
                border: Border.all(
                  color: selected
                      ? const Color(0xFFFF453A)
                      : Colors.white.withOpacity(0.7),
                  width: 2,
                ),
              ),
              child: selected
                  ? const Icon(Icons.check_rounded,
                      color: Colors.white, size: 13)
                  : null,
            ),
          ),

          // File size badge
          if (item.fileSizeBytes != null)
            Positioned(
              bottom: 0,
              left: 0,
              right: 0,
              child: Container(
                padding: const EdgeInsets.symmetric(vertical: 4),
                color: Colors.black.withOpacity(0.55),
                child: Text(
                  item.fileSizeDisplay,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                      color: Colors.white, fontSize: 10),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

// ─── Stat chip ────────────────────────────────────────────────────────────────

class _StatChip extends StatelessWidget {
  final IconData icon;
  final Color color;
  final String value;
  final String label;

  const _StatChip({
    required this.icon,
    required this.color,
    required this.value,
    required this.label,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: color.withOpacity(0.1),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withOpacity(0.2), width: 1),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, color: color, size: 16),
          const SizedBox(width: 6),
          RichText(
            text: TextSpan(
              children: [
                TextSpan(
                  text: value,
                  style: TextStyle(
                    color: color,
                    fontWeight: FontWeight.w700,
                    fontSize: 14,
                  ),
                ),
                TextSpan(
                  text: ' $label',
                  style: const TextStyle(
                    color: Color(0xFF8E8E93),
                    fontSize: 12,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ─── Nothing to delete view ────────────────────────────────────────────────────

class _NothingToDeleteView extends StatelessWidget {
  final int laterCount;
  final VoidCallback onContinue;

  const _NothingToDeleteView(
      {required this.laterCount, required this.onContinue});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 100,
              height: 100,
              decoration: BoxDecoration(
                color: const Color(0xFF30D158).withOpacity(0.12),
                shape: BoxShape.circle,
              ),
              child: const Icon(Icons.check_circle_outline_rounded,
                  color: Color(0xFF30D158), size: 52),
            ),
            const SizedBox(height: 28),
            const Text(
              'Nothing to Delete',
              style: TextStyle(
                  color: Colors.white,
                  fontSize: 24,
                  fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 12),
            Text(
              laterCount > 0
                  ? 'You kept everything and deferred $laterCount item${laterCount == 1 ? '' : 's'} for later.'
                  : 'You kept all your photos. Great job!',
              textAlign: TextAlign.center,
              style: const TextStyle(
                  color: Color(0xFF8E8E93), fontSize: 15, height: 1.5),
            ),
            const SizedBox(height: 36),
            SizedBox(
              width: double.infinity,
              height: 52,
              child: ElevatedButton(
                onPressed: onContinue,
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF6B4EFF),
                  foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14)),
                  elevation: 0,
                ),
                child: const Text('Done',
                    style: TextStyle(
                        fontSize: 16, fontWeight: FontWeight.w600)),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
