/// Periodic cleanup service.
///
/// Runs once per session (at most once every 24 hours) and performs
/// two phases of local storage cleanup:
///
///   Phase 1 (3 months):  Delete local image files for synced receipts
///                        older than 90 days. Metadata is kept for
///                        duplicate detection.
///
///   Phase 2 (6 months):  Delete entire receipt records (+ sync jobs)
///                        older than 180 days.
///
/// No UI — runs silently in the background on app start.

import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../db/database_helper.dart';

class CleanupService {
  static final CleanupService instance = CleanupService._();
  CleanupService._();

  static const String _prefKeyLastCleanup = 'last_cleanup_timestamp';
  static const int _minHoursBetweenRuns = 24;
  static const int _imageRetentionDays = 90; // 3 months
  static const int _recordRetentionDays = 180; // 6 months

  final DatabaseHelper _db = DatabaseHelper.instance;

  /// Run cleanup if enough time has passed since the last run.
  /// Safe to call on every app start — returns immediately if
  /// a run was performed recently.
  Future<void> runPeriodicCleanupIfNeeded() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final lastRun = prefs.getInt(_prefKeyLastCleanup) ?? 0;
      final now = DateTime.now().millisecondsSinceEpoch;
      final hoursSinceLastRun =
          (now - lastRun) / (1000 * 60 * 60);

      if (hoursSinceLastRun < _minHoursBetweenRuns) {
        debugPrint(
          'Cleanup: skipping — last run ${hoursSinceLastRun.toStringAsFixed(1)}h ago',
        );
        return;
      }

      debugPrint('Cleanup: starting periodic cleanup');

      // Phase 1: delete images for synced receipts > 3 months
      final imagesDeleted = await _cleanupOldImages();

      // Phase 2: delete full records > 6 months
      final recordsDeleted = await _cleanupOldRecords();

      // Save timestamp
      await prefs.setInt(_prefKeyLastCleanup, now);

      debugPrint(
        'Cleanup: done — $imagesDeleted images deleted, '
        '$recordsDeleted records purged',
      );
    } catch (e) {
      debugPrint('Cleanup: error during periodic cleanup: $e');
      // Non-fatal — app continues normally
    }
  }

  /// Phase 1: Delete local image files for synced receipts older than
  /// [_imageRetentionDays]. The receipt metadata row stays in SQLite
  /// so that duplicate detection continues working.
  Future<int> _cleanupOldImages() async {
    final oldReceipts = await _db.getSyncedReceiptsOlderThan(
      _imageRetentionDays,
    );

    int count = 0;
    for (final receipt in oldReceipts) {
      try {
        final file = File(receipt.imagePath);
        if (await file.exists()) {
          await file.delete();
          count++;
          debugPrint('Cleanup: deleted image ${receipt.imagePath}');
        }
      } catch (e) {
        debugPrint('Cleanup: failed to delete image ${receipt.imagePath}: $e');
      }
    }
    return count;
  }

  /// Phase 2: Delete entire receipt records (+ associated sync jobs)
  /// older than [_recordRetentionDays]. After this, the receipt
  /// disappears from the app entirely.
  Future<int> _cleanupOldRecords() async {
    return await _db.deleteReceiptsOlderThan(_recordRetentionDays);
  }
}


