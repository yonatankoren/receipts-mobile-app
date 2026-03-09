/// SQLite database helper.
/// Manages local persistence for receipts, sync jobs, and expenses.
/// This is the single source of truth while offline.

import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart' as p;
import '../models/expense.dart';
import '../models/receipt.dart';
import '../models/sync_job.dart';

class DatabaseHelper {
  static final DatabaseHelper instance = DatabaseHelper._();
  static Database? _database;

  DatabaseHelper._();

  Future<Database> get database async {
    if (_database != null) return _database!;
    _database = await _initDatabase();
    return _database!;
  }

  Future<Database> _initDatabase() async {
    final dbPath = await getDatabasesPath();
    final path = p.join(dbPath, 'receipts.db');

    return await openDatabase(
      path,
      version: 2,
      onCreate: _onCreate,
      onUpgrade: _onUpgrade,
    );
  }

  Future<void> _onCreate(Database db, int version) async {
    // Receipts table
    await db.execute('''
      CREATE TABLE receipts (
        id TEXT PRIMARY KEY,
        capture_timestamp INTEGER NOT NULL,
        image_path TEXT NOT NULL,
        merchant_name TEXT,
        receipt_date TEXT,
        total_amount REAL,
        currency TEXT DEFAULT 'ILS',
        category TEXT,
        drive_file_id TEXT,
        drive_file_link TEXT,
        raw_ocr_text TEXT,
        overall_confidence REAL,
        field_confidences TEXT,
        status TEXT DEFAULT 'captured',
        created_at INTEGER NOT NULL,
        updated_at INTEGER NOT NULL
      )
    ''');

    // Sync jobs table
    await db.execute('''
      CREATE TABLE sync_jobs (
        id TEXT PRIMARY KEY,
        receipt_id TEXT NOT NULL,
        job_type TEXT NOT NULL,
        status TEXT DEFAULT 'pending',
        retry_count INTEGER DEFAULT 0,
        max_retries INTEGER DEFAULT 5,
        next_retry_at INTEGER,
        error_message TEXT,
        created_at INTEGER NOT NULL,
        updated_at INTEGER NOT NULL,
        FOREIGN KEY (receipt_id) REFERENCES receipts(id)
      )
    ''');

    // Expenses table (pending expenses without receipts)
    await _createExpensesTable(db);

    // Indexes for efficient queries
    await db.execute(
        'CREATE INDEX idx_receipts_status ON receipts(status)');
    await db.execute(
        'CREATE INDEX idx_receipts_capture ON receipts(capture_timestamp DESC)');
    await db.execute(
        'CREATE INDEX idx_jobs_status ON sync_jobs(status)');
    await db.execute(
        'CREATE INDEX idx_jobs_receipt ON sync_jobs(receipt_id)');
    await db.execute(
        'CREATE INDEX idx_jobs_type_status ON sync_jobs(job_type, status)');
  }

  Future<void> _onUpgrade(Database db, int oldVersion, int newVersion) async {
    if (oldVersion < 2) {
      await _createExpensesTable(db);
    }
  }

