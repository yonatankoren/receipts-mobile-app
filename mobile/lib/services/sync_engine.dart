/// Sync engine — processes queued jobs when online.
///
/// Architecture:
///   - Monitors connectivity changes.
///   - When online, processes pending jobs in dependency order.
///   - Jobs are idempotent and retryable with exponential backoff.
///   - Runs automatically on app start and connectivity change.
///
/// Job pipeline per receipt:
///   1. uploadImage: Upload to Drive → store drive_file_id/link
///   2. processReceipt: Send image to backend → OCR + LLM → update fields
///   3. sheetsAppend: Append row to Google Sheets (needs both above done)

import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import '../db/database_helper.dart';
import '../models/receipt.dart';
import '../models/sync_job.dart';
import 'auth_service.dart';
import 'drive_service.dart';
import 'image_service.dart';
import 'sheets_service.dart';
import 'backend_service.dart';

class SyncEngine extends ChangeNotifier {
  static final SyncEngine instance = SyncEngine._();
  SyncEngine._();

  final DatabaseHelper _db = DatabaseHelper.instance;
  final Connectivity _connectivity = Connectivity();

  bool _isRunning = false;
  bool _isOnline = false;
  int _pendingCount = 0;
  String? _currentActivity;

  bool get isRunning => _isRunning;
  bool get isOnline => _isOnline;
  int get pendingCount => _pendingCount;
  String? get currentActivity => _currentActivity;

  StreamSubscription? _connectivitySub;
  Timer? _periodicTimer;

  /// Initialize the sync engine — call once on app start
  void init() {
    // Monitor connectivity
    _connectivitySub = _connectivity.onConnectivityChanged.listen(
      (results) {
        final wasOnline = _isOnline;
        _isOnline = results.any((r) => r != ConnectivityResult.none);
        if (_isOnline && !wasOnline) {
          debugPrint('SyncEngine: back online, starting sync');
          runPendingJobs();
        }
        notifyListeners();
      },
    );

    // Check initial connectivity
    _connectivity.checkConnectivity().then((results) {
      _isOnline = results.any((r) => r != ConnectivityResult.none);
      notifyListeners();
      if (_isOnline) {
        runPendingJobs();
      }
    });

    // Periodic sync every 30 seconds when online
    _periodicTimer = Timer.periodic(const Duration(seconds: 30), (_) {
      if (_isOnline && !_isRunning) {
        _refreshPendingCount();
        runPendingJobs();
      }
    });

    _refreshPendingCount();
  }

  @override
  void dispose() {
    _connectivitySub?.cancel();
    _periodicTimer?.cancel();
    super.dispose();
  }

  /// Create the three sync jobs for a newly captured receipt
  Future<void> enqueueReceiptJobs(String receiptId) async {
    final now = DateTime.now();
    final jobs = [
      SyncJob(
        id: '${receiptId}_upload',
        receiptId: receiptId,
        jobType: JobType.uploadImage,
        createdAt: now,
        updatedAt: now,
      ),
      SyncJob(
        id: '${receiptId}_process',
        receiptId: receiptId,
        jobType: JobType.processReceipt,
        createdAt: now,
        updatedAt: now,
      ),
      SyncJob(
        id: '${receiptId}_sheets',
        receiptId: receiptId,
        jobType: JobType.sheetsAppend,
        createdAt: now,
        updatedAt: now,
      ),
    ];

    for (final job in jobs) {
      await _db.insertJob(job);
    }

    await _refreshPendingCount();
    debugPrint('SyncEngine: enqueued 3 jobs for receipt $receiptId');

    // Try to process immediately if online
    if (_isOnline) {
      runPendingJobs();
    }
  }

  /// Process all pending jobs in dependency order
  Future<void> runPendingJobs() async {
    if (_isRunning) return; // Prevent concurrent runs
    if (!AuthService.instance.isSignedIn) {
      debugPrint('SyncEngine: not signed in, skipping');
      return;
    }

    _isRunning = true;
    notifyListeners();

    try {
      while (_isOnline) {
        final job = await _db.getNextReadyJob();
        if (job == null) break; // No more ready jobs

        await _executeJob(job);
        await _refreshPendingCount();
      }
    } catch (e) {
      debugPrint('SyncEngine: error in job loop: $e');
    } finally {
      _isRunning = false;
      _currentActivity = null;
      notifyListeners();
    }
  }

