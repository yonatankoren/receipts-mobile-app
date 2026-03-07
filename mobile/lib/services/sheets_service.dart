/// Google Sheets service.
///
/// Writes receipt rows to a configured spreadsheet with year-based tabs:
///   - "הוצאות YYYY" — per-year expenses tab
///   - "סיכום YYYY"  — per-year totals tab with SUMIF formulas
///
/// Each year tab has:
///   - Sorted insertion by month (chronological order)
///   - Month-based color coding (12 pastel colors)
///   - Borders and formatting for a clean look
///   - Idempotency: checks drive_file_link (column F) before inserting
///
/// Spreadsheet ID is read from StorageConfigService (set during onboarding).

import 'package:flutter/foundation.dart';
import 'package:googleapis/sheets/v4.dart' as sheets;
import 'auth_service.dart';
import 'storage_config_service.dart';
import '../models/receipt.dart';
import '../utils/constants.dart';

class SheetsService {
  static final SheetsService instance = SheetsService._();
  SheetsService._();

  // ────────────────────────── Settings ──────────────────────────

  /// Get the spreadsheet ID from StorageConfigService.
  String? getSpreadsheetId() {
    return StorageConfigService.instance.spreadsheetId;
  }

  /// Get a direct web link for the spreadsheet.
  /// Appends ?authuser=EMAIL so the browser opens with the correct Google account.
  String? getSpreadsheetLink() {
    final id = getSpreadsheetId();
    if (id == null || id.isEmpty) return null;
    final email = StorageConfigService.instance.accountEmail ??
        AuthService.instance.currentUser?.email;
    final authParam = (email != null && email.isNotEmpty) ? '?authuser=$email' : '';
    return 'https://docs.google.com/spreadsheets/d/$id$authParam';
  }

  // ────────────────── Tab naming helpers ──────────────────────

  /// Returns "הוצאות YYYY" for the given year.
  String _expensesTabName(int year) =>
      '${AppConstants.expensesTabPrefix} $year';

  /// Returns "סיכום YYYY" for the given year.
  String _totalsTabName(int year) =>
      '${AppConstants.totalsTabPrefix} $year';

  // ────────────────────── Main entry point ──────────────────────

  /// Insert a receipt row into the correct year tab at the correct sorted
  /// position, apply month color, borders, and ensure the totals tab exists.
  Future<void> appendReceiptRow(Receipt receipt) async {
    final spreadsheetId = getSpreadsheetId();
    if (spreadsheetId == null || spreadsheetId.isEmpty) {
      throw Exception('Spreadsheet ID not configured. Complete onboarding first.');
    }

    final client = await AuthService.instance.getAuthenticatedClient();
    if (client == null) {
      throw Exception('Not authenticated — cannot write to Sheets');
    }

    try {
      final api = sheets.SheetsApi(client);
      final year = receipt.receiptYear;
      final expensesTab = _expensesTabName(year);
      final totalsTab = _totalsTabName(year);

      // 1. Ensure the year's expenses tab exists with headers + formatting
      await _ensureExpensesTab(api, spreadsheetId, expensesTab);

      // 2. Ensure the year's totals tab exists with SUMIF formulas
      await _ensureTotalsTab(api, spreadsheetId, expensesTab, totalsTab);

      // 2b. Ensure this receipt's category has a row in the totals tab
      final receiptCategory = receipt.category;
      if (receiptCategory != null && receiptCategory.isNotEmpty) {
        await _ensureCategoryInTotals(
          api, spreadsheetId, totalsTab, expensesTab, receiptCategory,
        );
      }

      // 3. Idempotency: check drive link in column F
      if (receipt.driveFileLink != null && receipt.driveFileLink!.isNotEmpty) {
        final dup = await _isDriveLinkInSheet(
          api, spreadsheetId, expensesTab, receipt.driveFileLink!,
        );
        if (dup) {
          debugPrint('Sheets: drive link already exists in $expensesTab, skipping');
          return;
        }
      }

      // 4. Read existing month column (A) to find insertion point
      final insertRow = await _findInsertionRow(
        api, spreadsheetId, expensesTab, receipt.monthSortKey,
      );

      // 5. Get the tab's numeric ID (needed for batchUpdate)
      final sheetId = await _getSheetId(api, spreadsheetId, expensesTab);

      // 6. Insert a blank row at the position
      await _insertRow(api, spreadsheetId, sheetId, insertRow);

      // 7. Write the data into the new row
      final row = receipt.toSheetsRow();
      final valueRange = sheets.ValueRange()
        ..values = [row.map((v) => v.toString()).toList()];

      await api.spreadsheets.values.update(
        valueRange,
        spreadsheetId,
        '$expensesTab!A$insertRow:F$insertRow',
        valueInputOption: 'USER_ENTERED',
      );

      // 8. Apply month color + borders to the new row
      final month = _monthFromSortKey(receipt.monthSortKey);
      await _formatRow(api, spreadsheetId, sheetId, insertRow, month);

      debugPrint(
        'Sheets: inserted receipt at row $insertRow in "$expensesTab" '
        '(month ${receipt.sheetsMonth})',
      );
    } finally {
      client.close();
    }
  }

