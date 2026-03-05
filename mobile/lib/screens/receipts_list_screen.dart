/// Receipts List Screen — grouped by month.
///
/// Shows:
///   - Month sections with receipt count + pending sync count
///   - Receipt cards with status indicators
///   - "Open in Drive" action per month
///   - Navigation to review screen for each receipt

import 'dart:io';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../models/receipt.dart';
import '../providers/app_state.dart';
import '../services/drive_service.dart';
import '../widgets/sync_status_indicator.dart';
import 'review_and_fix_screen.dart';
import 'package:url_launcher/url_launcher.dart';

class ReceiptsListScreen extends StatefulWidget {
  const ReceiptsListScreen({super.key});

  @override
  State<ReceiptsListScreen> createState() => _ReceiptsListScreenState();
}

class _ReceiptsListScreenState extends State<ReceiptsListScreen> {
  @override
  void initState() {
    super.initState();
    context.read<AppState>().loadReceipts();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: const Text('הקבלות שלי'),
        actions: const [
          SyncStatusIndicator(),
          SizedBox(width: 12),
        ],
      ),
      body: Consumer<AppState>(
        builder: (context, appState, _) {
          if (appState.isLoading && appState.receipts.isEmpty) {
            return const Center(child: CircularProgressIndicator());
          }

          final byMonth = appState.receiptsByMonth;

          if (byMonth.isEmpty) {
            return Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.receipt_long, size: 80, color: Colors.grey.shade300),
                  const SizedBox(height: 16),
                  Text(
                    'עדיין אין קבלות',
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

          return RefreshIndicator(
            onRefresh: () => appState.loadReceipts(),
            child: ListView.builder(
              padding: const EdgeInsets.only(bottom: 16),
              itemCount: byMonth.length,
              itemBuilder: (context, index) {
                final month = byMonth.keys.elementAt(index);
                final receipts = byMonth[month]!;
                return _buildMonthSection(context, month, receipts, theme);
              },
            ),
          );
        },
      ),
    );
  }

  Widget _buildMonthSection(
    BuildContext context,
    String monthKey,
    List<Receipt> receipts,
    ThemeData theme,
  ) {
    final pendingCount =
        receipts.where((r) => !r.isFullySynced).length;
    final monthLabel = _formatMonthLabel(monthKey);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Month header
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          margin: const EdgeInsets.only(top: 8),
          color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
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
              if (pendingCount > 0) ...[
                const SizedBox(width: 6),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                  decoration: BoxDecoration(
                    color: Colors.orange.withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Text(
                    '$pendingCount ממתינים',
                    style: const TextStyle(
                      color: Colors.orange,
                      fontWeight: FontWeight.w600,
                      fontSize: 12,
                    ),
                  ),
                ),
              ],
              const Spacer(),
              // Open in Drive action
              IconButton(
                icon: Icon(Icons.open_in_new,
                    size: 20, color: theme.colorScheme.primary),
                tooltip: 'פתח בדרייב',
                onPressed: () => _openDriveFolder(monthKey),
              ),
            ],
          ),
        ),

        // Receipt cards
        ...receipts.map(
          (r) => _buildReceiptCard(context, r, theme),
        ),
      ],
    );
  }

  Widget _buildReceiptCard(
    BuildContext context,
    Receipt receipt,
    ThemeData theme,
  ) {
    final statusColor = _statusColor(receipt.status);

    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () => Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => ReviewAndFixScreen(receiptId: receipt.id),
          ),
        ),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            children: [
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
                          child: const Icon(Icons.receipt, color: Colors.grey),
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
                          receipt.receiptDate ?? _formatTimestamp(receipt.captureTimestamp),
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
      // Hebrew month name
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
            const SnackBar(content: Text('תיקיית החודש עדיין לא נוצרה בדרייב')),
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