  /// Execute a single job with error handling and retry logic
  Future<void> _executeJob(SyncJob job) async {
    debugPrint('SyncEngine: executing ${job.jobType.name} for ${job.receiptId}');

    job.status = JobStatus.inProgress;
    job.updatedAt = DateTime.now();
    await _db.updateJob(job);

    _currentActivity = _getActivityMessage(job);
    notifyListeners();

    try {
      switch (job.jobType) {
        case JobType.uploadImage:
          await _executeUploadImage(job);
          break;
        case JobType.processReceipt:
          await _executeProcessReceipt(job);
          break;
        case JobType.sheetsAppend:
          await _executeSheetsAppend(job);
          break;
      }

      // Success!
      job.status = JobStatus.completed;
      job.errorMessage = null;
      job.updatedAt = DateTime.now();
      await _db.updateJob(job);
      debugPrint('SyncEngine: completed ${job.jobType.name} for ${job.receiptId}');

      // Check if all jobs for this receipt are done → update receipt status
      await _checkReceiptFullySync(job.receiptId);

    } catch (e) {
      debugPrint('SyncEngine: failed ${job.jobType.name} for ${job.receiptId}: $e');

      job.status = JobStatus.failed;
      job.retryCount++;
      job.errorMessage = e.toString();
      job.nextRetryAt = DateTime.now().add(job.nextRetryDelay);
      job.updatedAt = DateTime.now();
      await _db.updateJob(job);

      if (job.isPermanentlyFailed) {
        // Update receipt status to error
        final receipt = await _db.getReceipt(job.receiptId);
        if (receipt != null) {
          receipt.status = ReceiptStatus.error;
          await _db.updateReceipt(receipt);
        }
      }
    }
  }

  // --- Job executors ---

  Future<void> _executeUploadImage(SyncJob job) async {
    // Idempotency: check if already uploaded
    final receipt = await _db.getReceipt(job.receiptId);
    if (receipt == null) throw Exception('Receipt not found');
    if (receipt.driveFileId != null && receipt.driveFileId!.isNotEmpty) {
      debugPrint('SyncEngine: upload already done for ${job.receiptId}');
      return; // Already uploaded
    }

    // Build Hebrew display name: "<merchant> <MM/YYYY>"
    final merchant = (receipt.merchantName != null && receipt.merchantName!.isNotEmpty)
        ? receipt.merchantName!
        : 'קבלה';
    final displayName = '$merchant ${receipt.sheetsMonth}';

    final result = await DriveService.instance.uploadReceiptImage(
      localPath: receipt.imagePath,
      receiptId: receipt.id,
      monthFolder: receipt.driveFolderName,
      category: receipt.category ?? 'אחר',
      displayName: displayName,
      pdfPath: receipt.pdfPath,
    );

    // Update receipt with Drive info and clear pdfPath (no longer needed locally)
    final updated = receipt.copyWith(
      driveFileId: result.fileId,
      driveFileLink: result.fileLink,
      clearPdfPath: true,
    );
    await _db.updateReceipt(updated);

    // Delete the local PDF now that it's safely in Drive
    if (receipt.pdfPath != null) {
      await ImageService.instance.deletePdf(receipt.id);
      debugPrint('SyncEngine: cleaned up local PDF for ${receipt.id}');
    }
  }

  Future<void> _executeProcessReceipt(SyncJob job) async {
    // Idempotency: check if already processed
    final receipt = await _db.getReceipt(job.receiptId);
    if (receipt == null) throw Exception('Receipt not found');
    if (receipt.rawOcrText != null && receipt.rawOcrText!.isNotEmpty) {
      debugPrint('SyncEngine: processing already done for ${job.receiptId}');
      return; // Already processed
    }

    final result = await BackendService.instance.processReceipt(
      imagePath: receipt.imagePath,
      receiptId: receipt.id,
    );

    // Check for validation failure from the backend
    final status = result['status'] as String? ?? 'ok';
    if (status != 'ok') {
      final reason = result['reason'] as String? ?? 'unknown';
      final messageHe = result['message_he'] as String? ?? 'שגיאה בעיבוד התמונה';
      debugPrint(
        'SyncEngine: validation failed for ${job.receiptId}: $reason — $messageHe',
      );
      // Mark receipt as error with the validation reason
      final errorUpdated = receipt.copyWith(
        status: ReceiptStatus.error,
        rawOcrText: 'VALIDATION_FAILED:$reason',
      );
      await _db.updateReceipt(errorUpdated);
      // Don't retry — this is a permanent failure for this image
      return;
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
      status: ReceiptStatus.processing, // Will become reviewed/synced later
    );
    await _db.updateReceipt(updated);
  }

  Future<void> _executeSheetsAppend(SyncJob job) async {
    final receipt = await _db.getReceipt(job.receiptId);
    if (receipt == null) throw Exception('Receipt not found');

    await SheetsService.instance.appendReceiptRow(receipt);
  }

  /// Check if all jobs for a receipt are done; if so, mark as synced
  Future<void> _checkReceiptFullySync(String receiptId) async {
    final jobs = await _db.getJobsForReceipt(receiptId);
    final allDone = jobs.every((j) => j.status == JobStatus.completed);
    if (allDone) {
      final receipt = await _db.getReceipt(receiptId);
      if (receipt != null && receipt.status != ReceiptStatus.synced) {
        final updated = receipt.copyWith(status: ReceiptStatus.synced);
        await _db.updateReceipt(updated);
        debugPrint('SyncEngine: receipt $receiptId fully synced!');
      }
    }
  }

  Future<void> _refreshPendingCount() async {
    _pendingCount = await _db.getPendingJobCount();
    notifyListeners();
  }

  String _getActivityMessage(SyncJob job) {
    switch (job.jobType) {
      case JobType.uploadImage:
        return 'מעלה תמונה לדרייב...';
      case JobType.processReceipt:
        return 'מעבד קבלה...';
      case JobType.sheetsAppend:
        return 'שומר בגיליון...';
    }
  }
}

