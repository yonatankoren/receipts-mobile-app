/// Export service — builds ZIP files from selected months' receipts.
///
/// Preserves the same hierarchy as Google Drive:
///   month/category/receipt-files
///
/// Also generates a summary.csv with per-month, per-category aggregations.

import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter/foundation.dart';
import 'package:googleapis/drive/v3.dart' as drive;
import 'package:path_provider/path_provider.dart';

import '../db/database_helper.dart';
import '../models/receipt.dart';
import 'auth_service.dart';

/// Whether a receipt has been fully synced to Drive.
bool _isSyncedToDrive(Receipt r) =>
    r.driveFileId != null && r.driveFileId!.isNotEmpty;

/// Build ZIP bytes in a background isolate from path+bytes entries.
Uint8List _encodeZipEntries(List<Map<String, dynamic>> entries) {
  final archive = Archive();
  for (final entry in entries) {
    final path = entry['path'] as String;
    final bytes = entry['bytes'] as Uint8List;
    archive.addFile(ArchiveFile(path, bytes.length, bytes));
  }

  final encoded = ZipEncoder().encode(archive);
  return Uint8List.fromList(encoded);
}

class ExportService {
  static final ExportService instance = ExportService._();
  ExportService._();

  /// Create an export ZIP containing receipts for the given months.
  ///
  /// [monthKeys] — list of month keys in "YYYY-MM" format.
  /// [userName] — user's display name for the ZIP filename.
  /// [onProgress] — callback for progress messages shown in loading UI.
  ///
  /// Returns the absolute path to the created ZIP file.
  Future<String> createExportZip({
    required List<String> monthKeys,
    required String userName,
    void Function(String)? onProgress,
  }) async {
    final db = DatabaseHelper.instance;
    final zipEntries = <Map<String, dynamic>>[];

    // ── 1. Gather receipts for selected months (synced to Drive only) ──
    onProgress?.call('אוסף את הקבלות…');
    final allReceipts = <String, List<Receipt>>{};
    int skippedUnsynced = 0;
    int skippedDuplicates = 0;
    final seenDriveIds = <String>{}; // deduplicate across months
    for (final mk in monthKeys) {
      final receipts = await db.getReceiptsByMonth(mk);
      final synced = receipts.where(_isSyncedToDrive).toList();
      skippedUnsynced += receipts.length - synced.length;

      // Deduplicate by driveFileId — two DB rows can point to the same
      // Drive file when a receipt was imported/processed more than once.
      final unique = <Receipt>[];
      for (final r in synced) {
        if (seenDriveIds.add(r.driveFileId!)) {
          unique.add(r);
        } else {
          skippedDuplicates++;
        }
      }

      if (unique.isNotEmpty) {
        allReceipts[mk] = unique;
      }
    }
    if (skippedUnsynced > 0) {
      debugPrint(
        'ExportService: skipped $skippedUnsynced receipts not yet synced to Drive',
      );
    }
    if (skippedDuplicates > 0) {
      debugPrint(
        'ExportService: deduplicated $skippedDuplicates receipts '
        'sharing the same Drive file',
      );
    }

    // ── 2. Download files and add to archive ──
    onProgress?.call('מוריד קבצים מ-Drive…');

    // Authenticate once for all Drive downloads
    final client = await AuthService.instance.getAuthenticatedClient();
    drive.DriveApi? driveApi;
    if (client != null) {
      driveApi = drive.DriveApi(client);
    }

    if (driveApi == null) {
      client?.close();
      throw Exception('Cannot authenticate with Google Drive');
    }

    try {
      for (final entry in allReceipts.entries) {
        final monthKey = entry.key;
        final receipts = entry.value;

        for (final receipt in receipts) {
          final category = receipt.category ?? 'אחר';

          try {
            // Download from Drive — the single source of truth.
            final result = await _downloadDriveFile(
              driveApi,
              receipt.driveFileId!,
            );

            if (result == null) {
              debugPrint(
                'ExportService: Drive download failed for receipt '
                '${receipt.id} — skipping',
              );
              continue;
            }

            // Sanitize the Drive filename — it may contain '/' (e.g.
            // "רמי לוי 03/2025 (abcd).pdf") which the archive would
            // interpret as a directory separator.
            final safeFileName = result.fileName
                .replaceAll('/', '-')
                .replaceAll(r'\', '-');
            final archivePath = '$monthKey/$category/$safeFileName';
            zipEntries.add({
              'path': archivePath,
              'bytes': result.bytes,
            });
          } catch (e) {
            debugPrint(
              'ExportService: failed to add receipt ${receipt.id}: $e',
            );
            // Continue with other receipts — don't let one failure break export
          }
        }
      }
    } finally {
      client?.close();
    }

    // ── 3. Generate summary.csv ──
    onProgress?.call('מכין סיכום חודשי…');
    final csvContent = _generateSummaryCsv(allReceipts);
    // UTF-8 BOM so Excel opens Hebrew correctly
    final csvBytes = Uint8List.fromList(
      [0xEF, 0xBB, 0xBF, ...utf8.encode(csvContent)],
    );
    zipEntries.add({
      'path': 'summary.csv',
      'bytes': csvBytes,
    });

    // ── 4. Encode ZIP ──
    onProgress?.call('יוצר קובץ ZIP…');
    final zipData = await compute(_encodeZipEntries, zipEntries);

    // ── 5. Write to cache directory ──
    onProgress?.call('מכין את הקובץ לשליחה…');
    final cacheDir = await getTemporaryDirectory();
    final exportsDir = Directory('${cacheDir.path}/exports');
    if (!await exportsDir.exists()) {
      await exportsDir.create(recursive: true);
    }

    final zipFileName = _buildZipFileName(monthKeys, userName);
    final zipFile = File('${exportsDir.path}/$zipFileName');
    await zipFile.writeAsBytes(zipData);

    debugPrint(
      'ExportService: created ZIP at ${zipFile.path} '
      '(${zipData.length} bytes, ${zipEntries.length} files)',
    );
    return zipFile.path;
  }

  // ─── Helpers ──────────────────────────────────────────────────

  /// Download a file from Google Drive by its file ID.
  /// Returns both the file bytes and the actual filename from Drive.
  Future<({Uint8List bytes, String fileName})?> _downloadDriveFile(
    drive.DriveApi api,
    String fileId,
  ) async {
    try {
      // Get file metadata to preserve the original filename/extension
      final fileMeta = await api.files.get(
        fileId,
        $fields: 'name',
      ) as drive.File;

      final media = await api.files.get(
        fileId,
        downloadOptions: drive.DownloadOptions.fullMedia,
      ) as drive.Media;

      final chunks = <int>[];
      await for (final chunk in media.stream) {
        chunks.addAll(chunk);
      }

      final driveName = fileMeta.name ?? 'receipt.jpg';
      return (bytes: Uint8List.fromList(chunks), fileName: driveName);
    } catch (e) {
      debugPrint('ExportService: Drive download failed for $fileId: $e');
      return null;
    }
  }

  /// Build the ZIP filename.
  /// Format: expenses_MM-YY_MM-YY_Firstname_Lastname.zip
  String _buildZipFileName(List<String> monthKeys, String userName) {
    final sorted = List<String>.from(monthKeys)..sort();

    final monthParts = sorted.map((mk) {
      final parts = mk.split('-');
      final year = parts[0].substring(2); // YYYY → YY
      final month = parts[1];
      return '$month-$year';
    }).join('_');

    // Sanitize username for filesystem safety
    final safeName = userName
        .replaceAll(RegExp(r'[/\\:*?"<>|]'), '_')
        .replaceAll(' ', '_');

    return 'expenses_${monthParts}_$safeName.zip';
  }

  /// Generate summary CSV content.
  String _generateSummaryCsv(Map<String, List<Receipt>> receiptsByMonth) {
    final buffer = StringBuffer();
    buffer.writeln('Month,Category,Receipts Count,Total Amount');

    final sortedMonths = receiptsByMonth.keys.toList()..sort();

    for (final monthKey in sortedMonths) {
      final receipts = receiptsByMonth[monthKey]!;

      // Group by category
      final byCategory = <String, List<Receipt>>{};
      for (final r in receipts) {
        final cat = r.category ?? 'אחר';
        byCategory.putIfAbsent(cat, () => []).add(r);
      }

      // Format month as MM/YY
      final parts = monthKey.split('-');
      final displayMonth = '${parts[1]}/${parts[0].substring(2)}';

      final sortedCategories = byCategory.keys.toList()..sort();
      for (final category in sortedCategories) {
        final catReceipts = byCategory[category]!;
        final count = catReceipts.length;
        final total = catReceipts.fold<double>(
          0.0,
          (sum, r) => sum + (r.totalAmount ?? 0.0),
        );
        buffer.writeln(
          '$displayMonth,$category,$count,${total.toStringAsFixed(2)}',
        );
      }
    }

    return buffer.toString();
  }
}
