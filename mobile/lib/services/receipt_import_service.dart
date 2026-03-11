/// Unified receipt import pipeline.
///
/// All import flows converge here:
///   - Camera capture
///   - Gallery pick (תמונה)
///   - Document pick (מסמך)
///   - Android Share
///
/// Detects file type, routes to the correct processing path (image vs PDF),
/// and returns a receipt ID ready for the review screen.

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import '../db/database_helper.dart';
import '../models/receipt_validation_exception.dart';
import '../providers/app_state.dart';
import 'image_service.dart';
import 'pdf_import_service.dart';

/// Outcome of a successful import (single receipt).
class ImportResult {
  final String receiptId;
  ImportResult(this.receiptId);
}

/// Thrown when the shared file type is not supported.
class UnsupportedFileException implements Exception {
  final String messageHe;
  UnsupportedFileException(this.messageHe);
  @override
  String toString() => messageHe;
}

class ReceiptImportService {
  static final ReceiptImportService instance = ReceiptImportService._();
  ReceiptImportService._();

  static const _supportedImageExts = {'.jpg', '.jpeg', '.png'};
  static const _supportedPdfExts = {'.pdf'};

  /// Detect whether a file path is a supported image, PDF, or unsupported.
  FileKind detectFileKind(String filePath) {
    final ext = p.extension(filePath).toLowerCase();
    if (_supportedPdfExts.contains(ext)) return FileKind.pdf;
    if (_supportedImageExts.contains(ext)) return FileKind.image;
    return FileKind.unsupported;
  }

  /// Import a single file as a receipt.
  ///
  /// [onProgress] is called with Hebrew status messages for UI feedback.
  /// Throws [UnsupportedFileException] if file type isn't supported.
  /// Throws [ImportException] for PDF-specific errors (too large, etc.).
  /// Throws [ReceiptValidationException] if the backend rejects the content.
  Future<ImportResult> importFile({
    required String filePath,
    required AppState appState,
    String? sourceType,
    void Function(String message)? onProgress,
  }) async {
    final kind = detectFileKind(filePath);

    switch (kind) {
      case FileKind.image:
        return _importImage(filePath, appState, onProgress, sourceType: sourceType ?? 'gallery');
      case FileKind.pdf:
        return _importPdf(filePath, appState, onProgress);
      case FileKind.unsupported:
        throw UnsupportedFileException(
          'סוג קובץ לא נתמך — ניתן לייבא תמונות או PDF',
        );
    }
  }

  /// Import multiple files sequentially, returning results for each.
  ///
  /// Processes every file independently; a failure on one file does not
  /// stop the others. [onFileProgress] reports the current file index.
  Future<List<ImportResult>> importFiles({
    required List<String> filePaths,
    required AppState appState,
    void Function(int fileIndex, int total, String message)? onFileProgress,
  }) async {
    final results = <ImportResult>[];
    for (int i = 0; i < filePaths.length; i++) {
      try {
        final result = await importFile(
          filePath: filePaths[i],
          appState: appState,
          onProgress: (msg) => onFileProgress?.call(i, filePaths.length, msg),
        );
        results.add(result);
      } catch (e) {
        debugPrint('ReceiptImportService: file ${i + 1} failed: $e');
      }
    }
    return results;
  }

  // ─── Private helpers ─────────────────────────────────────────

  Future<ImportResult> _importImage(
    String filePath,
    AppState appState,
    void Function(String)? onProgress,
    {String sourceType = 'gallery'}
  ) async {
    onProgress?.call('שומר ומנתח את הקבלה');
    final receipt = await appState.captureReceipt(filePath, sourceType: sourceType);
    final processed = await appState.processReceiptNow(receipt.id);
    return ImportResult(processed?.id ?? receipt.id);
  }

  Future<ImportResult> _importPdf(
    String filePath,
    AppState appState,
    void Function(String)? onProgress,
  ) async {
    onProgress?.call('טוען מסמך...');

    final pdfResult = await PdfImportService.instance.processPdf(
      filePath: filePath,
      onProgress: (msg) => onProgress?.call(msg),
    );

    onProgress?.call('שומר ומנתח...');

    final receipt = await appState.captureReceipt(pdfResult.firstPageImagePath, sourceType: 'pdf');

    // Save the original PDF for later Drive upload
    final savedPdfPath = await ImageService.instance
        .savePdf(pdfResult.originalPdfPath, receipt.id);
    final withPdf = receipt.copyWith(pdfPath: savedPdfPath);
    await DatabaseHelper.instance.updateReceipt(withPdf);

    final processed = await appState.processReceiptWithOcrText(
      receipt.id,
      pdfResult.mergedOcrText,
    );

    return ImportResult(processed?.id ?? receipt.id);
  }
}

enum FileKind { image, pdf, unsupported }
