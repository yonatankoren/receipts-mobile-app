/// Google Sheets service.
///
/// Writes receipt rows to a configured spreadsheet with:
///   - Sorted insertion by month (chronological order)
///   - Month-based color coding (12 pastel colors)
///   - A separate "סיכום" tab with SUMIF totals per category
///   - Borders and formatting for a clean look
///   - Idempotency: checks drive_file_link (column F) before inserting

import 'package:flutter/foundation.dart';
import 'package:googleapis/sheets/v4.dart' as sheets;
import 'package:shared_preferences/shared_preferences.dart';
import 'auth_service.dart';
import '../models/receipt.dart';
import '../utils/constants.dart';

class SheetsService {
  static final SheetsService instance = SheetsService._();
  SheetsService._();

  static const String _prefKeySpreadsheetId = 'sheets_spreadsheet_id';
  static const String _prefKeySheetName = 'sheets_sheet_name';

  // ────────────────────────── Settings ──────────────────────────

  Future<String?> getSpreadsheetId() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_prefKeySpreadsheetId);
  }

  Future<void> setSpreadsheetId(String id) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prefKeySpreadsheetId, id);
  }

  Future<String> getSheetName() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_prefKeySheetName) ?? 'קבלות';
  }

  Future<void> setSheetName(String name) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prefKeySheetName, name);
  }

  // ────────────────────── Main entry point ──────────────────────

  /// Insert a receipt row into the correct sorted position,
  /// apply month color, borders, and ensure the totals tab exists.
  Future<void> appendReceiptRow(Receipt receipt) async {
    final spreadsheetId = await getSpreadsheetId();
    if (spreadsheetId == null || spreadsheetId.isEmpty) {
      throw Exception('Spreadsheet ID not configured. Set it in Settings.');
    }

    final client = await AuthService.instance.getAuthenticatedClient();
    if (client == null) {
      throw Exception('Not authenticated — cannot write to Sheets');
    }

    try {
      final api = sheets.SheetsApi(client);
      final sheetName = await getSheetName();

      // 1. Ensure the main sheet headers + totals tab
      await _ensureSetup(api, spreadsheetId, sheetName);

      // 2. Idempotency: check drive link in column F
      if (receipt.driveFileLink != null && receipt.driveFileLink!.isNotEmpty) {
        final dup = await _isDriveLinkInSheet(
          api, spreadsheetId, sheetName, receipt.driveFileLink!,
        );
        if (dup) {
          debugPrint('Sheets: drive link already exists, skipping');
          return;
        }
      }

      // 3. Read existing month column (A) to find insertion point
      final insertRow = await _findInsertionRow(
        api, spreadsheetId, sheetName, receipt.monthSortKey,
      );

      // 4. Get the main sheet's numeric ID (needed for batchUpdate)
      final mainSheetId = await _getSheetId(api, spreadsheetId, sheetName);

      // 5. Insert a blank row at the position
      await _insertRow(api, spreadsheetId, mainSheetId, insertRow);

      // 6. Write the data into the new row
      final row = receipt.toSheetsRow();
      final valueRange = sheets.ValueRange()
        ..values = [row.map((v) => v.toString()).toList()];

      await api.spreadsheets.values.update(
        valueRange,
        spreadsheetId,
        '$sheetName!A$insertRow:F$insertRow',
        valueInputOption: 'USER_ENTERED',
      );

      // 7. Apply month color + borders to the new row
      final month = _monthFromSortKey(receipt.monthSortKey);
      await _formatRow(api, spreadsheetId, mainSheetId, insertRow, month);

      debugPrint('Sheets: inserted receipt at row $insertRow (month ${receipt.sheetsMonth})');
    } finally {
      client.close();
    }
  }

  // ──────────────────────── Setup helpers ────────────────────────

  /// Ensure main sheet headers exist and the totals tab is set up.
  Future<void> _ensureSetup(
    sheets.SheetsApi api,
    String spreadsheetId,
    String sheetName,
  ) async {
    // --- Main sheet headers ---
    try {
      final resp = await api.spreadsheets.values.get(
        spreadsheetId,
        '$sheetName!A1:F1',
      );
      if (resp.values == null || resp.values!.isEmpty) {
        await _writeHeaders(api, spreadsheetId, sheetName);
      }
    } catch (e) {
      debugPrint('Sheets: header check error: $e');
      try {
        await _writeHeaders(api, spreadsheetId, sheetName);
      } catch (_) {}
    }

    // --- Totals tab ---
    await _ensureTotalsSheet(api, spreadsheetId, sheetName);
  }

  Future<void> _writeHeaders(
    sheets.SheetsApi api,
    String spreadsheetId,
    String sheetName,
  ) async {
    final vr = sheets.ValueRange()
      ..values = [AppConstants.sheetsHeaders];
    await api.spreadsheets.values.update(
      vr,
      spreadsheetId,
      '$sheetName!A1:F1',
      valueInputOption: 'RAW',
    );

    // Format the header row: bold + dark background
    final mainSheetId = await _getSheetId(api, spreadsheetId, sheetName);
    await api.spreadsheets.batchUpdate(
      sheets.BatchUpdateSpreadsheetRequest(requests: [
        // Bold header text
        sheets.Request(
          repeatCell: sheets.RepeatCellRequest(
            range: sheets.GridRange(
              sheetId: mainSheetId,
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
              sheetId: mainSheetId,
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
        ..._columnWidthRequests(mainSheetId),
        // Freeze header row
        sheets.Request(
          updateSheetProperties: sheets.UpdateSheetPropertiesRequest(
            properties: sheets.SheetProperties(
              sheetId: mainSheetId,
              gridProperties: sheets.GridProperties(frozenRowCount: 1),
            ),
            fields: 'gridProperties.frozenRowCount',
          ),
        ),
      ]),
      spreadsheetId,
    );

    debugPrint('Sheets: wrote + formatted headers');
  }

  // ─────────────────── Totals sheet (סיכום) ───────────────────

  Future<void> _ensureTotalsSheet(
    sheets.SheetsApi api,
    String spreadsheetId,
    String mainSheetName,
  ) async {
    final totalsName = AppConstants.totalSheetName;

    // Check if the tab already exists
    final spreadsheet = await api.spreadsheets.get(spreadsheetId);
    final exists = spreadsheet.sheets?.any(
      (s) => s.properties?.title == totalsName,
    ) ?? false;

    if (exists) return; // Already set up

    // Create the tab
    try {
      await api.spreadsheets.batchUpdate(
        sheets.BatchUpdateSpreadsheetRequest(requests: [
          sheets.Request(
            addSheet: sheets.AddSheetRequest(
              properties: sheets.SheetProperties(title: totalsName),
            ),
          ),
        ]),
        spreadsheetId,
      );
    } catch (e) {
      debugPrint('Sheets: totals tab might already exist: $e');
      return;
    }

    // Get the new sheet's ID
    final totalsSheetId = await _getSheetId(api, spreadsheetId, totalsName);

    // Build header + category rows + overall total
    final categories = AppConstants.categories;
    final rows = <List<String>>[
      ['קטגוריה', 'סכום'], // Header (row 1)
      ...categories.map((cat) => [
        cat,
        "=SUMIF('$mainSheetName'!E:E,\"$cat\",'$mainSheetName'!C:C)",
      ]),
      ['סה"כ', '=SUM(B2:B10)'], // Total row — sums the SUMIF results above
    ];

    final vr = sheets.ValueRange()..values = rows;
    await api.spreadsheets.values.update(
      vr,
      spreadsheetId,
      '$totalsName!A1:B${rows.length}',
      valueInputOption: 'USER_ENTERED',
    );

    // Format the totals sheet
    final totalRowIndex = rows.length - 1; // 0-indexed
    await api.spreadsheets.batchUpdate(
      sheets.BatchUpdateSpreadsheetRequest(requests: [
        // Bold header row
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
        // Bold total row
        sheets.Request(
          repeatCell: sheets.RepeatCellRequest(
            range: sheets.GridRange(
              sheetId: totalsSheetId,
              startRowIndex: totalRowIndex,
              endRowIndex: totalRowIndex + 1,
              startColumnIndex: 0,
              endColumnIndex: 2,
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
        // Borders around everything
        sheets.Request(
          updateBorders: sheets.UpdateBordersRequest(
            range: sheets.GridRange(
              sheetId: totalsSheetId,
              startRowIndex: 0,
              endRowIndex: rows.length,
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
              sheetId: totalsSheetId,
              startRowIndex: totalRowIndex,
              endRowIndex: totalRowIndex + 1,
              startColumnIndex: 0,
              endColumnIndex: 2,
            ),
            top: _thickBorder(),
          ),
        ),
        // Column widths
        sheets.Request(
          updateDimensionProperties: sheets.UpdateDimensionPropertiesRequest(
            range: sheets.DimensionRange(
              sheetId: totalsSheetId,
              dimension: 'COLUMNS',
              startIndex: 0,
              endIndex: 1,
            ),
            properties: sheets.DimensionProperties(pixelSize: 140),
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
        // Number format for amounts (column B rows 2+)
        sheets.Request(
          repeatCell: sheets.RepeatCellRequest(
            range: sheets.GridRange(
              sheetId: totalsSheetId,
              startRowIndex: 1,
              endRowIndex: rows.length,
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
      ]),
      spreadsheetId,
    );

    debugPrint('Sheets: created and formatted totals tab');
  }

  // ────────────────── Sorted insertion logic ──────────────────

  /// Find the 1-based row index where a new receipt should be inserted.
  /// Rows are sorted chronologically by month (YYYYMM).
  /// Returns the row number for the new row (after the last row of the
  /// same month, or before the first row of a later month).
  Future<int> _findInsertionRow(
    sheets.SheetsApi api,
    String spreadsheetId,
    String sheetName,
    int newSortKey,
  ) async {
    try {
      final resp = await api.spreadsheets.values.get(
        spreadsheetId,
        '$sheetName!A:A',
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
    String sheetName,
    String driveLink,
  ) async {
    try {
      // Use FORMULA value render option to see the raw HYPERLINK formula
      final resp = await api.spreadsheets.values.get(
        spreadsheetId,
        '$sheetName!F:F',
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
    String sheetName,
  ) async {
    final spreadsheet = await api.spreadsheets.get(spreadsheetId);
    for (final sheet in spreadsheet.sheets ?? <sheets.Sheet>[]) {
      if (sheet.properties?.title == sheetName) {
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
