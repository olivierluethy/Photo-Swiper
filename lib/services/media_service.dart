import 'dart:async';

import 'package:photo_manager/photo_manager.dart';

/// Central service for all photo_manager interactions.
/// Uses FilterOptionGroup.createTimeCond for O(month) queries
/// so performance stays constant even with 40,000+ total items.
class MediaService {
  MediaService._();
  static final MediaService instance = MediaService._();

  // ─── In-memory caches ─────────────────────────────────────────────────────
  // Total bytes per "YYYY-MM" key. Computing requires reading every asset's
  // origin file, so we keep results around for the lifetime of the process.
  // Invalidate on deletion via [invalidateMonthSize].
  final Map<String, int> _monthSizeCache = {};
  final Map<String, Future<int>> _monthSizeInFlight = {};

  String _monthKey(int year, int month) =>
      '$year-${month.toString().padLeft(2, '0')}';

  // ─── Permission ────────────────────────────────────────────────────────────

  Future<bool> requestPermission() async {
    final ps = await PhotoManager.requestPermissionExtend();
    return ps.isAuth || ps.hasAccess;
  }

  // ─── Helpers ────────────────────────────────────────────────────────────────

  Future<AssetPathEntity?> _album({FilterOptionGroup? filter}) async {
    final paths = await PhotoManager.getAssetPathList(
      type: RequestType.common,
      hasAll: true,
      onlyAll: true,
      filterOption: filter ?? FilterOptionGroup(),
    );
    return paths.isEmpty ? null : paths.first;
  }

  FilterOptionGroup _monthFilter(int month, int year) {
    final start = DateTime(year, month, 1);
    final end = (month == 12)
        ? DateTime(year + 1, 1, 1)
        : DateTime(year, month + 1, 1);

    return FilterOptionGroup(
      createTimeCond: DateTimeCond(
        min: start,
        max: end.subtract(const Duration(milliseconds: 1)),
      ),
      orders: [
        OrderOption(type: OrderOptionType.createDate, asc: false),
      ],
    );
  }

  // ─── Year range ──────────────────────────────────────────────────────────────

  Future<List<int>> getAvailableYears() async {
    try {
      final album = await _album();
      if (album == null) return [DateTime.now().year];

      final count = await album.assetCountAsync;
      if (count == 0) return [DateTime.now().year];

      final newest = await album.getAssetListRange(start: 0, end: 1);
      final oldest =
          await album.getAssetListRange(start: count - 1, end: count);

      if (newest.isEmpty) return [DateTime.now().year];

      final newestYear = newest.first.createDateTime.year;
      final oldestYear =
          oldest.isEmpty ? newestYear : oldest.first.createDateTime.year;

      final span = (newestYear - oldestYear + 1).clamp(1, 30);
      return List.generate(span, (i) => newestYear - i);
    } catch (_) {
      return [DateTime.now().year];
    }
  }

  // ─── Month counts ────────────────────────────────────────────────────────────

  Future<int> getMonthCount(int month, int year) async {
    try {
      final album = await _album(filter: _monthFilter(month, year));
      if (album == null) return 0;
      return await album.assetCountAsync;
    } catch (_) {
      return 0;
    }
  }

  // ─── Load media ──────────────────────────────────────────────────────────────

  Future<List<AssetEntity>> loadMonthMedia(int month, int year) async {
    try {
      final album = await _album(filter: _monthFilter(month, year));
      if (album == null) return [];

      final count = await album.assetCountAsync;
      if (count == 0) return [];

      const batchSize = 200;
      final all = <AssetEntity>[];

      for (int page = 0; ; page++) {
        final batch =
            await album.getAssetListPaged(page: page, size: batchSize);
        if (batch.isEmpty) break;
        all.addAll(batch);
      }

      return all;
    } catch (_) {
      return [];
    }
  }