  // ──────────────── Year expenses tab setup ────────────────────

  /// Ensure the expenses tab for a given year exists with headers.
  /// If the tab doesn't exist, create it and write headers.
  Future<void> _ensureExpensesTab(
    sheets.SheetsApi api,
    String spreadsheetId,
    String tabName,
  ) async {
    final spreadsheet = await api.spreadsheets.get(spreadsheetId);
    final exists = spreadsheet.sheets?.any(
      (s) => s.properties?.title == tabName,
    ) ?? false;

    if (exists) {
      // Tab exists — check if headers are set
      try {
        final resp = await api.spreadsheets.values.get(
          spreadsheetId,
          '$tabName!A1:F1',
        );
        if (resp.values == null || resp.values!.isEmpty) {
          await _writeHeaders(api, spreadsheetId, tabName);
        }
      } catch (e) {
        debugPrint('Sheets: header check error in $tabName: $e');
        try {
          await _writeHeaders(api, spreadsheetId, tabName);
        } catch (_) {}
      }
      return;
    }

    // Create new tab
    try {
      await api.spreadsheets.batchUpdate(
        sheets.BatchUpdateSpreadsheetRequest(requests: [
          sheets.Request(
            addSheet: sheets.AddSheetRequest(
              properties: sheets.SheetProperties(title: tabName),
            ),
          ),
        ]),
        spreadsheetId,
      );
      debugPrint('Sheets: created tab "$tabName"');
    } catch (e) {
      debugPrint('Sheets: tab "$tabName" may already exist: $e');
    }

    // Write headers + formatting
    await _writeHeaders(api, spreadsheetId, tabName);
  }

  Future<void> _writeHeaders(
    sheets.SheetsApi api,
    String spreadsheetId,
    String tabName,
  ) async {
    final vr = sheets.ValueRange()
      ..values = [AppConstants.sheetsHeaders];
    await api.spreadsheets.values.update(
      vr,
      spreadsheetId,
      '$tabName!A1:F1',
      valueInputOption: 'RAW',
    );

    // Format the header row: bold + dark background
    final sheetId = await _getSheetId(api, spreadsheetId, tabName);
    await api.spreadsheets.batchUpdate(
      sheets.BatchUpdateSpreadsheetRequest(requests: [
        // Bold header text
        sheets.Request(
          repeatCell: sheets.RepeatCellRequest(
            range: sheets.GridRange(
              sheetId: sheetId,
              startRowIndex: 0,
              endRowIndex: 1,
              startColumnIndex: 0,
              endColumnIndex: AppConstants.sheetsColumnCount,
            ),
            cell: sheets.CellData(
              userEnteredFormat: sheets.CellFormat(
                textFormat: sheets.TextFormat(
                  bold: true,
                  fontSize: 11,
                  foregroundColor: sheets.Color(red: 1, green: 1, blue: 1, alpha: 1),
                ),
                backgroundColor: sheets.Color(
                  red: 0.2, green: 0.2, blue: 0.2, alpha: 1.0,
                ),
                horizontalAlignment: 'CENTER',
                verticalAlignment: 'MIDDLE',
              ),
            ),
            fields: 'userEnteredFormat(textFormat,backgroundColor,horizontalAlignment,verticalAlignment)',
          ),
        ),
        // Header borders
        sheets.Request(
          updateBorders: sheets.UpdateBordersRequest(
            range: sheets.GridRange(
              sheetId: sheetId,
              startRowIndex: 0,
              endRowIndex: 1,
              startColumnIndex: 0,
              endColumnIndex: AppConstants.sheetsColumnCount,
            ),
            top: _solidBorder(),
            bottom: _thickBorder(),
            left: _solidBorder(),
            right: _solidBorder(),
            innerVertical: _solidBorder(),
          ),
        ),
        // Set column widths
        ..._columnWidthRequests(sheetId),
        // Freeze header row
        sheets.Request(
          updateSheetProperties: sheets.UpdateSheetPropertiesRequest(
            properties: sheets.SheetProperties(
              sheetId: sheetId,
              gridProperties: sheets.GridProperties(frozenRowCount: 1),
            ),
            fields: 'gridProperties.frozenRowCount',
          ),
        ),
      ]),
      spreadsheetId,
    );

    debugPrint('Sheets: wrote + formatted headers for "$tabName"');
  }

