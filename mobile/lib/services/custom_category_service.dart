/// Custom category service.
///
/// Persists user-defined categories in SharedPreferences and provides
/// a merged, sorted list alongside the built-in ones.  Also handles
/// renaming a category everywhere: SharedPreferences, SQLite, Drive
/// folder names, and Sheets cell values.

import 'package:flutter/material.dart';
import 'package:googleapis/drive/v3.dart' as drive;
import 'package:googleapis/sheets/v4.dart' as sheets;
import 'package:shared_preferences/shared_preferences.dart';
import '../db/database_helper.dart';
import '../utils/constants.dart';
import 'auth_service.dart';
import 'sheets_service.dart';
import 'storage_config_service.dart';

class CustomCategoryService {
  static final CustomCategoryService instance = CustomCategoryService._();
  CustomCategoryService._();

  static const _prefsKey = 'custom_categories';
  static const int maxNameLength = 30;

  List<String> _custom = [];

  /// Built-in category → colour (same map that was in statistics_screen).
  static const Map<String, Color> builtInColors = {
    'אחר': Color(0xFFB0BEC5),
    'ביגוד': Color(0xFFF48FB1),
    'ביטוחים': Color(0xFF80CBC4),
    'בילויים': Color(0xFFFFAB91),
    'בית': Color(0xFFE6EE9C),
    'בריאות': Color(0xFFEF9A9A),
    'הדרכה והתפתחות': Color(0xFFB39DDB),
    'הוצאות משרדיות': Color(0xFF90CAF9),
    'חיות מחמד': Color(0xFFA1887F),
    'חשבונות': Color(0xFFA5D6A7),
    'טיולים': Color(0xFF80DEEA),
    'טיפוח': Color(0xFFF8BBD0),
    'טכנולוגיה': Color(0xFF9FA8DA),
    'ילדים': Color(0xFF4DD0E1),
    'מזון': Color(0xFFFFCC80),
    'פנאי': Color(0xFFCE93D8),
    'פרסום': Color(0xFFFFE082),
    'קניות': Color(0xFF81D4FA),
    'רכב ודלק': Color(0xFFC5E1A5),
    'שכירות': Color(0xFFBCAAA4),
    'תחבורה ציבורית': Color(0xFFB2EBF2),
    'תחזוקה': Color(0xFFD7CCC8),
    'תקשורת': Color(0xFFDCE775),
  };

  /// Extra pastel pool for custom categories (assigned by list index).
  static const List<Color> _extraColors = [
    Color(0xFFFF8A65),
    Color(0xFFA1887F),
    Color(0xFF4DD0E1),
    Color(0xFFAED581),
    Color(0xFF7986CB),
    Color(0xFFE57373),
    Color(0xFFFFD54F),
    Color(0xFF4DB6AC),
    Color(0xFFBA68C8),
    Color(0xFFF06292),
  ];

  static const Color fallbackColor = Color(0xFFE0E0E0);

  // ──────────────── public getters ────────────────

  List<String> get customCategories => List.unmodifiable(_custom);

  /// Built-in + custom, sorted alphabetically.
  List<String> get allCategories {
    final merged = {...AppConstants.categories, ..._custom}.toList()..sort();
    return merged;
  }

  // ──────────────── init ────────────────

  Future<void> init() async {
    final prefs = await SharedPreferences.getInstance();
    _custom = prefs.getStringList(_prefsKey) ?? [];
  }

  // ──────────────── colour ────────────────

  Color colorFor(String category) {
    final builtin = builtInColors[category];
    if (builtin != null) return builtin;
    final idx = _custom.indexOf(category);
    if (idx >= 0) return _extraColors[idx % _extraColors.length];
    return fallbackColor;
  }

  // ──────────────── add ────────────────

  /// Validate and persist a new custom category.
  /// Throws [ArgumentError] on invalid input.
  Future<void> addCategory(String name) async {
    final trimmed = name.trim();
    _validate(trimmed);
    _custom.add(trimmed);
    await _save();
  }

  // ──────────────── rename ────────────────

  /// Rename a custom category everywhere:
  ///   1. SharedPreferences list
  ///   2. SQLite receipts
  ///   3. Drive category folders (best-effort)
  ///   4. Sheets expenses + totals tabs (best-effort)
  ///
  /// Throws [ArgumentError] if newName is invalid.
  Future<void> renameCategory(String oldName, String newName) async {
    final trimmed = newName.trim();
    if (trimmed == oldName) return;
    _validate(trimmed);

    // 1. Update local list
    final idx = _custom.indexOf(oldName);
    if (idx == -1) throw ArgumentError('Category "$oldName" not found');
    _custom[idx] = trimmed;
    await _save();

    // 2. SQLite
    await DatabaseHelper.instance.renameCategory(oldName, trimmed);

    // 3. Drive folders (best-effort)
    try {
      await _renameDriveFolders(oldName, trimmed);
    } catch (e) {
      debugPrint('CustomCategoryService: Drive rename failed: $e');
    }

    // 4. Sheets cells (best-effort)
    try {
      await _renameSheetsCategory(oldName, trimmed);
    } catch (e) {
      debugPrint('CustomCategoryService: Sheets rename failed: $e');
    }
  }

