/// Local image storage service.
/// Saves receipt images to app-private storage.
/// Images are NEVER deleted until confirmed uploaded to Drive.

import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;

class ImageService {
  static final ImageService instance = ImageService._();
  ImageService._();

  /// Get the app-private directory for receipt images
  Future<Directory> get _imageDir async {
    final appDir = await getApplicationDocumentsDirectory();
    final dir = Directory(p.join(appDir.path, 'receipt_images'));
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir;
  }

  /// Save a captured image to app storage.
  /// Returns the saved file path.
  Future<String> saveImage(String sourcePath, String receiptId) async {
    final dir = await _imageDir;
    final destPath = p.join(dir.path, '$receiptId.jpg');
    final destFile = File(destPath);

    // If already saved (idempotent), return existing path
    if (await destFile.exists()) {
      debugPrint('Image already saved: $destPath');
      return destPath;
    }

    final sourceFile = File(sourcePath);
    if (!await sourceFile.exists()) {
      throw Exception('Source image not found: $sourcePath');
    }

    // Copy to app storage (don't move — source might be temp camera file)
    await sourceFile.copy(destPath);
    debugPrint('Image saved: $destPath (${await destFile.length()} bytes)');

    return destPath;
  }

  /// Save a PDF to app storage alongside the receipt image.
  /// Returns the saved file path.
  Future<String> savePdf(String sourcePath, String receiptId) async {
    final dir = await _imageDir;
    final destPath = p.join(dir.path, '$receiptId.pdf');
    final destFile = File(destPath);

    if (await destFile.exists()) {
      debugPrint('PDF already saved: $destPath');
      return destPath;
    }

    final sourceFile = File(sourcePath);
    if (!await sourceFile.exists()) {
      throw Exception('Source PDF not found: $sourcePath');
    }

    await sourceFile.copy(destPath);
    debugPrint('PDF saved: $destPath (${await destFile.length()} bytes)');
    return destPath;
  }

  /// Delete a local PDF (after confirmed Drive upload)
  Future<void> deletePdf(String receiptId) async {
    final dir = await _imageDir;
    final file = File(p.join(dir.path, '$receiptId.pdf'));
    if (await file.exists()) {
      await file.delete();
      debugPrint('PDF deleted: ${file.path}');
    }
  }

  /// Check if a receipt image exists locally
  Future<bool> imageExists(String receiptId) async {
    final dir = await _imageDir;
    final file = File(p.join(dir.path, '$receiptId.jpg'));
    return file.exists();
  }

  /// Get the local path for a receipt image
  Future<String> getImagePath(String receiptId) async {
    final dir = await _imageDir;
    return p.join(dir.path, '$receiptId.jpg');
  }

  /// Delete a local image (only after confirmed Drive upload)
  Future<void> deleteImage(String receiptId) async {
    final dir = await _imageDir;
    final file = File(p.join(dir.path, '$receiptId.jpg'));
    if (await file.exists()) {
      await file.delete();
      debugPrint('Image deleted: ${file.path}');
    }
  }

  /// Get total size of stored images (for debug/settings)
  Future<int> getTotalStorageBytes() async {
    final dir = await _imageDir;
    if (!await dir.exists()) return 0;
    int total = 0;
    await for (final entity in dir.list()) {
      if (entity is File) {
        total += await entity.length();
      }
    }
    return total;
  }
}