  // ─────────────────── Totals tab (סיכום YYYY) ───────────────────

  /// Ensure the per-year totals tab exists.
  /// Creates two side-by-side tables:
  ///   - Columns A-B: sums per category (starts empty — rows added dynamically)
  ///   - Columns D-E: sums per month (column C is a gap)
  ///
  /// Category rows are added on-demand by [_ensureCategoryInTotals] when
  /// a receipt with a new category is first appended.
  Future<void> _ensureTotalsTab(
    sheets.SheetsApi api,
    String spreadsheetId,
    String expensesTabName,
    String totalsTabName,
  ) async {
    // Check if the tab already exists
    final spreadsheet = await api.spreadsheets.get(spreadsheetId);
    final exists = spreadsheet.sheets?.any(
      (s) => s.properties?.title == totalsTabName,
    ) ?? false;

    if (exists) return; // Already set up

    // Create the tab
    try {
      await api.spreadsheets.batchUpdate(
        sheets.BatchUpdateSpreadsheetRequest(requests: [
          sheets.Request(
            addSheet: sheets.AddSheetRequest(
              properties: sheets.SheetProperties(title: totalsTabName),
            ),
          ),
        ]),
        spreadsheetId,
      );
    } catch (e) {
      debugPrint('Sheets: totals tab "$totalsTabName" might already exist: $e');
      return;
    }

    // Get the new sheet's ID
    final totalsSheetId = await _getSheetId(api, spreadsheetId, totalsTabName);

    // Extract the year from expensesTabName (e.g. "הוצאות 2025" → "2025")
    final year = expensesTabName.split(' ').last;

    // ── Table 1: Category sums (columns A-B) — header + total only ──
    // Category rows will be added dynamically by _ensureCategoryInTotals.
    final catRows = <List<String>>[
      ['קטגוריה', 'סכום'],       // Header (row 1)
      ['סה"כ', '=SUM(B3:B3)'],  // Total  (row 2) — expands as categories are added
    ];

    final catVr = sheets.ValueRange()..values = catRows;
    await api.spreadsheets.values.update(
      catVr,
      spreadsheetId,
      '$totalsTabName!A1:B${catRows.length}',
      valueInputOption: 'USER_ENTERED',
    );

    // ── Table 2: Monthly sums (columns D-E) ──
    final monthNames = AppConstants.hebrewMonthNames;
    final monthRows = <List<String>>[
      ['חודש', 'סכום'], // Header (row 1)
      ...List.generate(12, (i) {
        final mm = (i + 1).toString().padLeft(2, '0');
        return [
          monthNames[i],
          "=SUMIF('$expensesTabName'!A:A,\"$mm/$year\",'$expensesTabName'!C:C)",
        ];
      }),
      ['סה"כ', '=SUM(E2:E13)'],
    ];

    final monthVr = sheets.ValueRange()..values = monthRows;
    await api.spreadsheets.values.update(
      monthVr,
      spreadsheetId,
      '$totalsTabName!D1:E${monthRows.length}',
      valueInputOption: 'USER_ENTERED',
    );

    // ── Formatting ──
    final monthTotalRow = monthRows.length - 1; // 0-indexed (= 13)

    await api.spreadsheets.batchUpdate(
      sheets.BatchUpdateSpreadsheetRequest(requests: [
        // ═══ Category table (A-B) initial formatting ═══

        // Bold header row (A-B)
        sheets.Request(
          repeatCell: sheets.RepeatCellRequest(
            range: sheets.GridRange(
              sheetId: totalsSheetId,
              startRowIndex: 0,
              endRowIndex: 1,
              startColumnIndex: 0,
              endColumnIndex: 2,
            ),
            cell: sheets.CellData(
              userEnteredFormat: sheets.CellFormat(
                textFormat: sheets.TextFormat(
                  bold: true,
                  fontSize: 11,
                  foregroundColor: sheets.Color(red: 1, green: 1, blue: 1, alpha: 1),
                ),
                backgroundColor: sheets.Color(
                  red: 0.2, green: 0.2, blue: 0.2, alpha: 1.0,
                ),
                horizontalAlignment: 'CENTER',
              ),
            ),
            fields: 'userEnteredFormat(textFormat,backgroundColor,horizontalAlignment)',
          ),
        ),
        // Bold total row (row 2 = index 1)
        sheets.Request(
          repeatCell: sheets.RepeatCellRequest(
            range: sheets.GridRange(
              sheetId: totalsSheetId,
              startRowIndex: 1,
              endRowIndex: 2,
              startColumnIndex: 0,
              endColumnIndex: 2,
            ),
            cell: sheets.CellData(
              userEnteredFormat: sheets.CellFormat(
                textFormat: sheets.TextFormat(bold: true, fontSize: 12),
                backgroundColor: sheets.Color(
                  red: 0.93, green: 0.93, blue: 0.93, alpha: 1.0,
                ),
                numberFormat: sheets.NumberFormat(
                  type: 'NUMBER',
                  pattern: '#,##0.00',
                ),
              ),
            ),
            fields: 'userEnteredFormat(textFormat,backgroundColor,numberFormat)',
          ),
        ),
        // Borders around initial category table (header + total = 2 rows)
        sheets.Request(
          updateBorders: sheets.UpdateBordersRequest(
            range: sheets.GridRange(
              sheetId: totalsSheetId,
              startRowIndex: 0,
              endRowIndex: 2,
              startColumnIndex: 0,
              endColumnIndex: 2,
            ),
            top: _solidBorder(),
            bottom: _solidBorder(),
            left: _solidBorder(),
            right: _solidBorder(),
            innerHorizontal: _thickBorder(),
            innerVertical: _solidBorder(),
          ),
        ),

        // ═══ Monthly table (D-E) formatting ═══

        // Bold header row (D-E)
        sheets.Request(
          repeatCell: sheets.RepeatCellRequest(
            range: sheets.GridRange(
              sheetId: totalsSheetId,
              startRowIndex: 0,
              endRowIndex: 1,
              startColumnIndex: 3,
              endColumnIndex: 5,
            ),
            cell: sheets.CellData(
              userEnteredFormat: sheets.CellFormat(
                textFormat: sheets.TextFormat(
                  bold: true,
                  fontSize: 11,
                  foregroundColor: sheets.Color(red: 1, green: 1, blue: 1, alpha: 1),
                ),
                backgroundColor: sheets.Color(
                  red: 0.2, green: 0.2, blue: 0.2, alpha: 1.0,
                ),
                horizontalAlignment: 'CENTER',
              ),
            ),
            fields: 'userEnteredFormat(textFormat,backgroundColor,horizontalAlignment)',
          ),
        ),
        // Bold monthly total row
        sheets.Request(
          repeatCell: sheets.RepeatCellRequest(
            range: sheets.GridRange(
              sheetId: totalsSheetId,
              startRowIndex: monthTotalRow,
              endRowIndex: monthTotalRow + 1,
              startColumnIndex: 3,
              endColumnIndex: 5,
            ),
            cell: sheets.CellData(
              userEnteredFormat: sheets.CellFormat(
                textFormat: sheets.TextFormat(bold: true, fontSize: 12),
                backgroundColor: sheets.Color(
                  red: 0.93, green: 0.93, blue: 0.93, alpha: 1.0,
                ),
              ),
            ),
            fields: 'userEnteredFormat(textFormat,backgroundColor)',
          ),
        ),
        // Borders around monthly table
        sheets.Request(
          updateBorders: sheets.UpdateBordersRequest(
            range: sheets.GridRange(
              sheetId: totalsSheetId,
              startRowIndex: 0,
              endRowIndex: monthRows.length,
              startColumnIndex: 3,
              endColumnIndex: 5,
            ),
            top: _solidBorder(),
            bottom: _solidBorder(),
            left: _solidBorder(),
            right: _solidBorder(),
            innerHorizontal: _solidBorder(),
            innerVertical: _solidBorder(),
          ),
        ),
        // Thick border above monthly total row
        sheets.Request(
          updateBorders: sheets.UpdateBordersRequest(
            range: sheets.GridRange(
              sheetId: totalsSheetId,
              startRowIndex: monthTotalRow,
              endRowIndex: monthTotalRow + 1,
              startColumnIndex: 3,
              endColumnIndex: 5,
            ),
            top: _thickBorder(),
          ),
        ),
        // Number format for monthly amounts (column E rows 2+)
        sheets.Request(
          repeatCell: sheets.RepeatCellRequest(
            range: sheets.GridRange(
              sheetId: totalsSheetId,
              startRowIndex: 1,
              endRowIndex: monthRows.length,
              startColumnIndex: 4,
              endColumnIndex: 5,
            ),
            cell: sheets.CellData(
              userEnteredFormat: sheets.CellFormat(
                numberFormat: sheets.NumberFormat(
                  type: 'NUMBER',
                  pattern: '#,##0.00',
                ),
              ),
            ),
            fields: 'userEnteredFormat.numberFormat',
          ),
        ),

        // ═══ Shared formatting ═══

        // Column widths: A=160, B=120, C=30(gap), D=100, E=120
        sheets.Request(
          updateDimensionProperties: sheets.UpdateDimensionPropertiesRequest(
            range: sheets.DimensionRange(
              sheetId: totalsSheetId,
              dimension: 'COLUMNS',
              startIndex: 0,
              endIndex: 1,
            ),
            properties: sheets.DimensionProperties(pixelSize: 160),
            fields: 'pixelSize',
          ),
        ),
        sheets.Request(
          updateDimensionProperties: sheets.UpdateDimensionPropertiesRequest(
            range: sheets.DimensionRange(
              sheetId: totalsSheetId,
              dimension: 'COLUMNS',
              startIndex: 1,
              endIndex: 2,
            ),
            properties: sheets.DimensionProperties(pixelSize: 120),
            fields: 'pixelSize',
          ),
        ),
        sheets.Request(
          updateDimensionProperties: sheets.UpdateDimensionPropertiesRequest(
            range: sheets.DimensionRange(
              sheetId: totalsSheetId,
              dimension: 'COLUMNS',
              startIndex: 2,
              endIndex: 3,
            ),
            properties: sheets.DimensionProperties(pixelSize: 30),
            fields: 'pixelSize',
          ),
        ),
        sheets.Request(
          updateDimensionProperties: sheets.UpdateDimensionPropertiesRequest(
            range: sheets.DimensionRange(
              sheetId: totalsSheetId,
              dimension: 'COLUMNS',
              startIndex: 3,
              endIndex: 4,
            ),
            properties: sheets.DimensionProperties(pixelSize: 100),
            fields: 'pixelSize',
          ),
        ),
        sheets.Request(
          updateDimensionProperties: sheets.UpdateDimensionPropertiesRequest(
            range: sheets.DimensionRange(
              sheetId: totalsSheetId,
              dimension: 'COLUMNS',
              startIndex: 4,
              endIndex: 5,
            ),
            properties: sheets.DimensionProperties(pixelSize: 120),
            fields: 'pixelSize',
          ),
        ),
        // Freeze header
        sheets.Request(
          updateSheetProperties: sheets.UpdateSheetPropertiesRequest(
            properties: sheets.SheetProperties(
              sheetId: totalsSheetId,
              gridProperties: sheets.GridProperties(frozenRowCount: 1),
            ),
            fields: 'gridProperties.frozenRowCount',
          ),
        ),
      ]),
      spreadsheetId,
    );

    debugPrint('Sheets: created and formatted totals tab "$totalsTabName"');
  }