  Future<void> _createExpensesTable(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS expenses (
        id TEXT PRIMARY KEY,
        name TEXT NOT NULL,
        date TEXT NOT NULL,
        amount REAL NOT NULL,
        paid_to TEXT NOT NULL,
        created_at INTEGER NOT NULL
      )
    ''');
    await db.execute(
        'CREATE INDEX IF NOT EXISTS idx_expenses_date ON expenses(date DESC)');
  }

  // ===== RECEIPT OPERATIONS =====

  Future<void> insertReceipt(Receipt receipt) async {
    final db = await database;
    await db.insert(
      'receipts',
      receipt.toMap(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<void> updateReceipt(Receipt receipt) async {
    final db = await database;
    receipt.updatedAt = DateTime.now();
    await db.update(
      'receipts',
      receipt.toMap(),
      where: 'id = ?',
      whereArgs: [receipt.id],
    );
  }

  Future<Receipt?> getReceipt(String id) async {
    final db = await database;
    final maps = await db.query('receipts', where: 'id = ?', whereArgs: [id]);
    if (maps.isEmpty) return null;
    return Receipt.fromMap(maps.first);
  }

  Future<List<Receipt>> getAllReceipts() async {
    final db = await database;
    final maps = await db.query(
      'receipts',
      orderBy: 'capture_timestamp DESC',
    );
    return maps.map((m) => Receipt.fromMap(m)).toList();
  }

  Future<List<Receipt>> getReceiptsByMonth(String monthKey) async {
    final db = await database;
    // monthKey is "YYYY-MM", match against receipt_date or capture_timestamp
    final maps = await db.query(
      'receipts',
      where: "receipt_date LIKE ? OR receipt_date IS NULL",
      whereArgs: ['$monthKey%'],
      orderBy: 'capture_timestamp DESC',
    );
    // For receipts without receipt_date, filter by capture_timestamp month
    final all = maps.map((m) => Receipt.fromMap(m)).toList();
    return all.where((r) => r.monthKey == monthKey).toList();
  }

  Future<int> getPendingSyncCount() async {
    final db = await database;
    final result = await db.rawQuery(
      "SELECT COUNT(DISTINCT receipt_id) as cnt FROM sync_jobs WHERE status IN ('pending', 'failed')",
    );
    return (result.first['cnt'] as int?) ?? 0;
  }

  Future<Map<String, int>> getMonthCounts() async {
    final receipts = await getAllReceipts();
    final counts = <String, int>{};
    for (final r in receipts) {
      counts[r.monthKey] = (counts[r.monthKey] ?? 0) + 1;
    }
    return counts;
  }

  /// Rename a category across all receipts. Returns updated row count.
  Future<int> renameCategory(String oldName, String newName) async {
    final db = await database;
    return await db.rawUpdate(
      'UPDATE receipts SET category = ?, updated_at = ? WHERE category = ?',
      [newName, DateTime.now().millisecondsSinceEpoch, oldName],
    );
  }

  // ===== SYNC JOB OPERATIONS =====

  Future<void> insertJob(SyncJob job) async {
    final db = await database;
    await db.insert(
      'sync_jobs',
      job.toMap(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<void> updateJob(SyncJob job) async {
    final db = await database;
    job.updatedAt = DateTime.now();
    await db.update(
      'sync_jobs',
      job.toMap(),
      where: 'id = ?',
      whereArgs: [job.id],
    );
  }

  /// Get next ready job, respecting execution order:
  /// For each receipt: uploadImage → processReceipt → sheetsAppend
  Future<SyncJob?> getNextReadyJob() async {
    final db = await database;
    final now = DateTime.now().millisecondsSinceEpoch;

    // Get all pending/failed jobs that are ready to execute
    final maps = await db.query(
      'sync_jobs',
      where: "(status = 'pending' OR status = 'failed') "
          "AND retry_count < max_retries "
          "AND (next_retry_at IS NULL OR next_retry_at <= ?)",
      whereArgs: [now],
      orderBy: 'created_at ASC',
    );

    if (maps.isEmpty) return null;

    final jobs = maps.map((m) => SyncJob.fromMap(m)).toList();

    // Find the first job whose dependencies are met
    for (final job in jobs) {
      if (await _areDependenciesMet(job)) {
        return job;
      }
    }

    return null;
  }

  /// Check if a job's predecessor jobs for the same receipt are complete.
  /// For sheetsAppend, also requires the receipt to be in 'reviewed' or
  /// 'synced' status — this ensures the user has saved their edits first.
  Future<bool> _areDependenciesMet(SyncJob job) async {
    final db = await database;

    // Define job order
    final predecessors = <JobType>[];
    switch (job.jobType) {
      case JobType.processReceipt:
        // processReceipt can run independently (uses local image)
        break;
      case JobType.sheetsAppend:
        // sheetsAppend needs both uploadImage and processReceipt to be done
        predecessors.addAll([JobType.uploadImage, JobType.processReceipt]);
        break;
      case JobType.uploadImage:
        // uploadImage has no dependencies
        break;
    }

    for (final predType in predecessors) {
      final predJobs = await db.query(
        'sync_jobs',
        where: "receipt_id = ? AND job_type = ?",
        whereArgs: [job.receiptId, predType.name],
      );
      // If predecessor exists and is not completed, dependency not met
      for (final pMap in predJobs) {
        final pJob = SyncJob.fromMap(pMap);
        if (pJob.status != JobStatus.completed) {
          return false;
        }
      }
    }

    // --- Status gate for uploadImage and sheetsAppend ---
    // Block Drive upload and Sheets write until the user has reviewed (saved)
    // the receipt. This ensures:
    //   (a) user edits (merchant, category, amount) are included
    //   (b) Drive upload uses the confirmed category for folder placement
    //   (c) gallery screenshots with sparse OCR data are not written prematurely
    // processReceipt remains ungated so OCR results appear on the review screen.
    if (job.jobType == JobType.uploadImage ||
        job.jobType == JobType.sheetsAppend) {
      final receipt = await getReceipt(job.receiptId);
      if (receipt == null) return false;
      if (receipt.status != ReceiptStatus.reviewed &&
          receipt.status != ReceiptStatus.synced) {
        return false; // Not yet reviewed by user
      }
    }

    return true;
  }

  Future<List<SyncJob>> getJobsForReceipt(String receiptId) async {
    final db = await database;
    final maps = await db.query(
      'sync_jobs',
      where: 'receipt_id = ?',
      whereArgs: [receiptId],
      orderBy: 'created_at ASC',
    );
    return maps.map((m) => SyncJob.fromMap(m)).toList();
  }

  Future<int> getPendingJobCount() async {
    final db = await database;
    final result = await db.rawQuery(
      "SELECT COUNT(*) as cnt FROM sync_jobs WHERE status IN ('pending', 'failed') AND retry_count < max_retries",
    );
    return (result.first['cnt'] as int?) ?? 0;
  }

  /// Check if a specific job type is already completed for a receipt (idempotency)
  Future<bool> isJobCompleted(String receiptId, JobType jobType) async {
    final db = await database;
    final maps = await db.query(
      'sync_jobs',
      where: "receipt_id = ? AND job_type = ? AND status = 'completed'",
      whereArgs: [receiptId, jobType.name],
    );
    return maps.isNotEmpty;
  }

  /// Delete old local images for fully synced receipts (cleanup)
  Future<List<String>> getCleanableImagePaths({int olderThanDays = 30}) async {
    final db = await database;
    final cutoff = DateTime.now()
        .subtract(Duration(days: olderThanDays))
        .millisecondsSinceEpoch;
    final maps = await db.query(
      'receipts',
      columns: ['image_path'],
      where: "status = 'synced' AND drive_file_id IS NOT NULL AND capture_timestamp < ?",
      whereArgs: [cutoff],
    );
    return maps.map((m) => m['image_path'] as String).toList();
  }

  /// Get synced receipts older than [days] whose images can be cleaned up.
  /// Returns full Receipt objects so the cleanup service can delete the files.
  Future<List<Receipt>> getSyncedReceiptsOlderThan(int days) async {
    final db = await database;
    final cutoff = DateTime.now()
        .subtract(Duration(days: days))
        .millisecondsSinceEpoch;
    final maps = await db.query(
      'receipts',
      where: "status = 'synced' AND capture_timestamp < ?",
      whereArgs: [cutoff],
      orderBy: 'capture_timestamp ASC',
    );
    return maps.map((m) => Receipt.fromMap(m)).toList();
  }

  /// Delete all receipt records (+ sync jobs) older than [days].
  /// Used for the 6-month full cleanup phase.
  Future<int> deleteReceiptsOlderThan(int days) async {
    final db = await database;
    final cutoff = DateTime.now()
        .subtract(Duration(days: days))
        .millisecondsSinceEpoch;

    // First delete sync jobs for those receipts
    await db.rawDelete(
      "DELETE FROM sync_jobs WHERE receipt_id IN "
      "(SELECT id FROM receipts WHERE capture_timestamp < ?)",
      [cutoff],
    );

    // Then delete the receipts themselves
    final count = await db.delete(
      'receipts',
      where: "capture_timestamp < ?",
      whereArgs: [cutoff],
    );
    return count;
  }

  /// Delete a receipt and its associated sync jobs
  Future<void> deleteReceipt(String receiptId) async {
    final db = await database;
    await db.delete('sync_jobs', where: 'receipt_id = ?', whereArgs: [receiptId]);
    await db.delete('receipts', where: 'id = ?', whereArgs: [receiptId]);
  }

  // ===== CATEGORY STATS =====

  /// Get the most frequently used categories, ordered by usage count desc.
  Future<List<String>> getTopCategories({int limit = 3}) async {
    final db = await database;
    final result = await db.rawQuery(
      "SELECT category, COUNT(*) as cnt FROM receipts "
      "WHERE category IS NOT NULL AND category != '' "
      "GROUP BY category "
      "ORDER BY cnt DESC "
      "LIMIT ?",
      [limit],
    );
    return result.map((m) => m['category'] as String).toList();
  }

  // ===== DUPLICATE DETECTION =====

  /// Find existing receipts that match on date + amount (same day, same sum).
  /// Merchant name is NOT required — two receipts on the same day with the
  /// same total are suspicious regardless of merchant.
  /// Excludes the receipt with [excludeId] (the one being checked).
  Future<List<Receipt>> findDuplicateReceipts({
    required String? merchantName,
    required String? receiptDate,
    required double? totalAmount,
    String? excludeId,
  }) async {
    // Need at least date + amount to detect duplicates
    if (receiptDate == null || receiptDate.isEmpty || totalAmount == null) {
      return [];
    }

    final db = await database;

    // Query for exact date + amount match
    final maps = await db.query(
      'receipts',
      where: "receipt_date = ? AND total_amount = ? "
          "AND status != 'captured' "
          "${excludeId != null ? "AND id != ?" : ""}",
      whereArgs: [
        receiptDate,
        totalAmount,
        if (excludeId != null) excludeId,
      ],
    );

    if (maps.isEmpty) return [];

    return maps.map((m) => Receipt.fromMap(m)).toList();
  }

  // ===== EXPENSE OPERATIONS =====

  Future<void> insertExpense(Expense expense) async {
    final db = await database;
    await db.insert(
      'expenses',
      expense.toMap(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<List<Expense>> getAllExpenses() async {
    final db = await database;
    final maps = await db.query(
      'expenses',
      orderBy: 'date DESC',
    );
    return maps.map((m) => Expense.fromMap(m)).toList();
  }

  Future<Expense?> getExpense(String id) async {
    final db = await database;
    final maps = await db.query('expenses', where: 'id = ?', whereArgs: [id]);
    if (maps.isEmpty) return null;
    return Expense.fromMap(maps.first);
  }

  Future<void> deleteExpense(String id) async {
    final db = await database;
    await db.delete('expenses', where: 'id = ?', whereArgs: [id]);
  }

  Future<int> getExpenseCount() async {
    final db = await database;
    final result = await db.rawQuery('SELECT COUNT(*) as cnt FROM expenses');
    return (result.first['cnt'] as int?) ?? 0;
  }
}

