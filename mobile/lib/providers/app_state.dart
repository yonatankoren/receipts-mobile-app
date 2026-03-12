/// App state provider — orchestrates capture flow and manages receipt list.
/// Uses ChangeNotifier for simple, effective state management.

import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';
import '../db/database_helper.dart';
import '../models/expense.dart';
import '../models/receipt.dart';
import '../models/sync_job.dart';
import '../services/drive_service.dart';
import '../services/image_service.dart';
import '../services/sheets_service.dart';
import '../services/sync_engine.dart';
import '../services/backend_service.dart';
import '../models/receipt_validation_exception.dart';

class AppState extends ChangeNotifier {
  final DatabaseHelper _db = DatabaseHelper.instance;
  final Uuid _uuid = const Uuid();

  List<Receipt> _receipts = [];
  List<Expense> _expenses = [];
  int _errorBannerCount = 0;
  int _reviewBannerCount = 0;
  int _syncingBannerCount = 0;
  int _pendingExpenseCount = 0;
  bool _isLoading = false;
  String? _error;

  List<Receipt> get receipts => _receipts;
  List<Expense> get expenses => _expenses;
  int get errorBannerCount => _errorBannerCount;
  int get reviewBannerCount => _reviewBannerCount;
  int get syncingBannerCount => _syncingBannerCount;
  int get pendingExpenseCount => _pendingExpenseCount;
  bool get isLoading => _isLoading;
  String? get error => _error;

  /// Receipts grouped by month
  Map<String, List<Receipt>> get receiptsByMonth {
    final map = <String, List<Receipt>>{};
    for (final r in _receipts) {
      final key = r.monthKey;
      map.putIfAbsent(key, () => []).add(r);
    }
    // Sort months descending
    final sorted = Map.fromEntries(
      map.entries.toList()..sort((a, b) => b.key.compareTo(a.key)),
    );
    return sorted;
  }

  /// Load all receipts from DB
  Future<void> loadReceipts() async {
    _isLoading = true;
    notifyListeners();
    try {
      _receipts = await _db.getAllReceipts();
      _error = null;
    } catch (e) {
      _error = e.toString();
    }
    _isLoading = false;
    await loadLaunchDashboardCounts(notify: false);
    notifyListeners();
  }

  /// Loads only lightweight launch/dashboard counts from SQLite.
  /// This is safe to call frequently and avoids loading full receipt rows.
  Future<void> loadLaunchDashboardCounts({bool notify = true}) async {
    try {
      final counts = await _db.getLaunchStatusCounts();
      final expenseCount = await _db.getExpenseCount();
      _errorBannerCount = counts.errorCount;
      _reviewBannerCount = counts.reviewCount;
      _syncingBannerCount = counts.syncingCount;
      _pendingExpenseCount = expenseCount;
    } catch (e) {
      debugPrint('AppState: failed to load dashboard counts: $e');
    }
    if (notify) notifyListeners();
  }

  /// Core capture flow: save image locally, create receipt, enqueue jobs.
  /// Returns the receipt for immediate navigation to review screen.
  Future<Receipt> captureReceipt(String imagePath, {String? sourceType}) async {
    final receiptId = _uuid.v4();
    final now = DateTime.now();

    // 1. Save image to app storage (never lose the photo)
    final savedPath = await ImageService.instance.saveImage(imagePath, receiptId);

    // 2. Create receipt record
    final receipt = Receipt(
      id: receiptId,
      captureTimestamp: now,
      imagePath: savedPath,
      status: ReceiptStatus.captured,
      sourceType: sourceType,
    );

    await _db.insertReceipt(receipt);

    // 3. Add to local list
    _receipts.insert(0, receipt);
    notifyListeners();

    // 4. Enqueue sync jobs (runs in background)
    await SyncEngine.instance.enqueueReceiptJobs(receiptId);

    debugPrint('AppState: captured receipt $receiptId');
    return receipt;
  }

