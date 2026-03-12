/// PDF import service — renders PDF pages to images, OCRs each page, and
/// merges the text for a single LLM extraction pass.
///
/// Architecture notes:
///   - Each page is rendered independently → separate OCR call → merged text.
///   - Merchant name typically appears on page 1; final total on the last page.
///   - The merged text uses [עמוד N] markers so the LLM can reason about
///     page boundaries. Future heuristics can hook into these markers.
///   - The first page render is kept as the receipt's representative image.

import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:pdfx/pdfx.dart';
import 'backend_service.dart';

/// Result of a successful PDF import.
class PdfImportResult {
  final String mergedOcrText;
  final String firstPageImagePath;
  final String originalPdfPath;
  final int pageCount;

  PdfImportResult({
    required this.mergedOcrText,
    required this.firstPageImagePath,
    required this.originalPdfPath,
    required this.pageCount,
  });
}

/// Thrown for user-facing import errors (file too large, too many pages, etc.).
class ImportException implements Exception {
  final String messageHe;
  ImportException(this.messageHe);

  @override
  String toString() => messageHe;
}

class PdfImportService {
  static final PdfImportService instance = PdfImportService._();
  PdfImportService._();

  static const int maxPages = 4;
  static const int maxFileSizeBytes = 20 * 1024 * 1024; // 20 MB
  static const int ocrMaxLongEdgePx = 2200;

  /// Process a PDF file: render pages → OCR each → merge text.
  ///
  /// [onProgress] is called with Hebrew status messages for UI feedback.
  /// Returns [PdfImportResult] with the merged OCR text and the first page
  /// image path (to be used as the receipt's representative image).
  Future<PdfImportResult> processPdf({
    required String filePath,
    required void Function(String message) onProgress,
  }) async {
    final file = File(filePath);
    final fileSize = await file.length();
    if (fileSize > maxFileSizeBytes) {
      throw ImportException('הקובץ גדול מדי — עד 20MB');
    }

    final document = await PdfDocument.openFile(filePath);
    final pageCount = document.pagesCount;

    if (pageCount == 0) {
      await document.close();
      throw ImportException('המסמך ריק');
    }

    if (pageCount > maxPages) {
      await document.close();
      throw ImportException(
        'המסמך ארוך מדי — עד $maxPages עמודים לקבלה',
      );
    }

    onProgress('זוהה מסמך בן $pageCount עמודים');

    final tempDir = await getTemporaryDirectory();
    String? firstPagePath;
    final ocrParts = <String>[];

    try {
      for (int i = 1; i <= pageCount; i++) {
        onProgress('מעבד עמוד $i מתוך $pageCount');

        // Render page to image
        final page = await document.getPage(i);
        final targetSize = _targetRenderSize(page.width, page.height);
        final pageImage = await page.render(
          width: targetSize.width,
          height: targetSize.height,
          format: PdfPageImageFormat.jpeg,
          backgroundColor: '#ffffff',
        );
        await page.close();

        if (pageImage == null) {
          throw ImportException('לא ניתן לקרוא עמוד $i');
        }

        if (i == 1) {
          final ts = DateTime.now().millisecondsSinceEpoch;
          final pagePath = '${tempDir.path}/pdf_page_${i}_$ts.jpg';
          final pageFile = File(pagePath);
          await pageFile.writeAsBytes(pageImage.bytes);
          firstPagePath = pagePath;
        }

        // OCR this page via backend
        try {
          final ocrText = await BackendService.instance.ocrOnlyBytes(
            imageBytes: pageImage.bytes,
          );
          if (ocrText.trim().isNotEmpty) {
            ocrParts.add(ocrText.trim());
          } else {
            debugPrint('PdfImportService: empty OCR for page $i (skipping)');
          }
        } catch (e) {
          debugPrint('PdfImportService: OCR failed for page $i: $e');
          // Continue with remaining pages instead of failing entirely
        }
      }
    } finally {
      await document.close();
    }

    if (ocrParts.isEmpty) {
      throw ImportException('לא ניתן לחלץ טקסט מהמסמך');
    }

    // Merge with page markers for LLM context
    final merged = ocrParts
        .asMap()
        .entries
        .map((e) => '[עמוד ${e.key + 1}]\n${e.value}')
        .join('\n\n');

    return PdfImportResult(
      mergedOcrText: merged,
      firstPageImagePath: firstPagePath!,
      originalPdfPath: filePath,
      pageCount: pageCount,
    );
  }

  ({double width, double height}) _targetRenderSize(
    double srcWidth,
    double srcHeight,
  ) {
    final longEdge = srcWidth > srcHeight ? srcWidth : srcHeight;
    if (longEdge <= ocrMaxLongEdgePx) {
      return (width: srcWidth, height: srcHeight);
    }

    final scale = ocrMaxLongEdgePx / longEdge;
    return (
      width: srcWidth * scale,
      height: srcHeight * scale,
    );
  }
}
