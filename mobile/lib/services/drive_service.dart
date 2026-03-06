/// Google Drive service.
/// Handles uploading receipt images to organized folders by month and category.
/// Folder structure: Receipts/YYYY-MM/category/receipt_id.jpg
///
/// Folders are created lazily — only when a receipt needs them.
/// Idempotency: checks if file already exists by name before uploading.

import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:googleapis/drive/v3.dart' as drive;
import 'auth_service.dart';
import '../utils/constants.dart';

class DriveService {
  static final DriveService instance = DriveService._();
  DriveService._();

  /// Upload a receipt image to Drive.
  /// Returns (fileId, webViewLink) or throws on failure.
  ///
  /// Idempotent: if a file with the same name exists in the target folder,
  /// returns its existing ID instead of creating a duplicate.
  Future<({String fileId, String fileLink})> uploadReceiptImage({
    required String localPath,
    required String receiptId,
    required String monthFolder, // "YYYY-MM"
    required String category, // e.g. "מזון", "תחבורה", "אחר"
  }) async {
    final client = await AuthService.instance.getAuthenticatedClient();
    if (client == null) {
      throw Exception('Not authenticated — cannot upload to Drive');
    }

    try {
      final driveApi = drive.DriveApi(client);
      final fileName = '$receiptId.jpg';

      // 1. Ensure root "Receipts" folder exists
      final rootFolderId = await _ensureFolder(
        driveApi,
        AppConstants.driveFolderRoot,
        'root',
      );

      // 2. Ensure month subfolder exists (created lazily)
      final monthFolderId = await _ensureFolder(
        driveApi,
        monthFolder,
        rootFolderId,
      );

      // 3. Ensure category subfolder inside month (created lazily)
      final categoryFolderId = await _ensureFolder(
        driveApi,
        category,
        monthFolderId,
      );

      // 4. Check if file already exists (idempotency)
      final existing = await driveApi.files.list(
        q: "name = '$fileName' and '$categoryFolderId' in parents and trashed = false",
        spaces: 'drive',
        $fields: 'files(id, webViewLink)',
      );

      if (existing.files != null && existing.files!.isNotEmpty) {
        final file = existing.files!.first;
        debugPrint('Drive: file already exists: ${file.id}');
        return (
          fileId: file.id!,
          fileLink: file.webViewLink ?? 'https://drive.google.com/file/d/${file.id}/view',
        );
      }

      // 5. Upload the file into the category subfolder
      final localFile = File(localPath);
      if (!await localFile.exists()) {
        throw Exception('Local image not found: $localPath');
      }

      final media = drive.Media(localFile.openRead(), await localFile.length());
      final driveFile = drive.File()
        ..name = fileName
        ..parents = [categoryFolderId]
        ..mimeType = 'image/jpeg';

      final uploaded = await driveApi.files.create(
        driveFile,
        uploadMedia: media,
        $fields: 'id, webViewLink',
      );

      debugPrint('Drive: uploaded ${uploaded.id} → $monthFolder/$category/');
      return (
        fileId: uploaded.id!,
        fileLink: uploaded.webViewLink ?? 'https://drive.google.com/file/d/${uploaded.id}/view',
      );
    } finally {
      client.close();
    }
  }

  /// Ensure a folder exists in Drive. Returns the folder ID.
  /// Creates it if it doesn't exist.
  Future<String> _ensureFolder(
    drive.DriveApi api,
    String folderName,
    String parentId,
  ) async {
    // Search for existing folder
    final parentQuery = parentId == 'root'
        ? "'root' in parents"
        : "'$parentId' in parents";

    final search = await api.files.list(
      q: "name = '$folderName' and $parentQuery and mimeType = 'application/vnd.google-apps.folder' and trashed = false",
      spaces: 'drive',
      $fields: 'files(id)',
    );

    if (search.files != null && search.files!.isNotEmpty) {
      return search.files!.first.id!;
    }

    // Create folder
    final folder = drive.File()
      ..name = folderName
      ..mimeType = 'application/vnd.google-apps.folder'
      ..parents = [parentId];

    final created = await api.files.create(folder, $fields: 'id');
    debugPrint('Drive: created folder "$folderName" → ${created.id}');
    return created.id!;
  }

  /// Get the web link for a month folder (for "Open in Drive" action)
  Future<String?> getMonthFolderLink(String monthFolder) async {
    final client = await AuthService.instance.getAuthenticatedClient();
    if (client == null) return null;

    try {
      final driveApi = drive.DriveApi(client);

      // Find root folder
      final rootSearch = await driveApi.files.list(
        q: "name = '${AppConstants.driveFolderRoot}' and 'root' in parents and mimeType = 'application/vnd.google-apps.folder' and trashed = false",
        spaces: 'drive',
        $fields: 'files(id)',
      );
      if (rootSearch.files == null || rootSearch.files!.isEmpty) return null;
      final rootId = rootSearch.files!.first.id!;

      // Find month folder
      final monthSearch = await driveApi.files.list(
        q: "name = '$monthFolder' and '$rootId' in parents and mimeType = 'application/vnd.google-apps.folder' and trashed = false",
        spaces: 'drive',
        $fields: 'files(id, webViewLink)',
      );
      if (monthSearch.files == null || monthSearch.files!.isEmpty) return null;

      final folder = monthSearch.files!.first;
      return folder.webViewLink ??
          'https://drive.google.com/drive/folders/${folder.id}';
    } finally {
      client.close();
    }
  }
}

