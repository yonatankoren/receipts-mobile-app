/// Receipts List Screen — grouped by month.
///
/// Shows:
///   - Month sections with receipt count + pending sync count
///   - Receipt cards with status indicators
///   - "Open in Drive" action per month
///   - Navigation to review screen for each receipt
///   - Multi-select via long-press for batch deletion

import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import '../models/receipt.dart';
import '../providers/app_state.dart';
import '../services/drive_service.dart';
import 'review_and_fix_screen.dart';
import 'package:url_launcher/url_launcher.dart';

class ReceiptsListScreen extends StatefulWidget {
  const ReceiptsListScreen({super.key});

  @override
  State<ReceiptsListScreen> createState() => _ReceiptsListScreenState();
}

class _ReceiptsListScreenState extends State<ReceiptsListScreen> {
  final Set<String> _selectedIds = {};
  bool get _isSelecting => _selectedIds.isNotEmpty;

  @override
  void initState() {
    super.initState();
    context.read<AppState>().loadReceipts();
  }

  void _toggleSelection(String id) {
    setState(() {
      if (_selectedIds.contains(id)) {
        _selectedIds.remove(id);
      } else {
        _selectedIds.add(id);
      }
    });
  }

  void _clearSelection() {
    setState(() => _selectedIds.clear());
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return PopScope(
      canPop: !_isSelecting,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && _isSelecting) _clearSelection();
      },
      child: Scaffold(
        appBar: AppBar(
          title: _isSelecting
              ? Text('${_selectedIds.length} נבחרו')
              : const Text('קבלות אחרונות'),
          leading: _isSelecting
              ? IconButton(
                  icon: const Icon(Icons.close),
                  onPressed: _clearSelection,
                )
              : null,
          actions: _isSelecting
              ? [
                  IconButton(
                    icon: const Icon(Icons.select_all_rounded),
                    tooltip: 'בחר הכל',
                    onPressed: () {
                      final appState = context.read<AppState>();
                      final cutoff =
                          DateTime.now().subtract(const Duration(days: 90));
                      final allIds = appState.receipts
                          .where((r) => r.captureTimestamp.isAfter(cutoff))
                          .map((r) => r.id)
                          .toSet();
                      setState(() {
                        if (_selectedIds.length == allIds.length) {
                          _selectedIds.clear();
                        } else {
                          _selectedIds.addAll(allIds);
                        }
                      });
                    },
                  ),
                ]
              : const [],
        ),
        body: Consumer<AppState>(
          builder: (context, appState, _) {
            if (appState.isLoading && appState.receipts.isEmpty) {
              return const Center(child: CircularProgressIndicator());
            }

            final cutoff = DateTime.now().subtract(const Duration(days: 90));
            final recentReceipts = appState.receipts.where(
              (r) => r.captureTimestamp.isAfter(cutoff),
            ).toList();

            // Purge stale selections
            final validIds = recentReceipts.map((r) => r.id).toSet();
            _selectedIds.removeWhere((id) => !validIds.contains(id));

            final byMonth = <String, List<Receipt>>{};
            for (final r in recentReceipts) {
              byMonth.putIfAbsent(r.monthKey, () => []).add(r);
            }
            final sortedMonths = byMonth.keys.toList()
              ..sort((a, b) => b.compareTo(a));

            if (sortedMonths.isEmpty) {
              return Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.receipt_long,
                        size: 80, color: Colors.grey.shade300),
                    const SizedBox(height: 16),
                    Text(
                      'אין קבלות אחרונות',
                      style: theme.textTheme.titleLarge?.copyWith(
                        color: Colors.grey.shade500,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'צלם קבלה כדי להתחיל',
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: Colors.grey.shade400,
                      ),
                    ),
                  ],
                ),
              );
            }

            return Column(
              children: [
                Expanded(
                  child: RefreshIndicator(
                    onRefresh: () => appState.loadReceipts(),
                    child: ListView.builder(
                      padding: EdgeInsets.only(
                        bottom: _isSelecting ? 80 : 16,
                      ),
                      itemCount: sortedMonths.length,
                      itemBuilder: (context, index) {
                        final month = sortedMonths[index];
                        final receipts = byMonth[month]!;
                        return _buildMonthSection(
                            context, month, receipts, theme);
                      },
                    ),
                  ),
                ),
                if (_isSelecting) _buildDeleteBar(theme),
              ],
            );
          },
        ),
      ),
    );
  }

  // ──────────────── Delete bar ────────────────

  Widget _buildDeleteBar(ThemeData theme) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
      decoration: BoxDecoration(
        color: theme.scaffoldBackgroundColor,
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.08),
            blurRadius: 8,
            offset: const Offset(0, -2),
          ),
        ],
      ),
      child: SafeArea(
        top: false,
        child: SizedBox(
          width: double.infinity,
          height: 48,
          child: ElevatedButton.icon(
            onPressed: _confirmBatchDelete,
            icon: const Icon(Icons.delete_outline, size: 20),
            label: Text(
              _selectedIds.length == 1
                  ? 'מחק קבלה'
                  : 'מחק ${_selectedIds.length} קבלות',
              style:
                  const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
            ),
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.red.shade600,
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(14),
              ),
            ),
          ),
        ),
      ),
    );
  }

  // ──────────────── Batch delete ────────────────

  Future<void> _confirmBatchDelete() async {
    final count = _selectedIds.length;
    final singular = count == 1;

    final proceed = await showDialog<bool>(
      context: context,
      builder: (ctx) => Directionality(
        textDirection: TextDirection.rtl,
        child: AlertDialog(
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          title: Row(
            children: [
              Icon(Icons.warning_amber_rounded,
                  color: Colors.red.shade600, size: 26),
              const SizedBox(width: 8),
              Text(singular ? 'מחיקת קבלה' : 'מחיקת $count קבלות'),
            ],
          ),
          content: Text(
            singular
                ? 'הקבלה תימחק לצמיתות מהאפליקציה, מהגיליון ב-Google Sheets ומתיקיית הקבלות ב-Google Drive.\n\n'
                    'לא ניתן לשחזר את המידע לאחר המחיקה.'
                : '$count קבלות יימחקו לצמיתות מהאפליקציה, מהגיליון ב-Google Sheets ומתיקיית הקבלות ב-Google Drive.\n\n'
                    'לא ניתן לשחזר את המידע לאחר המחיקה.',
            style: const TextStyle(fontSize: 16, height: 1.5),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text(
                'ביטול',
                style: TextStyle(
                  color: Colors.grey.shade700,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            ElevatedButton.icon(
              onPressed: () => Navigator.pop(ctx, true),
              icon: const Icon(Icons.delete_outline, size: 20),
              label: Text(singular ? 'מחק' : 'מחק $count'),
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.red.shade600,
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
            ),
          ],
        ),
      ),
    );

    if (proceed != true || !mounted) return;

    final idsToDelete = Set<String>.from(_selectedIds);
    _clearSelection();

    final appState = context.read<AppState>();
    int deleted = 0;

    for (final id in idsToDelete) {
      try {
        await appState.deleteReceiptFully(id);
        deleted++;
      } catch (e) {
        debugPrint('Batch delete: failed for $id: $e');
      }
    }

    if (!mounted) return;

    final msg = deleted == idsToDelete.length
        ? (deleted == 1 ? 'הקבלה נמחקה בהצלחה' : '$deleted קבלות נמחקו בהצלחה')
        : '$deleted מתוך ${idsToDelete.length} קבלות נמחקו';

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(msg),
        backgroundColor:
            deleted == idsToDelete.length ? Colors.green : Colors.orange,
      ),
    );
  }

  // ──────────────── Month section ────────────────

  Widget _buildMonthSection(
    BuildContext context,
    String monthKey,
    List<Receipt> receipts,
    ThemeData theme,
  ) {
    final monthLabel = _formatMonthLabel(monthKey);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          margin: const EdgeInsets.only(top: 8),
          color:
              theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
          child: Row(
            children: [
              Icon(Icons.calendar_month,
                  size: 20, color: theme.colorScheme.primary),
              const SizedBox(width: 8),
              Text(
                monthLabel,
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(width: 8),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                decoration: BoxDecoration(
                  color: theme.colorScheme.primary.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Text(
                  '${receipts.length}',
                  style: TextStyle(
                    color: theme.colorScheme.primary,
                    fontWeight: FontWeight.w600,
                    fontSize: 13,
                  ),
                ),
              ),
              const Spacer(),
              IconButton(
                icon: Icon(Icons.open_in_new,
                    size: 20, color: theme.colorScheme.primary),
                tooltip: 'פתח בדרייב',
                onPressed: () => _openDriveFolder(monthKey),
              ),
            ],
          ),
        ),
        ...receipts.map(
          (r) => _buildReceiptCard(context, r, theme),
        ),
      ],
    );
  }

  // ──────────────── Receipt card ────────────────

  Widget _buildReceiptCard(
    BuildContext context,
    Receipt receipt,
    ThemeData theme,
  ) {
    final statusColor = _statusColor(receipt.status);
    final isSelected = _selectedIds.contains(receipt.id);

    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      color: isSelected
          ? theme.colorScheme.primary.withValues(alpha: 0.06)
          : null,
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: _isSelecting
            ? () => _toggleSelection(receipt.id)
            : () => Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) =>
                        ReviewAndFixScreen(receiptId: receipt.id),
                  ),
                ),
        onLongPress: _isSelecting
            ? null
            : () {
                HapticFeedback.mediumImpact();
                _toggleSelection(receipt.id);
              },
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            children: [
              // Selection checkbox (animated)
              AnimatedSize(
                duration: const Duration(milliseconds: 200),
                curve: Curves.easeInOut,
                child: _isSelecting
                    ? Padding(
                        padding: const EdgeInsets.only(left: 10),
                        child: _SelectionCheckbox(
                          selected: isSelected,
                          color: theme.colorScheme.primary,
                        ),
                      )
                    : const SizedBox.shrink(),
              ),

              // Thumbnail
              ClipRoundedRect(
                borderRadius: BorderRadius.circular(8),
                child: SizedBox(
                  width: 56,
                  height: 56,
                  child: File(receipt.imagePath).existsSync()
                      ? Image.file(
                          File(receipt.imagePath),
                          fit: BoxFit.cover,
                        )
                      : Container(
                          color: Colors.grey.shade200,
                          child:
                              const Icon(Icons.receipt, color: Colors.grey),
                        ),
                ),
              ),
              const SizedBox(width: 12),

              // Info
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      receipt.merchantName ?? 'קבלה לא מעובדת',
                      style: theme.textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 4),
                    Row(
                      children: [
                        if (receipt.totalAmount != null) ...[
                          Text(
                            '₪${receipt.totalAmount!.toStringAsFixed(2)}',
                            style: theme.textTheme.bodyMedium?.copyWith(
                              fontWeight: FontWeight.w600,
                              color: theme.colorScheme.primary,
                            ),
                          ),
                          const SizedBox(width: 8),
                        ],
                        Text(
                          receipt.receiptDate ??
                              _formatTimestamp(receipt.captureTimestamp),
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: Colors.grey.shade600,
                          ),
                        ),
                      ],
                    ),
                    if (receipt.category != null) ...[
                      const SizedBox(height: 2),
                      Text(
                        receipt.category!,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: Colors.grey.shade500,
                        ),
                      ),
                    ],
                  ],
                ),
              ),

              // Status indicator
              Container(
                width: 10,
                height: 10,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: statusColor,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ──────────────── Helpers ────────────────

  Color _statusColor(ReceiptStatus status) {
    switch (status) {
      case ReceiptStatus.captured:
        return Colors.grey;
      case ReceiptStatus.processing:
        return Colors.blue;
      case ReceiptStatus.reviewed:
        return Colors.orange;
      case ReceiptStatus.synced:
        return Colors.green;
      case ReceiptStatus.error:
        return Colors.red;
    }
  }

  String _formatMonthLabel(String monthKey) {
    try {
      final parts = monthKey.split('-');
      final date = DateTime(int.parse(parts[0]), int.parse(parts[1]));
      const months = [
        'ינואר', 'פברואר', 'מרץ', 'אפריל', 'מאי', 'יוני',
        'יולי', 'אוגוסט', 'ספטמבר', 'אוקטובר', 'נובמבר', 'דצמבר',
      ];
      return '${months[date.month - 1]} ${date.year}';
    } catch (_) {
      return monthKey;
    }
  }

  String _formatTimestamp(DateTime dt) {
    return '${dt.day}/${dt.month}/${dt.year}';
  }

  Future<void> _openDriveFolder(String monthKey) async {
    try {
      final link = await DriveService.instance.getMonthFolderLink(monthKey);
      if (link != null) {
        final uri = Uri.parse(link);
        if (await canLaunchUrl(uri)) {
          await launchUrl(uri, mode: LaunchMode.externalApplication);
        }
      } else {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
                content: Text('תיקיית החודש עדיין לא נוצרה בדרייב')),
          );
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('שגיאה בפתיחת דרייב: $e')),
        );
      }
    }
  }
}

// ──────────────── Selection checkbox widget ────────────────

class _SelectionCheckbox extends StatelessWidget {
  final bool selected;
  final Color color;

  const _SelectionCheckbox({required this.selected, required this.color});

  @override
  Widget build(BuildContext context) {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 200),
      width: 22,
      height: 22,
      decoration: BoxDecoration(
        color: selected ? color : Colors.transparent,
        border: Border.all(
          color: selected ? color : Colors.grey.shade400,
          width: 2,
        ),
        borderRadius: BorderRadius.circular(6),
      ),
      child: selected
          ? const Icon(Icons.check_rounded, size: 16, color: Colors.white)
          : null,
    );
  }
}

/// Helper widget since ClipRRect is verbose
class ClipRoundedRect extends StatelessWidget {
  final BorderRadius borderRadius;
  final Widget child;

  const ClipRoundedRect({
    super.key,
    required this.borderRadius,
    required this.child,
  });

  @override
  Widget build(BuildContext context) => ClipRRect(
        borderRadius: borderRadius,
        child: child,
      );
}
