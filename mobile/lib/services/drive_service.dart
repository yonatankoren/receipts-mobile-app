/// Google Drive service.
/// Handles uploading receipt images to organized folders by month and category.
/// Folder structure: <root>/YYYY-MM/category/<merchant> <MM-YYYY>.jpg
///
/// The root folder ID comes from StorageConfigService (set during onboarding).
/// Subfolders are created lazily — only when a receipt needs them.
/// Idempotency: checks if file already exists by name before uploading.

import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:googleapis/drive/v3.dart' as drive;
import 'auth_service.dart';
import 'storage_config_service.dart';

class DriveService {
  static final DriveService instance = DriveService._();
  DriveService._();

  /// Escape a value for use inside single-quoted Drive API query strings.
  static String escQ(String v) =>
      v.replaceAll(r'\', r'\\').replaceAll("'", r"\'");

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
    required String displayName, // e.g. "רמי לוי 03/2025"
    String? pdfPath, // if set, upload the PDF instead of the image
  }) async {
    final client = await AuthService.instance.getAuthenticatedClient();
    if (client == null) {
      throw Exception('Not authenticated — cannot upload to Drive');
    }

    // Get the root folder ID from StorageConfigService
    final rootFolderId = StorageConfigService.instance.receiptsRootFolderId;
    if (rootFolderId == null || rootFolderId.isEmpty) {
      throw Exception('Root folder not configured — complete onboarding first');
    }

    final isPdf = pdfPath != null && File(pdfPath).existsSync();
    final uploadPath = isPdf ? pdfPath : localPath;
    final ext = isPdf ? 'pdf' : 'jpg';
    final mimeType = isPdf ? 'application/pdf' : 'image/jpeg';

    try {
      final driveApi = drive.DriveApi(client);
      final shortId = receiptId.substring(0, 4);
      final fileName = '$displayName ($shortId).$ext';

      // 1. Ensure month subfolder exists under the root (created lazily)
      final monthFolderId = await _ensureFolder(
        driveApi,
        monthFolder,
        rootFolderId,
      );

      // 2. Ensure category subfolder inside month (created lazily)
      final categoryFolderId = await _ensureFolder(
        driveApi,
        category,
        monthFolderId,
      );

      // 3. Check if file already exists (idempotency)
      final existing = await driveApi.files.list(
        q: "name = '${escQ(fileName)}' and '$categoryFolderId' in parents and trashed = false",
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

      // 4. Upload the file into the category subfolder
      final localFile = File(uploadPath);
      if (!await localFile.exists()) {
        throw Exception('Local file not found: $uploadPath');
      }

      final media = drive.Media(localFile.openRead(), await localFile.length());
      final driveFile = drive.File()
        ..name = fileName
        ..parents = [categoryFolderId]
        ..mimeType = mimeType;

      final uploaded = await driveApi.files.create(
        driveFile,
        uploadMedia: media,
        $fields: 'id, webViewLink',
      );

      debugPrint('Drive: uploaded ${uploaded.id} ($ext) → $monthFolder/$category/');
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
    final search = await api.files.list(
      q: "name = '${escQ(folderName)}' and '$parentId' in parents and mimeType = 'application/vnd.google-apps.folder' and trashed = false",
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

    final rootFolderId = StorageConfigService.instance.receiptsRootFolderId;
    if (rootFolderId == null || rootFolderId.isEmpty) return null;

    try {
      final driveApi = drive.DriveApi(client);

      // Find month folder directly under the stored root folder ID
      final monthSearch = await driveApi.files.list(
        q: "name = '${escQ(monthFolder)}' and '$rootFolderId' in parents and mimeType = 'application/vnd.google-apps.folder' and trashed = false",
        spaces: 'drive',
        $fields: 'files(id, webViewLink)',
      );
      if (monthSearch.files == null || monthSearch.files!.isEmpty) return null;

      final folder = monthSearch.files!.first;
      final email = StorageConfigService.instance.accountEmail ??
          AuthService.instance.currentUser?.email;
      final authParam = (email != null && email.isNotEmpty) ? '?authuser=$email' : '';
      return (folder.webViewLink ??
          'https://drive.google.com/drive/folders/${folder.id}') + authParam;
    } finally {
      client.close();
    }
  }

  /// Delete a file from Google Drive by its file ID.
  /// Idempotent: succeeds silently if the file is already gone.
  Future<void> deleteFile(String fileId) async {
    final client = await AuthService.instance.getAuthenticatedClient();
    if (client == null) {
      throw Exception('Not authenticated — cannot delete from Drive');
    }

    try {
      final driveApi = drive.DriveApi(client);
      await driveApi.files.delete(fileId);
      debugPrint('Drive: deleted file $fileId');
    } on drive.DetailedApiRequestError catch (e) {
      if (e.status == 404) {
        // File already gone — idempotent success
        debugPrint('Drive: file $fileId not found (already deleted)');
      } else {
        rethrow;
      }
    } finally {
      client.close();
    }
  }

  /// Delete a file and remove any parent folders that become empty.
  /// Walks up the folder chain (category → month) and deletes each empty
  /// folder, but never deletes the root expenses folder.
  /// Idempotent: succeeds silently if the file is already gone.
  Future<void> deleteFileAndCleanupFolders(String fileId) async {
    final client = await AuthService.instance.getAuthenticatedClient();
    if (client == null) {
      throw Exception('Not authenticated — cannot delete from Drive');
    }

    final rootFolderId = StorageConfigService.instance.receiptsRootFolderId;

    try {
      final driveApi = drive.DriveApi(client);

      // Resolve the file's parent (category folder) before deleting it.
      String? categoryFolderId;
      try {
        final file = await driveApi.files.get(
          fileId,
          $fields: 'parents',
        ) as drive.File;
        categoryFolderId = file.parents?.firstOrNull;
      } on drive.DetailedApiRequestError catch (e) {
        if (e.status == 404) {
          debugPrint('Drive: file $fileId already gone — nothing to clean up');
          return;
        }
        rethrow;
      }

      // Delete the file itself.
      try {
        await driveApi.files.delete(fileId);
        debugPrint('Drive: deleted file $fileId');
      } on drive.DetailedApiRequestError catch (e) {
        if (e.status == 404) {
          debugPrint('Drive: file $fileId not found (already deleted)');
        } else {
          rethrow;
        }
      }

      // Walk up and remove empty folders (category, then month).
      if (categoryFolderId != null) {
        await _deleteFolderIfEmpty(driveApi, categoryFolderId,
            protectId: rootFolderId);
      }
    } finally {
      client.close();
    }
  }

  /// Delete [folderId] if it contains no children. When deleted, recursively
  /// check its parent as well. [protectId] is never deleted (the root folder).
  Future<void> _deleteFolderIfEmpty(
    drive.DriveApi api,
    String folderId, {
    String? protectId,
  }) async {
    if (folderId == protectId) return;

    final children = await api.files.list(
      q: "'$folderId' in parents and trashed = false",
      spaces: 'drive',
      $fields: 'files(id)',
      pageSize: 1,
    );

    if (children.files != null && children.files!.isNotEmpty) {
      return;
    }

    // Grab the folder's own parent before deleting so we can check it next.
    String? parentId;
    try {
      final folder =
          await api.files.get(folderId, $fields: 'parents') as drive.File;
      parentId = folder.parents?.firstOrNull;
    } catch (e) {
      debugPrint('Drive: could not resolve parent of folder $folderId: $e');
    }

    try {
      await api.files.delete(folderId);
      debugPrint('Drive: deleted empty folder $folderId');
    } on drive.DetailedApiRequestError catch (e) {
      if (e.status == 404) {
        debugPrint('Drive: folder $folderId already gone');
      } else {
        rethrow;
      }
    }

    if (parentId != null) {
      await _deleteFolderIfEmpty(api, parentId, protectId: protectId);
    }
  }

  /// Get a direct web link for the root receipts folder.
  /// Appends ?authuser=EMAIL so the browser opens with the correct Google account.
  Future<String?> getRootFolderLink() async {
    final rootFolderId = StorageConfigService.instance.receiptsRootFolderId;
    if (rootFolderId == null || rootFolderId.isEmpty) return null;
    final email = StorageConfigService.instance.accountEmail ??
        AuthService.instance.currentUser?.email;
    final authParam = (email != null && email.isNotEmpty) ? '?authuser=$email' : '';
    return 'https://drive.google.com/drive/folders/$rootFolderId$authParam';
  }
}