  /// Ensure a category row exists in the totals tab.
  /// If not, insert it in alphabetical order with a SUMIF formula,
  /// then update the total row formula and apply formatting.
  Future<void> _ensureCategoryInTotals(
    sheets.SheetsApi api,
    String spreadsheetId,
    String totalsTabName,
    String expensesTabName,
    String category,
  ) async {
    if (category.isEmpty) return;

    try {
      // 1. Read column A to find existing rows
      final resp = await api.spreadsheets.values.get(
        spreadsheetId,
        '$totalsTabName!A:A',
      );
      final values = resp.values ?? [];
      if (values.isEmpty) return; // Malformed tab

      // 2. Find the total row and existing categories
      int totalRowIndex = -1; // 0-indexed position in values list
      final existingCategories = <String>[];

      for (int i = 1; i < values.length; i++) {
        // Skip header (row 0)
        final cellVal = values[i].isNotEmpty ? values[i][0].toString() : '';
        if (cellVal.contains('סה"כ') || cellVal.contains("סה\"כ")) {
          totalRowIndex = i;
          break;
        }
        if (cellVal.isNotEmpty) {
          existingCategories.add(cellVal);
        }
      }

      if (totalRowIndex == -1) return; // No total row found

      // 3. Check if category already exists
      if (existingCategories.contains(category)) return;

      // 4. Find alphabetical insertion position
      int insertPos = 0; // Position within the category list
      for (int i = 0; i < existingCategories.length; i++) {
        if (category.compareTo(existingCategories[i]) > 0) {
          insertPos = i + 1;
        } else {
          break;
        }
      }

      // Convert to 1-based sheet row: header=1, first category=2
      final insertRow = insertPos + 2;

      // 5. Get sheet ID and insert a blank row
      final sheetId = await _getSheetId(api, spreadsheetId, totalsTabName);
      await _insertRow(api, spreadsheetId, sheetId, insertRow);

      // 6. Write category name + SUMIF formula
      final formula =
          "=SUMIF('$expensesTabName'!E:E,\"$category\",'$expensesTabName'!C:C)";
      final vr = sheets.ValueRange()
        ..values = [
          [category, formula]
        ];
      await api.spreadsheets.values.update(
        vr,
        spreadsheetId,
        '$totalsTabName!A$insertRow:B$insertRow',
        valueInputOption: 'USER_ENTERED',
      );

      // 7. Update total row (it shifted down by 1)
      final newTotalRow = totalRowIndex + 2; // +1 for 1-based, +1 for shift
      final totalFormula = '=SUM(B2:B${newTotalRow - 1})';
      final totalVr = sheets.ValueRange()
        ..values = [
          ['סה"כ', totalFormula]
        ];
      await api.spreadsheets.values.update(
        totalVr,
        spreadsheetId,
        '$totalsTabName!A$newTotalRow:B$newTotalRow',
        valueInputOption: 'USER_ENTERED',
      );

      // 8. Format the new row + total row + borders
      await api.spreadsheets.batchUpdate(
        sheets.BatchUpdateSpreadsheetRequest(requests: [
          // Number format for the new amount cell
          sheets.Request(
            repeatCell: sheets.RepeatCellRequest(
              range: sheets.GridRange(
                sheetId: sheetId,
                startRowIndex: insertRow - 1, // 0-indexed
                endRowIndex: insertRow,
                startColumnIndex: 1,
                endColumnIndex: 2,
              ),
              cell: sheets.CellData(
                userEnteredFormat: sheets.CellFormat(
                  numberFormat: sheets.NumberFormat(
                    type: 'NUMBER',
                    pattern: '#,##0.00',
                  ),
                ),
              ),
              fields: 'userEnteredFormat.numberFormat',
            ),
          ),
          // Bold + gray bg for total row
          sheets.Request(
            repeatCell: sheets.RepeatCellRequest(
              range: sheets.GridRange(
                sheetId: sheetId,
                startRowIndex: newTotalRow - 1, // 0-indexed
                endRowIndex: newTotalRow,
                startColumnIndex: 0,
                endColumnIndex: 2,
              ),
              cell: sheets.CellData(
                userEnteredFormat: sheets.CellFormat(
                  textFormat: sheets.TextFormat(bold: true, fontSize: 12),
                  backgroundColor: sheets.Color(
                    red: 0.93, green: 0.93, blue: 0.93, alpha: 1.0,
                  ),
                  numberFormat: sheets.NumberFormat(
                    type: 'NUMBER',
                    pattern: '#,##0.00',
                  ),
                ),
              ),
              fields:
                  'userEnteredFormat(textFormat,backgroundColor,numberFormat)',
            ),
          ),
          // Borders around entire category table (header through total)
          sheets.Request(
            updateBorders: sheets.UpdateBordersRequest(
              range: sheets.GridRange(
                sheetId: sheetId,
                startRowIndex: 0,
                endRowIndex: newTotalRow, // 0-indexed end (exclusive)
                startColumnIndex: 0,
                endColumnIndex: 2,
              ),
              top: _solidBorder(),
              bottom: _solidBorder(),
              left: _solidBorder(),
              right: _solidBorder(),
              innerHorizontal: _solidBorder(),
              innerVertical: _solidBorder(),
            ),
          ),
          // Thick border above total row
          sheets.Request(
            updateBorders: sheets.UpdateBordersRequest(
              range: sheets.GridRange(
                sheetId: sheetId,
                startRowIndex: newTotalRow - 1, // 0-indexed
                endRowIndex: newTotalRow,
                startColumnIndex: 0,
                endColumnIndex: 2,
              ),
              top: _thickBorder(),
            ),
          ),
        ]),
        spreadsheetId,
      );

      debugPrint(
        'Sheets: added category "$category" at row $insertRow in "$totalsTabName"',
      );
    } catch (e) {
      debugPrint('Sheets: failed to add category to totals: $e');
    }
  }