  /// Try to process a receipt immediately (for online quick flow).
  /// This sends to the backend and returns parsed data.
  /// Falls back to returning null if offline or error.
  ///
  /// Throws [ReceiptValidationException] if the backend rejects the image
  /// due to quality/content validation (blurry, too dark, not a receipt, etc.).
  /// Callers should catch this and show the appropriate user-facing UI.
  Future<Receipt?> processReceiptNow(String receiptId) async {
    try {
      final receipt = await _db.getReceipt(receiptId);
      if (receipt == null) return null;

      if (!SyncEngine.instance.isOnline) return receipt;

      // If already processed, return as-is
      if (receipt.rawOcrText != null) return receipt;

      final result = await BackendService.instance.processReceipt(
        imagePath: receipt.imagePath,
        receiptId: receipt.id,
      );

      // Check for validation failure from the backend
      final status = result['status'] as String? ?? 'ok';
      if (status != 'ok') {
        final reason = result['reason'] as String? ?? 'unknown';
        final messageHe = result['message_he'] as String? ?? 'שגיאה בעיבוד התמונה. נסה שוב.';

        // Clean up the receipt since validation failed
        await _cleanupFailedReceipt(receiptId);

        throw ReceiptValidationException(
          status: status,
          reason: reason,
          messageHe: messageHe,
          receiptId: receiptId,
        );
      }

      // Extract confidence scores
      final confMap = <String, double>{};
      if (result['confidence'] is Map) {
        final conf = result['confidence'] as Map<String, dynamic>;
        conf.forEach((key, value) {
          if (value is num) confMap[key] = value.toDouble();
        });
      }

      // Update receipt with parsed data
      final updated = receipt.copyWith(
        merchantName: result['merchant_name'] as String?,
        receiptDate: result['receipt_date'] as String?,
        totalAmount: result['total_amount'] != null
            ? (result['total_amount'] as num).toDouble()
            : null,
        currency: (result['currency'] as String?) ?? receipt.currency,
        category: result['category'] as String?,
        rawOcrText: result['raw_ocr_text'] as String?,
        overallConfidence: confMap['overall'],
        fieldConfidences: confMap,
        status: ReceiptStatus.processing,
      );

      await _db.updateReceipt(updated);

      // Mark the processReceipt job as completed
      final jobs = await _db.getJobsForReceipt(receiptId);
      for (final job in jobs) {
        if (job.jobType == JobType.processReceipt) {
          job.status = JobStatus.completed;
          await _db.updateJob(job);
        }
      }

      // Update local list
      final idx = _receipts.indexWhere((r) => r.id == receiptId);
      if (idx >= 0) _receipts[idx] = updated;
      notifyListeners();

      return updated;
    } on ReceiptValidationException {
      rethrow; // Let callers handle validation failures
    } catch (e) {
      debugPrint('AppState: immediate processing failed: $e');
      return await _db.getReceipt(receiptId);
    }
  }

  /// Clean up a receipt that failed validation — remove image and DB record.
  Future<void> _cleanupFailedReceipt(String receiptId) async {
    final receipt = await _db.getReceipt(receiptId);
    if (receipt != null) {
      // Delete the local image
      try {
        final file = File(receipt.imagePath);
        if (await file.exists()) {
          await file.delete();
        }
      } catch (e) {
        debugPrint('AppState: failed to delete image for failed receipt: $e');
      }

      // Delete associated sync jobs
      final jobs = await _db.getJobsForReceipt(receiptId);
      for (final job in jobs) {
        job.status = JobStatus.completed;
        await _db.updateJob(job);
      }

      // Delete receipt from DB
      await _db.deleteReceipt(receiptId);
      _receipts.removeWhere((r) => r.id == receiptId);
      notifyListeners();
    }
    debugPrint('AppState: cleaned up failed-validation receipt $receiptId');
  }

  /// Process a receipt using pre-extracted OCR text (e.g. from PDF pages).
  /// Sends text to /parseReceipt for LLM extraction and updates the receipt.
  Future<Receipt?> processReceiptWithOcrText(
    String receiptId,
    String ocrText,
  ) async {
    try {
      final receipt = await _db.getReceipt(receiptId);
      if (receipt == null) return null;

      final result = await BackendService.instance.parseReceiptText(
        ocrText: ocrText,
        receiptId: receiptId,
      );

      final status = result['status'] as String? ?? 'ok';
      if (status != 'ok') {
        final reason = result['reason'] as String? ?? 'unknown';
        final messageHe =
            result['message_he'] as String? ?? 'שגיאה בעיבוד המסמך.';
        await _cleanupFailedReceipt(receiptId);
        throw ReceiptValidationException(
          status: status,
          reason: reason,
          messageHe: messageHe,
          receiptId: receiptId,
        );
      }

      final confMap = <String, double>{};
      if (result['confidence'] is Map) {
        final conf = result['confidence'] as Map<String, dynamic>;
        conf.forEach((key, value) {
          if (value is num) confMap[key] = value.toDouble();
        });
      }

      final updated = receipt.copyWith(
        merchantName: result['merchant_name'] as String?,
        receiptDate: result['receipt_date'] as String?,
        totalAmount: result['total_amount'] != null
            ? (result['total_amount'] as num).toDouble()
            : null,
        currency: (result['currency'] as String?) ?? receipt.currency,
        category: result['category'] as String?,
        rawOcrText: ocrText,
        overallConfidence: confMap['overall'],
        fieldConfidences: confMap,
        status: ReceiptStatus.processing,
      );

      await _db.updateReceipt(updated);

      // Mark the processReceipt job as completed (OCR was done externally)
      final jobs = await _db.getJobsForReceipt(receiptId);
      for (final job in jobs) {
        if (job.jobType == JobType.processReceipt) {
          job.status = JobStatus.completed;
          await _db.updateJob(job);
        }
      }

      final idx = _receipts.indexWhere((r) => r.id == receiptId);
      if (idx >= 0) _receipts[idx] = updated;
      notifyListeners();

      return updated;
    } on ReceiptValidationException {
      rethrow;
    } catch (e) {
      debugPrint('AppState: OCR text processing failed: $e');
      return await _db.getReceipt(receiptId);
    }
  }

