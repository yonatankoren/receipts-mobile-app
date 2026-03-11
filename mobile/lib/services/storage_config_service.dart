/// Centralized storage configuration service.
///
/// Single source of truth for Drive folder ID, Spreadsheet ID, and related
/// metadata. Backed by SharedPreferences. All other services read from here
/// instead of managing their own prefs keys.

import 'package:flutter/foundation.dart';
import 'package:googleapis/drive/v3.dart' as drive;
import 'package:googleapis/sheets/v4.dart' as sheets;
import 'package:shared_preferences/shared_preferences.dart';
import 'auth_service.dart';

class StorageConfigService extends ChangeNotifier {
  static final StorageConfigService instance = StorageConfigService._();
  StorageConfigService._();

  // SharedPreferences keys
  static const String _keyFolderId = 'storage_receipts_root_folder_id';
  static const String _keyFolderName = 'storage_receipts_root_folder_name';
  static const String _keySpreadsheetId = 'storage_spreadsheet_id';
  static const String _keySpreadsheetName = 'storage_spreadsheet_name';
  static const String _keyParentFolderId = 'storage_parent_folder_id';
  static const String _keyAccountEmail = 'storage_account_email';

  // Cached values (loaded on init)
  String? _folderId;
  String? _folderName;
  String? _spreadsheetId;
  String? _spreadsheetName;
  String? _parentFolderId;
  String? _accountEmail;

  // --- Getters ---

  String? get receiptsRootFolderId => _folderId;
  String? get receiptsRootFolderName => _folderName;
  String? get spreadsheetId => _spreadsheetId;
  String? get spreadsheetName => _spreadsheetName;
  String? get parentFolderId => _parentFolderId;
  String? get accountEmail => _accountEmail;

  /// True when both folder ID and spreadsheet ID are set.
  bool get isFullyConfigured =>
      _folderId != null &&
      _folderId!.isNotEmpty &&
      _spreadsheetId != null &&
      _spreadsheetId!.isNotEmpty;

  // --- Init ---

  /// Load cached values from SharedPreferences.
  Future<void> init() async {
    final prefs = await SharedPreferences.getInstance();
    _folderId = prefs.getString(_keyFolderId);
    _folderName = prefs.getString(_keyFolderName);
    _spreadsheetId = prefs.getString(_keySpreadsheetId);
    _spreadsheetName = prefs.getString(_keySpreadsheetName);
    _parentFolderId = prefs.getString(_keyParentFolderId);
    _accountEmail = prefs.getString(_keyAccountEmail);

    // Migrate from legacy SheetsService key if present
    final legacySheetId = prefs.getString('sheets_spreadsheet_id');
    if (legacySheetId != null && legacySheetId.isNotEmpty && _spreadsheetId == null) {
      _spreadsheetId = legacySheetId;
      await prefs.setString(_keySpreadsheetId, legacySheetId);
      await prefs.remove('sheets_spreadsheet_id');
      debugPrint('StorageConfig: migrated legacy spreadsheet ID');
    }

    debugPrint('StorageConfig: init — folder=$_folderId, sheet=$_spreadsheetId');
    notifyListeners();
  }

  // --- Setters ---

  Future<void> setFolderConfig({
    required String folderId,
    required String folderName,
    String? parentFolderId,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    _folderId = folderId;
    _folderName = folderName;
    _parentFolderId = parentFolderId;

    await prefs.setString(_keyFolderId, folderId);
    await prefs.setString(_keyFolderName, folderName);
    if (parentFolderId != null) {
      await prefs.setString(_keyParentFolderId, parentFolderId);
    } else {
      await prefs.remove(_keyParentFolderId);
    }
    notifyListeners();
  }

  Future<void> setSpreadsheetConfig({
    required String spreadsheetId,
    required String spreadsheetName,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    _spreadsheetId = spreadsheetId;
    _spreadsheetName = spreadsheetName;

    await prefs.setString(_keySpreadsheetId, spreadsheetId);
    await prefs.setString(_keySpreadsheetName, spreadsheetName);
    notifyListeners();
  }

  Future<void> setAccountEmail(String email) async {
    final prefs = await SharedPreferences.getInstance();
    _accountEmail = email;
    await prefs.setString(_keyAccountEmail, email);
    notifyListeners();
  }

  /// Clear all stored config (e.g. on sign-out or relink).
  Future<void> clear() async {
    final prefs = await SharedPreferences.getInstance();
    for (final key in [
      _keyFolderId,
      _keyFolderName,
      _keySpreadsheetId,
      _keySpreadsheetName,
      _keyParentFolderId,
      _keyAccountEmail,
    ]) {
      await prefs.remove(key);
    }
    _folderId = null;
    _folderName = null;
    _spreadsheetId = null;
    _spreadsheetName = null;
    _parentFolderId = null;
    _accountEmail = null;
    notifyListeners();
  }

  // --- Validation ---

  /// Check that the stored folder and spreadsheet are still accessible.
  /// Returns a [ValidationResult] indicating which (if any) are inaccessible.
  Future<ValidationResult> validateAccess() async {
    if (!isFullyConfigured) {
      return ValidationResult(folderOk: false, sheetOk: false);
    }

    final client = await AuthService.instance.getAuthenticatedClient();
    if (client == null) {
      return ValidationResult(folderOk: false, sheetOk: false);
    }

    bool folderOk = false;
    bool sheetOk = false;

    try {
      // Check Drive folder and Spreadsheet in parallel — they are independent
      final results = await Future.wait([
        // [0] Drive folder check
        () async {
          try {
            final driveApi = drive.DriveApi(client);
            final folder = await driveApi.files.get(
              _folderId!,
              $fields: 'id,trashed',
            );
            return (folder is drive.File && folder.trashed != true);
          } catch (e) {
            debugPrint('StorageConfig: folder validation failed: $e');
            return false;
          }
        }(),
        // [1] Spreadsheet check
        () async {
          try {
            final sheetsApi = sheets.SheetsApi(client);
            await sheetsApi.spreadsheets.get(
              _spreadsheetId!,
              $fields: 'spreadsheetId',
            );
            return true;
          } catch (e) {
            debugPrint('StorageConfig: spreadsheet validation failed: $e');
            return false;
          }
        }(),
      ]);

      folderOk = results[0];
      sheetOk = results[1];
    } finally {
      client.close();
    }

    return ValidationResult(folderOk: folderOk, sheetOk: sheetOk);
  }
}

class ValidationResult {
  final bool folderOk;
  final bool sheetOk;

  const ValidationResult({required this.folderOk, required this.sheetOk});

  bool get allOk => folderOk && sheetOk;
}