  // ────────────────── Sorted insertion logic ──────────────────

  /// Find the 1-based row index where a new receipt should be inserted.
  /// Rows are sorted chronologically by month (YYYYMM).
  /// Returns the row number for the new row (after the last row of the
  /// same month, or before the first row of a later month).
  Future<int> _findInsertionRow(
    sheets.SheetsApi api,
    String spreadsheetId,
    String tabName,
    int newSortKey,
  ) async {
    try {
      final resp = await api.spreadsheets.values.get(
        spreadsheetId,
        '$tabName!A:A',
      );

      final values = resp.values;
      if (values == null || values.length <= 1) {
        return 2; // First data row (row 1 is header)
      }

      // Iterate data rows (skip header at index 0)
      int insertAfter = 1; // Default: after header
      for (int i = 1; i < values.length; i++) {
        if (values[i].isEmpty) continue;
        final cellKey = _parseSortKey(values[i][0].toString());
        if (cellKey <= newSortKey) {
          insertAfter = i + 1; // 1-based row (index + 1)
        } else {
          break; // We've passed the correct block
        }
      }

      return insertAfter + 1; // Insert AFTER the last matching row
    } catch (e) {
      debugPrint('Sheets: error finding insertion row: $e');
      return 2; // Fallback: first data row
    }
  }