  // ──────────────── validation ────────────────

  void _validate(String name) {
    if (name.isEmpty) throw ArgumentError('שם קטגוריה לא יכול להיות ריק');
    if (name.length > maxNameLength) {
      throw ArgumentError('שם קטגוריה ארוך מדי (עד $maxNameLength תווים)');
    }
    if (name == 'ללא') throw ArgumentError('שם שמור');
    if (allCategories.contains(name)) {
      throw ArgumentError('קטגוריה "$name" כבר קיימת');
    }
  }

  // ──────────────── persistence ────────────────

  Future<void> _save() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_prefsKey, _custom);
  }

  // ──────────────── Drive rename ────────────────

  Future<void> _renameDriveFolders(String oldName, String newName) async {
    final client = await AuthService.instance.getAuthenticatedClient();
    if (client == null) return;

    final rootFolderId = StorageConfigService.instance.receiptsRootFolderId;
    if (rootFolderId == null || rootFolderId.isEmpty) return;

    try {
      final api = drive.DriveApi(client);

      // List all month folders under root
      final monthFolders = await api.files.list(
        q: "'$rootFolderId' in parents "
            "and mimeType = 'application/vnd.google-apps.folder' "
            "and trashed = false",
        spaces: 'drive',
        $fields: 'files(id, name)',
      );
      if (monthFolders.files == null) return;

      for (final mf in monthFolders.files!) {
        final catSearch = await api.files.list(
          q: "name = '$oldName' and '${mf.id}' in parents "
              "and mimeType = 'application/vnd.google-apps.folder' "
              "and trashed = false",
          spaces: 'drive',
          $fields: 'files(id)',
        );
        if (catSearch.files != null && catSearch.files!.isNotEmpty) {
          await api.files.update(
            drive.File()..name = newName,
            catSearch.files!.first.id!,
          );
          debugPrint('Drive: renamed "${mf.name}/$oldName" → "$newName"');
        }
      }
    } finally {
      client.close();
    }
  }

  // ──────────────── Sheets rename ────────────────

  Future<void> _renameSheetsCategory(String oldName, String newName) async {
    final spreadsheetId = SheetsService.instance.getSpreadsheetId();
    if (spreadsheetId == null || spreadsheetId.isEmpty) return;

    final client = await AuthService.instance.getAuthenticatedClient();
    if (client == null) return;

    try {
      final api = sheets.SheetsApi(client);
      final spreadsheet = await api.spreadsheets.get(spreadsheetId);

      for (final sheet in spreadsheet.sheets ?? <sheets.Sheet>[]) {
        final title = sheet.properties?.title ?? '';

        if (title.startsWith(AppConstants.expensesTabPrefix)) {
          // Column E = קטגוריה (index 4, letter E)
          await _replaceInColumn(
              api, spreadsheetId, title, 'E', oldName, newName);
        } else if (title.startsWith(AppConstants.totalsTabPrefix)) {
          await _renameTotalsRow(
              api, spreadsheetId, title, oldName, newName);
        }
      }
    } finally {
      client.close();
    }
  }

  /// Replace all occurrences of [oldVal] with [newVal] in a single column.
  Future<void> _replaceInColumn(
    sheets.SheetsApi api,
    String spreadsheetId,
    String tabName,
    String column,
    String oldVal,
    String newVal,
  ) async {
    final resp = await api.spreadsheets.values.get(
      spreadsheetId,
      '$tabName!$column:$column',
    );
    if (resp.values == null) return;

    for (int i = 0; i < resp.values!.length; i++) {
      final row = resp.values![i];
      if (row.isNotEmpty && row[0].toString() == oldVal) {
        final cell = '$tabName!$column${i + 1}';
        await api.spreadsheets.values.update(
          sheets.ValueRange()
            ..values = [
              [newVal]
            ],
          spreadsheetId,
          cell,
          valueInputOption: 'RAW',
        );
      }
    }
  }

  /// Rename a category row in a totals tab: update label (A) and SUMIF (B).
  Future<void> _renameTotalsRow(
    sheets.SheetsApi api,
    String spreadsheetId,
    String totalsTab,
    String oldName,
    String newName,
  ) async {
    final resp = await api.spreadsheets.values.get(
      spreadsheetId,
      '$totalsTab!A:B',
      valueRenderOption: 'FORMULA',
    );
    if (resp.values == null) return;

    for (int i = 0; i < resp.values!.length; i++) {
      final row = resp.values![i];
      if (row.isNotEmpty && row[0].toString() == oldName) {
        final rowNum = i + 1;
        // Derive the expenses tab name from the totals tab name
        final year = totalsTab.split(' ').last;
        final expensesTab = '${AppConstants.expensesTabPrefix} $year';
        final formula =
            "=SUMIF('$expensesTab'!E:E,\"$newName\",'$expensesTab'!C:C)";

        await api.spreadsheets.values.update(
          sheets.ValueRange()
            ..values = [
              [newName, formula]
            ],
          spreadsheetId,
          '$totalsTab!A$rowNum:B$rowNum',
          valueInputOption: 'USER_ENTERED',
        );
        debugPrint('Sheets: renamed "$oldName" → "$newName" in "$totalsTab"');
        break;
      }
    }
  }
}