  /// Save user edits from the review screen.
  /// Merges user-editable fields onto the latest DB state so that
  /// system-managed fields (driveFileId, driveFileLink, rawOcrText, etc.)
  /// are never accidentally overwritten with stale/null values.
  Future<void> saveReview(Receipt receipt) async {
    // Read the freshest copy from DB (may have driveFileLink set by upload job)
    final fresh = await _db.getReceipt(receipt.id);
    final base = fresh ?? receipt;

    final updated = base.copyWith(
      // User-editable fields — always take from the review screen
      merchantName: receipt.merchantName,
      receiptDate: receipt.receiptDate,
      totalAmount: receipt.totalAmount,
      currency: receipt.currency,
      category: receipt.category,
      status: base.status == ReceiptStatus.synced
          ? ReceiptStatus.synced
          : ReceiptStatus.reviewed,
    );
    await _db.updateReceipt(updated);

    final idx = _receipts.indexWhere((r) => r.id == receipt.id);
    if (idx >= 0) {
      _receipts[idx] = updated;
    }
    notifyListeners();

    // Trigger sync to push any remaining jobs
    SyncEngine.instance.runPendingJobs();
    await loadLaunchDashboardCounts();
  }

  /// Refresh a single receipt from DB
  Future<Receipt?> refreshReceipt(String receiptId) async {
    final receipt = await _db.getReceipt(receiptId);
    if (receipt != null) {
      final idx = _receipts.indexWhere((r) => r.id == receiptId);
      if (idx >= 0) {
        _receipts[idx] = receipt;
      }
      notifyListeners();
    }
    return receipt;
  }

  // ===== DUPLICATE DETECTION =====

  /// Check if a receipt is a likely duplicate of an existing one.
  /// Returns the first matching receipt, or null if none found.
  Future<Receipt?> checkForDuplicate(Receipt receipt) async {
    final dupes = await _db.findDuplicateReceipts(
      merchantName: receipt.merchantName,
      receiptDate: receipt.receiptDate,
      totalAmount: receipt.totalAmount,
      excludeId: receipt.id,
    );
    return dupes.isNotEmpty ? dupes.first : null;
  }

  // ===== EXPENSE OPERATIONS =====

  /// Load all pending expenses from DB
  Future<void> loadExpenses() async {
    try {
      _expenses = await _db.getAllExpenses();
      _pendingExpenseCount = _expenses.length;
    } catch (e) {
      debugPrint('AppState: failed to load expenses: $e');
    }
    notifyListeners();
  }

  /// Add a new manual expense (no receipt)
  Future<Expense> addExpense({
    required String name,
    required String date,
    required double amount,
    required String paidTo,
  }) async {
    final expense = Expense(
      id: _uuid.v4(),
      name: name,
      date: date,
      amount: amount,
      paidTo: paidTo,
    );

    await _db.insertExpense(expense);
    _expenses.insert(0, expense);
    _pendingExpenseCount = _expenses.length;
    // Re-sort by date descending
    _expenses.sort((a, b) => b.date.compareTo(a.date));
    notifyListeners();

    debugPrint('AppState: added expense ${expense.id}');
    return expense;
  }

  /// Delete a pending expense
  Future<void> deleteExpense(String expenseId) async {
    await _db.deleteExpense(expenseId);
    _expenses.removeWhere((e) => e.id == expenseId);
    _pendingExpenseCount = _expenses.length;
    notifyListeners();
  }