  /// Parse "MM/YYYY" into a sort key (YYYYMM).
  int _parseSortKey(String monthStr) {
    try {
      final parts = monthStr.split('/');
      if (parts.length == 2) {
        final month = int.parse(parts[0]);
        final year = int.parse(parts[1]);
        return year * 100 + month;
      }
    } catch (_) {}
    return 0;
  }

  /// Extract month number (1-12) from sort key.
  int _monthFromSortKey(int sortKey) => sortKey % 100;

  // ───────────────── Row insertion + formatting ─────────────────

  /// Insert a blank row at the given 1-based row index.
  Future<void> _insertRow(
    sheets.SheetsApi api,
    String spreadsheetId,
    int sheetId,
    int rowNumber,
  ) async {
    final zeroIndex = rowNumber - 1; // Convert to 0-based
    await api.spreadsheets.batchUpdate(
      sheets.BatchUpdateSpreadsheetRequest(requests: [
        sheets.Request(
          insertDimension: sheets.InsertDimensionRequest(
            range: sheets.DimensionRange(
              sheetId: sheetId,
              dimension: 'ROWS',
              startIndex: zeroIndex,
              endIndex: zeroIndex + 1,
            ),
            inheritFromBefore: false,
          ),
        ),
      ]),
      spreadsheetId,
    );
  }

