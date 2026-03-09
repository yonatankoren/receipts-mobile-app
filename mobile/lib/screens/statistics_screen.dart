/// Statistics Screen — in-app expense analytics by category.
///
/// Shows a year/month-filtered breakdown of expenses with a pie chart.
/// Data comes from local SQLite receipts whose status is reviewed or synced —
/// the same records written to Google Sheets — so the totals match the
/// "סיכום YYYY" tab (same fields: totalAmount grouped by category).

import 'package:flutter/material.dart';
import 'package:fl_chart/fl_chart.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';
import '../models/receipt.dart';
import '../providers/app_state.dart';
import '../services/custom_category_service.dart';
import '../utils/constants.dart';

class StatisticsScreen extends StatefulWidget {
  const StatisticsScreen({super.key});

  @override
  State<StatisticsScreen> createState() => _StatisticsScreenState();
}

class _StatisticsScreenState extends State<StatisticsScreen>
    with AutomaticKeepAliveClientMixin {
  int? _selectedYear;
  int? _selectedMonth; // null = full year

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      context.read<AppState>().loadReceipts();
    });
  }

  /// Parse the month number (1-12) from a receipt, using the same logic
  /// as [Receipt.monthKey] / [Receipt.sheetsMonth] so it stays in sync
  /// with the spreadsheet SUMIF formulas.
  static int _receiptMonth(Receipt r) {
    final d = r.receiptDate != null
        ? DateTime.tryParse(r.receiptDate!) ?? r.captureTimestamp
        : r.captureTimestamp;
    return d.month;
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final appState = context.watch<AppState>();

    // Only include finalised receipts — these are the ones in the spreadsheet.
    final receipts = appState.receipts
        .where((r) =>
            (r.status == ReceiptStatus.reviewed ||
                r.status == ReceiptStatus.synced) &&
            r.totalAmount != null &&
            r.category != null &&
            r.category!.isNotEmpty)
        .toList();

    // Available years (descending)
    final years = receipts.map((r) => r.receiptYear).toSet().toList()
      ..sort((a, b) => b.compareTo(a));

    if (years.isEmpty) {
      return _buildEmptyState('אין נתונים להצגה');
    }

    // Default to latest year
    final year = (_selectedYear != null && years.contains(_selectedYear))
        ? _selectedYear!
        : years.first;
    if (_selectedYear != year) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) setState(() => _selectedYear = year);
      });
    }

    // Receipts in selected year
    final yearReceipts =
        receipts.where((r) => r.receiptYear == year).toList();

    // Which months have data (for enabling/disabling month chips)
    final monthsWithData = yearReceipts.map(_receiptMonth).toSet();

    // Auto-reset month if the selected month lost all its data (e.g. deletion)
    if (_selectedMonth != null && !monthsWithData.contains(_selectedMonth)) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) setState(() => _selectedMonth = null);
      });
    }

    // Apply month filter
    final filtered = _selectedMonth != null
        ? yearReceipts
            .where((r) => _receiptMonth(r) == _selectedMonth)
            .toList()
        : yearReceipts;

    // Group by category, sum amounts — skip categories with total ≤ 0
    final categoryTotals = <String, double>{};
    for (final r in filtered) {
      categoryTotals[r.category!] =
          (categoryTotals[r.category!] ?? 0) + r.totalAmount!;
    }
    categoryTotals.removeWhere((_, v) => v <= 0);

    final total = categoryTotals.values.fold(0.0, (s, v) => s + v);

    // Sort descending by amount
    final sorted = categoryTotals.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));

    final fmt = NumberFormat('#,##0.00', 'he_IL');

    return Scaffold(
      backgroundColor: Colors.white,
      body: SafeArea(
        child: Column(
          children: [
            const SizedBox(height: 16),
            if (years.length > 1) ...[
              _buildYearSelector(years, year),
              const SizedBox(height: 8),
            ],
            _buildMonthSelector(monthsWithData),
            const SizedBox(height: 16),
            Expanded(
              child: sorted.isEmpty
                  ? Center(
                      child: Text(
                        _selectedMonth != null
                            ? 'אין הוצאות בחודש זה'
                            : 'אין הוצאות בשנה זו',
                        style: TextStyle(
                          fontSize: 18,
                          color: Colors.grey.shade600,
                        ),
                      ),
                    )
                  : _buildContent(sorted, total, fmt),
            ),
            // Extra space so the page-indicator dots don't overlap content
            const SizedBox(height: 28),
          ],
        ),
      ),
    );
  }

  // ──────────────────── Content ────────────────────

  Widget _buildContent(
    List<MapEntry<String, double>> sorted,
    double total,
    NumberFormat fmt,
  ) {
    return SingleChildScrollView(
      padding: const EdgeInsets.symmetric(horizontal: 24),
      child: Column(
        children: [
          // Total
          Text(
            '₪${fmt.format(total)}',
            style: const TextStyle(
              fontSize: 36,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            _selectedMonth != null
                ? 'סה"כ הוצאות ב${AppConstants.hebrewMonthNames[_selectedMonth! - 1]}'
                : 'סה"כ הוצאות ב-$_selectedYear',
            style: TextStyle(fontSize: 15, color: Colors.grey.shade600),
          ),
          const SizedBox(height: 28),

          // Pie chart
          SizedBox(
            height: 220,
            child: PieChart(
              PieChartData(
                sectionsSpace: 2,
                centerSpaceRadius: 40,
                sections: sorted.map((e) {
                  final pct = e.value / total * 100;
                  return PieChartSectionData(
                    value: e.value,
                    title: pct >= 5 ? '${pct.toStringAsFixed(0)}%' : '',
                    color: CustomCategoryService.instance.colorFor(e.key),
                    radius: 80,
                    titleStyle: const TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.bold,
                      color: Colors.white,
                    ),
                    titlePositionPercentageOffset: 0.55,
                  );
                }).toList(),
              ),
            ),
          ),
          const SizedBox(height: 28),

          // Legend
          ...sorted.map((e) => _buildLegendRow(e, total, fmt)),
          const SizedBox(height: 16),
        ],
      ),
    );
  }

  Widget _buildLegendRow(
    MapEntry<String, double> entry,
    double total,
    NumberFormat fmt,
  ) {
    final pct = entry.value / total * 100;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          Container(
            width: 14,
            height: 14,
            decoration: BoxDecoration(
              color: CustomCategoryService.instance.colorFor(entry.key),
              borderRadius: BorderRadius.circular(4),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              entry.key,
              style: const TextStyle(fontSize: 14),
            ),
          ),
          Text(
            '₪${fmt.format(entry.value)}',
            style: const TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(width: 8),
          SizedBox(
            width: 50,
            child: Text(
              '${pct.toStringAsFixed(1)}%',
              style: TextStyle(fontSize: 12, color: Colors.grey.shade500),
              textAlign: TextAlign.start,
            ),
          ),
        ],
      ),
    );
  }

  // ──────────────────── Year selector ────────────────────

  Widget _buildYearSelector(List<int> years, int selectedYear) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24),
      child: Wrap(
        alignment: WrapAlignment.center,
        spacing: 8,
        children: years.map((y) {
          final selected = y == selectedYear;
          return ChoiceChip(
            label: Text('$y'),
            selected: selected,
            onSelected: (_) => setState(() {
              _selectedYear = y;
              _selectedMonth = null;
            }),
            selectedColor: Colors.blue.shade100,
            backgroundColor: Colors.grey.shade100,
            labelStyle: TextStyle(
              fontWeight: selected ? FontWeight.bold : FontWeight.normal,
              color: selected ? Colors.blue.shade800 : Colors.black87,
            ),
          );
        }).toList(),
      ),
    );
  }

  // ──────────────────── Month selector ────────────────────

  Widget _buildMonthSelector(Set<int> monthsWithData) {
    return SizedBox(
      height: 40,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 24),
        itemCount: 13, // "כל השנה" + 12 months
        separatorBuilder: (_, __) => const SizedBox(width: 6),
        itemBuilder: (_, i) {
          if (i == 0) {
            final selected = _selectedMonth == null;
            return ChoiceChip(
              label: const Text('כל השנה'),
              selected: selected,
              onSelected: (_) => setState(() => _selectedMonth = null),
              selectedColor: Colors.blue.shade100,
              backgroundColor: Colors.grey.shade100,
              labelStyle: TextStyle(
                fontSize: 13,
                fontWeight: selected ? FontWeight.bold : FontWeight.normal,
                color: selected ? Colors.blue.shade800 : Colors.black87,
              ),
            );
          }
          final month = i;
          final hasData = monthsWithData.contains(month);
          final selected = _selectedMonth == month;
          return ChoiceChip(
            label: Text(AppConstants.hebrewMonthNames[month - 1]),
            selected: selected,
            onSelected: hasData
                ? (_) => setState(() => _selectedMonth = month)
                : null,
            selectedColor: Colors.blue.shade100,
            backgroundColor:
                hasData ? Colors.grey.shade100 : Colors.grey.shade50,
            labelStyle: TextStyle(
              fontSize: 13,
              fontWeight: selected ? FontWeight.bold : FontWeight.normal,
              color: selected
                  ? Colors.blue.shade800
                  : hasData
                      ? Colors.black87
                      : Colors.grey.shade400,
            ),
          );
        },
      ),
    );
  }

  // ──────────────────── Empty state ────────────────────

  Widget _buildEmptyState(String message) {
    return Scaffold(
      backgroundColor: Colors.white,
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.bar_chart, size: 64, color: Colors.grey.shade300),
            const SizedBox(height: 16),
            Text(
              message,
              style: TextStyle(fontSize: 18, color: Colors.grey.shade600),
            ),
          ],
        ),
      ),
    );
  }
}
