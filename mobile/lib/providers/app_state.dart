/// App state provider — orchestrates capture flow and manages receipt list.
/// Uses ChangeNotifier for simple, effective state management.

import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';
import '../db/database_helper.dart';
import '../models/expense.dart';
import '../models/receipt.dart';
import '../models/sync_job.dart';
import '../services/image_service.dart';
import '../services/sync_engine.dart';
import '../services/backend_service.dart';

class AppState extends ChangeNotifier {
  final DatabaseHelper _db = DatabaseHelper.instance;
  final Uuid _uuid = const Uuid();

  List<Receipt> _receipts = [];
  List<Expense> _expenses = [];
  bool _isLoading = false;
  String? _error;

  List<Receipt> get receipts => _receipts;
  List<Expense> get expenses => _expenses;
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
    notifyListeners();
  }

  /// Core capture flow: save image locally, create receipt, enqueue jobs.
  /// Returns the receipt for immediate navigation to review screen.
  Future<Receipt> captureReceipt(String imagePath) async {
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
    } catch (e) {
      debugPrint('AppState: immediate processing failed: $e');
      return await _db.getReceipt(receiptId);
    }
  }

  /// Save user edits from the review screen
  Future<void> saveReview(Receipt receipt) async {
    final updated = receipt.copyWith(
      status: receipt.status == ReceiptStatus.synced
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

    notifyListeners();
    debugPrint('AppState: confirmed expense receipt, expense=$expenseId deleted');
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
    }
    debugPrint('AppState: cancelled expense receipt $receiptId');
  }
}