  Future<List<AssetEntity>> loadTodayMedia() async {
    final now = DateTime.now();
    final start = DateTime(now.year, now.month, now.day);
    final end =
        DateTime(now.year, now.month, now.day + 1)
            .subtract(const Duration(milliseconds: 1));

    try {
      final filter = FilterOptionGroup(
        createTimeCond: DateTimeCond(min: start, max: end),
        orders: [OrderOption(type: OrderOptionType.createDate, asc: false)],
      );
      final album = await _album(filter: filter);
      if (album == null) return [];
      final count = await album.assetCountAsync;
      if (count == 0) return [];
      return await album.getAssetListRange(start: 0, end: count);
    } catch (_) {
      return [];
    }
  }

  Future<List<AssetEntity>> loadRandomMedia({int limit = 50}) async {
    try {
      final album = await _album();
      if (album == null) return [];
      final count = await album.assetCountAsync;
      if (count == 0) return [];

      // Sample from the whole library, shuffled
      final sample = (count < limit) ? count : limit;
      final assets = await album.getAssetListRange(start: 0, end: sample * 5 > count ? count : sample * 5);
      assets.shuffle();
      return assets.take(limit).toList();
    } catch (_) {
      return [];
    }
  }

  // ─── File size ────────────────────────────────────────────────────────────────

  Future<int?> getFileSize(AssetEntity asset) async {
    try {
      final file = await asset.originFile;
      if (file == null) return null;
      return await file.length();
    } catch (_) {
      return null;
    }
  }

  /// Total byte count for every asset in the given month, summed.
  ///
  /// Backed by a per-process cache — the first call for a month does the
  /// (potentially slow) read; subsequent calls return instantly. Concurrent
  /// calls for the same month share a single in-flight future so we never
  /// double-fetch.
  ///
  /// On iOS, assets that live only in iCloud Photo Library require a
  /// download to measure; this method skips any asset whose origin file is
  /// unavailable (length contribution = 0) rather than blocking on the
  /// download. Total is therefore a *best-effort* lower bound for users
  /// whose library is mostly in the cloud.
  Future<int> getMonthTotalSize(int month, int year) {
    final key = _monthKey(year, month);
    final cached = _monthSizeCache[key];
    if (cached != null) return Future.value(cached);
    final inflight = _monthSizeInFlight[key];
    if (inflight != null) return inflight;

    final future = _computeMonthTotalSize(month, year).then((total) {
      _monthSizeCache[key] = total;
      _monthSizeInFlight.remove(key);
      return total;
    }).catchError((_) {
      _monthSizeInFlight.remove(key);
      return 0;
    });
    _monthSizeInFlight[key] = future;
    return future;
  }

  Future<int> _computeMonthTotalSize(int month, int year) async {
    final assets = await loadMonthMedia(month, year);
    if (assets.isEmpty) return 0;

    // Cap concurrency. Without this, hundreds of parallel `originFile`
    // calls thrash the OS image pipeline (especially the iOS resource
    // coordinator) and the whole batch slows down rather than speeds up.
    const concurrency = 8;
    int total = 0;
    for (int i = 0; i < assets.length; i += concurrency) {
      final slice = assets.sublist(
          i, i + concurrency > assets.length ? assets.length : i + concurrency);
      final sizes = await Future.wait(slice.map(getFileSize));
      for (final s in sizes) {
        if (s != null) total += s;
      }
    }
    return total;
  }

  /// Invalidate a cached month size (call after deletions in that month).
  void invalidateMonthSize(int month, int year) {
    _monthSizeCache.remove(_monthKey(year, month));
  }

  // ─── Delete ──────────────────────────────────────────────────────────────────

  Future<List<String>> deleteAssets(List<AssetEntity> assets) async {
    if (assets.isEmpty) return [];
    try {
      final ids = assets.map((a) => a.id).toList();
      return await PhotoManager.editor.deleteWithIds(ids);
    } catch (_) {
      return [];
    }
  }
}