  /// Capture a receipt image linked to an expense.
  /// Saves image + creates receipt record but does NOT enqueue sync jobs.
  /// Sync jobs are deferred until the user confirms (after amount check).
  Future<Receipt> captureReceiptForExpense(String imagePath) async {
    final receiptId = _uuid.v4();
    final now = DateTime.now();

    // 1. Save image to app storage
    final savedPath = await ImageService.instance.saveImage(imagePath, receiptId);

    // 2. Create receipt record (no sync jobs yet)
    final receipt = Receipt(
      id: receiptId,
      captureTimestamp: now,
      imagePath: savedPath,
      status: ReceiptStatus.captured,
    );

    await _db.insertReceipt(receipt);
    _receipts.insert(0, receipt);
    notifyListeners();

    debugPrint('AppState: captured receipt for expense, id=$receiptId (no sync jobs yet)');
    return receipt;
  }

  /// Confirm expense receipt — enqueue sync jobs and delete the expense.
  /// Called after user confirms the amount (or picks one in mismatch dialog).
  Future<void> confirmExpenseReceipt({
    required String receiptId,
    required String expenseId,
    required double chosenAmount,
  }) async {
    // Update the receipt with the chosen amount and mark as reviewed
    final receipt = await _db.getReceipt(receiptId);
    if (receipt == null) return;

    final updated = receipt.copyWith(
      totalAmount: chosenAmount,
      status: ReceiptStatus.reviewed,
    );
    await _db.updateReceipt(updated);

    final idx = _receipts.indexWhere((r) => r.id == receiptId);
    if (idx >= 0) _receipts[idx] = updated;

    // Enqueue sync jobs (upload to Drive + append to Sheets)
    await SyncEngine.instance.enqueueReceiptJobs(receiptId);

    // Delete the expense
    await _db.deleteExpense(expenseId);
    _expenses.removeWhere((e) => e.id == expenseId);
    _pendingExpenseCount = _expenses.length;

    notifyListeners();
    await loadLaunchDashboardCounts();
    debugPrint('AppState: confirmed expense receipt, expense=$expenseId deleted');
  }

  /// Delete a receipt fully: local image + DB record + Drive file + Sheets row.
  /// Shows progress via a callback and returns true on success.
  /// Throws on fatal errors so callers can show error UI.
  Future<void> deleteReceiptFully(String receiptId) async {
    final receipt = await _db.getReceipt(receiptId);
    if (receipt == null) {
      throw Exception('Receipt not found');
    }

    // 1. Remove from Google Sheets (best-effort)
    try {
      await SheetsService.instance.deleteReceiptRow(receipt);
    } catch (e) {
      debugPrint('deleteReceiptFully: sheets delete failed: $e');
      // Continue — user chose to delete, don't block on Sheets failure
    }

    // 2. Remove from Google Drive + clean up empty folders (best-effort)
    if (receipt.driveFileId != null && receipt.driveFileId!.isNotEmpty) {
      try {
        await DriveService.instance
            .deleteFileAndCleanupFolders(receipt.driveFileId!);
      } catch (e) {
        debugPrint('deleteReceiptFully: drive delete failed: $e');
      }
    }

    // 3. Delete local image
    try {
      final file = File(receipt.imagePath);
      if (await file.exists()) {
        await file.delete();
      }
    } catch (e) {
      debugPrint('deleteReceiptFully: image delete failed: $e');
    }

    // 4. Delete from SQLite (receipt + sync jobs)
    await _db.deleteReceipt(receiptId);
    _receipts.removeWhere((r) => r.id == receiptId);
    notifyListeners();
    await loadLaunchDashboardCounts();

    debugPrint('deleteReceiptFully: fully deleted receipt $receiptId');
  }

  /// Cancel expense receipt — delete the receipt + image, expense stays.
  Future<void> cancelExpenseReceipt(String receiptId) async {
    final receipt = await _db.getReceipt(receiptId);
    if (receipt != null) {
      // Delete the local image
      try {
        final file = File(receipt.imagePath);
        if (await file.exists()) {
          await file.delete();
        }
      } catch (e) {
        debugPrint('AppState: failed to delete image: $e');
      }

      // Delete receipt from DB
      await _db.deleteReceipt(receiptId);
      _receipts.removeWhere((r) => r.id == receiptId);
      notifyListeners();
      await loadLaunchDashboardCounts();
    }
    debugPrint('AppState: cancelled expense receipt $receiptId');
  }
}