  /// Apply the month background color and borders to a single row.
  Future<void> _formatRow(
    sheets.SheetsApi api,
    String spreadsheetId,
    int sheetId,
    int rowNumber,
    int month,
  ) async {
    final zeroIndex = rowNumber - 1;
    final rgb = AppConstants.monthColors[month] ?? [0xFF, 0xFF, 0xFF];

    await api.spreadsheets.batchUpdate(
      sheets.BatchUpdateSpreadsheetRequest(requests: [
        // Background color
        sheets.Request(
          repeatCell: sheets.RepeatCellRequest(
            range: sheets.GridRange(
              sheetId: sheetId,
              startRowIndex: zeroIndex,
              endRowIndex: zeroIndex + 1,
              startColumnIndex: 0,
              endColumnIndex: AppConstants.sheetsColumnCount,
            ),
            cell: sheets.CellData(
              userEnteredFormat: sheets.CellFormat(
                backgroundColor: sheets.Color(
                  red: rgb[0] / 255.0,
                  green: rgb[1] / 255.0,
                  blue: rgb[2] / 255.0,
                  alpha: 1.0,
                ),
                verticalAlignment: 'MIDDLE',
              ),
            ),
            fields: 'userEnteredFormat(backgroundColor,verticalAlignment)',
          ),
        ),
        // Thin borders
        sheets.Request(
          updateBorders: sheets.UpdateBordersRequest(
            range: sheets.GridRange(
              sheetId: sheetId,
              startRowIndex: zeroIndex,
              endRowIndex: zeroIndex + 1,
              startColumnIndex: 0,
              endColumnIndex: AppConstants.sheetsColumnCount,
            ),
            top: _solidBorder(),
            bottom: _solidBorder(),
            left: _solidBorder(),
            right: _solidBorder(),
            innerVertical: _solidBorder(),
          ),
        ),
        // Number format for amount column (C = index 2)
        sheets.Request(
          repeatCell: sheets.RepeatCellRequest(
            range: sheets.GridRange(
              sheetId: sheetId,
              startRowIndex: zeroIndex,
              endRowIndex: zeroIndex + 1,
              startColumnIndex: 2,
              endColumnIndex: 3,
            ),
            cell: sheets.CellData(
              userEnteredFormat: sheets.CellFormat(
                numberFormat: sheets.NumberFormat(
                  type: 'NUMBER',
                  pattern: '#,##0.00',
                ),
              ),
            ),
            fields: 'userEnteredFormat.numberFormat',
          ),
        ),
      ]),
      spreadsheetId,
    );
  }

  // ───────────────────── Idempotency check ─────────────────────

  /// Check if a drive link already exists in column F (idempotency).
  /// Column F now contains HYPERLINK formulas, so we check if the cell
  /// value (display text) or the raw formula contains the URL.
  Future<bool> _isDriveLinkInSheet(
    sheets.SheetsApi api,
    String spreadsheetId,
    String tabName,
    String driveLink,
  ) async {
    try {
      // Use FORMULA value render option to see the raw HYPERLINK formula
      final resp = await api.spreadsheets.values.get(
        spreadsheetId,
        '$tabName!F:F',
        valueRenderOption: 'FORMULA',
      );
      if (resp.values == null) return false;
      for (final row in resp.values!) {
        if (row.isNotEmpty) {
          final cell = row[0].toString();
          // Match raw URL or URL inside HYPERLINK("url","...")
          if (cell == driveLink || cell.contains(driveLink)) {
            return true;
          }
        }
      }
      return false;
    } catch (e) {
      debugPrint('Sheets: idempotency check error: $e');
      return false;
    }
  }

  // ──────────────────── Utility helpers ────────────────────────

  /// Get the numeric sheet ID for a given tab name.
  Future<int> _getSheetId(
    sheets.SheetsApi api,
    String spreadsheetId,
    String tabName,
  ) async {
    final spreadsheet = await api.spreadsheets.get(spreadsheetId);
    for (final sheet in spreadsheet.sheets ?? <sheets.Sheet>[]) {
      if (sheet.properties?.title == tabName) {
        return sheet.properties!.sheetId ?? 0;
      }
    }
    return 0; // Default first sheet
  }

  /// Thin solid black border.
  sheets.Border _solidBorder() {
    return sheets.Border(
      style: 'SOLID',
      color: sheets.Color(red: 0, green: 0, blue: 0, alpha: 1),
    );
  }

  /// Thick solid black border (used between month blocks / headers).
  sheets.Border _thickBorder() {
    return sheets.Border(
      style: 'SOLID_MEDIUM',
      color: sheets.Color(red: 0, green: 0, blue: 0, alpha: 1),
    );
  }

  /// Column width requests for the main data sheet.
  List<sheets.Request> _columnWidthRequests(int sheetId) {
    // A: חודש(90), B: שם עסק(200), C: סכום(100), D: מטבע(70),
    // E: קטגוריה(120), F: קישור(280)
    const widths = [90, 200, 100, 70, 120, 280];
    return List.generate(widths.length, (i) {
      return sheets.Request(
        updateDimensionProperties: sheets.UpdateDimensionPropertiesRequest(
          range: sheets.DimensionRange(
            sheetId: sheetId,
            dimension: 'COLUMNS',
            startIndex: i,
            endIndex: i + 1,
          ),
          properties: sheets.DimensionProperties(pixelSize: widths[i]),
          fields: 'pixelSize',
        ),
      );
    });
  }
}
