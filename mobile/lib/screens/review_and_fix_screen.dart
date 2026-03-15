/// Review & Fix Screen — shows extracted receipt fields for review/editing.
///
/// UX requirements:
///   - Large, easy-to-edit fields
///   - One-tap save
///   - Confidence indicators per field
///   - Receipt image preview
///   - If still processing, show loading state
///   - Category dropdown
///   - Must never block with complicated forms
///
/// Expense linking:
///   - When linkedExpenseId is provided, this screen is in "attach receipt" mode
///   - After OCR, compares reportedAmount vs extracted amount
///   - Mismatch → dialog to choose amount or cancel
///   - Cancel cleans up receipt + image without any Drive/Sheets writes

import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import '../db/database_helper.dart';
import '../models/receipt.dart';
import '../providers/app_state.dart';
import '../services/custom_category_service.dart';
import '../services/sync_engine.dart';
import '../widgets/loading_indicator.dart';

class _SlashDateInputFormatter extends TextInputFormatter {
  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    final digits = newValue.text.replaceAll(RegExp(r'[^0-9]'), '');
    final clamped = digits.length > 8 ? digits.substring(0, 8) : digits;

    final buffer = StringBuffer();
    for (int i = 0; i < clamped.length; i++) {
      buffer.write(clamped[i]);
      if ((i == 1 || i == 3) && i != clamped.length - 1) {
        buffer.write('/');
      }
    }

    final text = buffer.toString();
    return TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: text.length),
    );
  }
}

class ReviewAndFixScreen extends StatefulWidget {
  final String receiptId;

  /// When non-null, this screen is in "attach receipt to expense" mode.
  final String? linkedExpenseId;

  /// The amount the user manually reported for the expense.
  final double? reportedAmount;

  const ReviewAndFixScreen({
    super.key,
    required this.receiptId,
    this.linkedExpenseId,
    this.reportedAmount,
  });

  @override
  State<ReviewAndFixScreen> createState() => _ReviewAndFixScreenState();
}

class _ReviewAndFixScreenState extends State<ReviewAndFixScreen> {
  static const List<String> _allowedCurrencies = ['ILS', 'USD', 'EUR'];

  Receipt? _receipt;
  bool _isLoading = true;
  bool _isSaving = false;
  bool _isDeleting = false;

  // Controllers for editable fields
  final _merchantController = TextEditingController();
  final _dateController = TextEditingController();
  final _amountController = TextEditingController();
  String? _selectedCurrency;
  String? _selectedCategory;

  /// Top 3 most-used categories (loaded from DB).
  List<String> _topCategories = [];

  /// Whether this screen is in expense-linking mode
  bool get _isExpenseMode => widget.linkedExpenseId != null;

  @override
  void initState() {
    super.initState();
    _loadTopCategories();
    _loadReceipt();
  }

  Future<void> _loadTopCategories() async {
    final top = await DatabaseHelper.instance.getTopCategories(limit: 3);
    if (mounted) {
      setState(() => _topCategories = top);
    }
  }

  @override
  void dispose() {
    _merchantController.dispose();
    _dateController.dispose();
    _amountController.dispose();
    super.dispose();
  }

  Future<void> _loadReceipt() async {
    final appState = context.read<AppState>();
    final receipt = await appState.refreshReceipt(widget.receiptId);

    if (receipt != null && mounted) {
      _populateFields(receipt);
    }

    setState(() {
      _receipt = receipt;
      _isLoading = false;
    });

    // If not yet processed, poll for updates
    if (receipt != null && receipt.rawOcrText == null) {
      _pollForProcessing();
    }
  }

  /// Convert internal ISO date (YYYY-MM-DD) to display format (dd/mm/yyyy).
  String _isoToDisplay(String isoDate) {
    final dt = DateTime.tryParse(isoDate);
    if (dt == null) return isoDate;
    return '${dt.day.toString().padLeft(2, '0')}/${dt.month.toString().padLeft(2, '0')}/${dt.year}';
  }

  /// Convert display date (dd/mm/yyyy) back to ISO (YYYY-MM-DD) for storage.
  String _displayToIso(String displayDate) {
    final parts = displayDate.split('/');
    if (parts.length != 3) return displayDate;
    final day = parts[0];
    final month = parts[1];
    final year = parts[2];
    return '$year-$month-$day';
  }

  String _normalizeCurrency(String? raw, {String fallback = ''}) {
    var value = (raw ?? '')
        .replaceAll(RegExp(r'[\u200E\u200F\u202A-\u202E\u2066-\u2069\uFEFF]'), '')
        .trim();

    if (value.isEmpty) value = fallback;
    value = value
        .replaceAll(RegExp(r'[\u200E\u200F\u202A-\u202E\u2066-\u2069\uFEFF]'), '')
        .trim()
        .toUpperCase();

    if (value.contains('€') || value.contains('EUR')) return 'EUR';
    if (value == r'$' || value.contains('US\$') || value.contains('USD')) return 'USD';
    if (value.contains('₪') ||
        value.contains('NIS') ||
        value.contains('ILS') ||
        value.contains('ש"ח') ||
        value.contains("ש'ח") ||
        value.contains('שח')) {
      return 'ILS';
    }

    switch (value) {
      case '₪':
      case 'ש"ח':
      case "ש'ח":
      case 'שח':
      case 'NIS':
      case 'N.I.S':
      case 'ILS.':
      case 'ILS':
        return 'ILS';
      case r'$':
      case 'US\$':
      case 'USD':
      case 'USD.':
        return 'USD';
      case '€':
      case 'EUR':
      case 'EUR.':
        return 'EUR';
      default:
        return _allowedCurrencies.contains(value) ? value : '';
    }
  }

  void _populateFields(Receipt receipt) {
    _merchantController.text = receipt.merchantName ?? '';
    _dateController.text = receipt.receiptDate != null
        ? _isoToDisplay(receipt.receiptDate!)
        : '';
    _amountController.text =
        receipt.totalAmount?.toStringAsFixed(2) ?? '';
    final normalizedCurrency = _normalizeCurrency(receipt.currency);
    _selectedCurrency = normalizedCurrency.isNotEmpty ? normalizedCurrency : null;

    final normalizedCategory = receipt.category?.trim();
    _selectedCategory =
      (normalizedCategory != null && normalizedCategory.isNotEmpty)
        ? normalizedCategory
        : 'אחר';
  }

  /// Poll every 2 seconds until processing is complete
  Future<void> _pollForProcessing() async {
    for (int i = 0; i < 30; i++) {
      // Max 60 seconds
      await Future.delayed(const Duration(seconds: 2));
      if (!mounted) return;

      final appState = context.read<AppState>();
      final updated = await appState.refreshReceipt(widget.receiptId);

      if (updated != null && updated.rawOcrText != null) {
        setState(() => _receipt = updated);
        _populateFields(updated);
        return;
      }
    }
  }

  Future<void> _save() async {
    if (_receipt == null || _isSaving) return;

    final finalCurrency = _normalizeCurrency(_selectedCurrency);
    if (finalCurrency.isEmpty) {
      await _showCurrencyRequiredDialog();
      return;
    }

    final appState = context.read<AppState>();
    final receiptAmount = double.tryParse(_amountController.text);

    // --- Duplicate detection (runs before any write) ---
    {
      final isoDate = _dateController.text.isNotEmpty
          ? _displayToIso(_dateController.text)
          : null;
      final tempReceipt = _receipt!.copyWith(
        merchantName: _merchantController.text.isNotEmpty
            ? _merchantController.text
            : null,
        receiptDate: isoDate,
        totalAmount: receiptAmount,
      );

      final duplicate = await appState.checkForDuplicate(tempReceipt);
      if (duplicate != null && mounted) {
        final proceed = await _showDuplicateWarning(duplicate);
        if (proceed != true) {
          // User cancelled — clean up the receipt and go back to home screen
          await appState.cancelExpenseReceipt(widget.receiptId);
          if (mounted) {
            Navigator.of(context).popUntil((route) => route.isFirst);
          }
          return;
        }
      }
    }

    // --- Expense mode: check for amount mismatch ---
    if (_isExpenseMode && widget.reportedAmount != null && receiptAmount != null) {
      final reported = widget.reportedAmount!;
      final diff = (receiptAmount - reported).abs();

      // Mismatch threshold: more than 0.01 difference
      if (diff > 0.01) {
        final chosenAmount = await _showMismatchDialog(reported, receiptAmount);
        if (chosenAmount == null) {
          // User cancelled — do nothing, stay on this screen
          return;
        }
        // Update the amount field with the chosen amount
        _amountController.text = chosenAmount.toStringAsFixed(2);
      }
    }

    setState(() => _isSaving = true);

    try {
      final finalAmount = double.tryParse(_amountController.text);
      final finalIsoDate = _dateController.text.isNotEmpty
          ? _displayToIso(_dateController.text)
          : null;

      final updated = _receipt!.copyWith(
        merchantName: _merchantController.text.isNotEmpty
            ? _merchantController.text
            : null,
        receiptDate: finalIsoDate,
        totalAmount: finalAmount,
        currency: finalCurrency,
        category: (_selectedCategory != null && _selectedCategory!.trim().isNotEmpty)
          ? _selectedCategory!.trim()
          : 'אחר',
        status: ReceiptStatus.reviewed,
      );

      if (_isExpenseMode) {
        // Expense mode: confirm receipt, enqueue sync jobs, delete expense
        await appState.confirmExpenseReceipt(
              receiptId: widget.receiptId,
              expenseId: widget.linkedExpenseId!,
              chosenAmount: finalAmount ?? widget.reportedAmount ?? 0,
            );

        // Also save any edits the user made to other fields
        await appState.saveReview(updated);
      } else {
        // Normal mode
        await appState.saveReview(updated);
      }

      if (!mounted) return;

      // Show loading overlay while remote sync runs
      _showSyncOverlay();

      final syncSuccess = await SyncEngine.instance.awaitReceiptSync(
        widget.receiptId,
        timeout: const Duration(seconds: 60),
      );

      if (!mounted) return;
      Navigator.of(context).pop(); // dismiss sync overlay

      if (syncSuccess) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(_isExpenseMode
                ? 'הקבלה צורפה בהצלחה ✓'
                : 'הקבלה נשמרה בהצלחה ✓'),
            backgroundColor: Colors.green,
            duration: const Duration(seconds: 2),
          ),
        );
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('הקבלה נשמרה במכשיר, הסנכרון יושלם בהמשך'),
            backgroundColor: Colors.orange,
            duration: Duration(seconds: 3),
          ),
        );
      }

      // Pop back — in expense mode, go back to the expenses list
      if (mounted) Navigator.of(context).pop();

    } catch (e) {
      // Dismiss sync overlay if showing
      if (_isSaving && mounted && Navigator.of(context).canPop()) {
        Navigator.of(context).pop();
      }
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('שגיאה בשמירה: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }

  /// Show a loading overlay while waiting for remote sync to complete
  void _showSyncOverlay() {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => PopScope(
        canPop: false,
        child: Center(
          child: Card(
            margin: const EdgeInsets.all(32),
            child: Padding(
              padding: const EdgeInsets.all(32),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const LoadingIndicator(message: 'שומר ומסנכרן את הקבלה…'),
                  const SizedBox(height: 12),
                  Text(
                    'נא לא לצאת מהאפליקציה',
                    textAlign: TextAlign.center,
                    textDirection: TextDirection.rtl,
                    style: TextStyle(
                      fontSize: 13,
                      color: Colors.grey.shade500,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// Show a duplicate receipt warning dialog.
  /// Returns true if user wants to proceed, false/null to cancel.
  Future<bool?> _showDuplicateWarning(Receipt existing) {
    return showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) {
        final theme = Theme.of(dialogContext);
        return AlertDialog(
          title: Row(
            children: [
              Icon(Icons.content_copy, color: Colors.red.shade700, size: 28),
              const SizedBox(width: 8),
              const Expanded(child: Text('קבלה כפולה?')),
            ],
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                'נמצאה קבלה דומה שכבר קיימת במערכת:',
                style: theme.textTheme.bodyMedium,
              ),
              const SizedBox(height: 16),
              Container(
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: Colors.red.shade50,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: Colors.red.shade200),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (existing.merchantName != null)
                      _duplicateInfoRow(
                        Icons.store, 'עסק', existing.merchantName!,
                      ),
                    if (existing.receiptDate != null)
                      _duplicateInfoRow(
                        Icons.calendar_today, 'תאריך', _isoToDisplay(existing.receiptDate!),
                      ),
                    if (existing.totalAmount != null)
                      _duplicateInfoRow(
                        Icons.payments, 'סכום',
                        '₪${existing.totalAmount!.toStringAsFixed(2)}',
                      ),
                  ],
                ),
              ),
              const SizedBox(height: 12),
              Text(
                'האם להמשיך בכל זאת?',
                style: theme.textTheme.bodyMedium?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
          actionsAlignment: MainAxisAlignment.center,
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('ביטול'),
            ),
            ElevatedButton(
              onPressed: () => Navigator.pop(dialogContext, true),
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.orange.shade700,
                foregroundColor: Colors.white,
              ),
              child: const Text('המשך בכל זאת'),
            ),
          ],
        );
      },
    );
  }

  Widget _duplicateInfoRow(IconData icon, String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        children: [
          Icon(icon, size: 16, color: Colors.red.shade400),
          const SizedBox(width: 8),
          Text('$label: ', style: const TextStyle(fontWeight: FontWeight.w600)),
          Expanded(child: Text(value, overflow: TextOverflow.ellipsis)),
        ],
      ),
    );
  }

  /// Show amount mismatch dialog.
  /// Returns the chosen amount, or null if user cancels.
  Future<double?> _showMismatchDialog(double reported, double receiptAmount) {
    return showDialog<double>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) {
        final diff = (receiptAmount - reported).abs();
        final theme = Theme.of(dialogContext);

        return AlertDialog(
          title: Row(
            children: [
              Icon(Icons.warning_amber_rounded, color: Colors.orange.shade700, size: 28),
              const SizedBox(width: 8),
              const Expanded(child: Text('הפרש בסכום')),
            ],
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                'הסכום שדיווחת שונה מהסכום בקבלה',
                style: theme.textTheme.bodyMedium,
              ),
              const SizedBox(height: 16),

              // Reported amount
              Container(
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: Colors.blue.shade50,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: Colors.blue.shade200),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.edit_note, color: Colors.blue),
                    const SizedBox(width: 10),
                    const Expanded(child: Text('הסכום שדיווחת')),
                    Text(
                      '₪${reported.toStringAsFixed(2)}',
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.bold,
                        color: Colors.blue.shade700,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 10),

              // Receipt amount
              Container(
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: Colors.green.shade50,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: Colors.green.shade200),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.receipt, color: Colors.green),
                    const SizedBox(width: 10),
                    const Expanded(child: Text('הסכום בקבלה')),
                    Text(
                      '₪${receiptAmount.toStringAsFixed(2)}',
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.bold,
                        color: Colors.green.shade700,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 10),

              // Difference highlight
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                decoration: BoxDecoration(
                  color: Colors.orange.shade50,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: Colors.orange.shade200),
                ),
                child: Row(
                  children: [
                    Icon(Icons.compare_arrows, color: Colors.orange.shade700),
                    const SizedBox(width: 10),
                    const Expanded(child: Text('הפרש')),
                    Text(
                      '₪${diff.toStringAsFixed(2)}',
                      style: theme.textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.bold,
                        color: Colors.orange.shade700,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          actionsAlignment: MainAxisAlignment.center,
          actions: [
            // Cancel — don't save anything
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, null),
              child: const Text('ביטול'),
            ),
            // Use reported amount
            OutlinedButton(
              onPressed: () => Navigator.pop(dialogContext, reported),
              style: OutlinedButton.styleFrom(foregroundColor: Colors.blue),
              child: Text('₪${reported.toStringAsFixed(2)}'),
            ),
            // Use receipt amount
            ElevatedButton(
              onPressed: () => Navigator.pop(dialogContext, receiptAmount),
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.green.shade600,
                foregroundColor: Colors.white,
              ),
              child: Text('₪${receiptAmount.toStringAsFixed(2)}'),
            ),
          ],
        );
      },
    );
  }

  /// Cancel the expense-receipt attachment — clean up and go back
  Future<void> _cancelExpenseReceipt() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('ביטול צירוף קבלה'),
        content: const Text('הקבלה לא תישמר. ההוצאה תישאר ברשימה. להמשיך?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('חזור'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: const Text('ביטול'),
          ),
        ],
      ),
    );

    if (confirmed == true && mounted) {
      await context.read<AppState>().cancelExpenseReceipt(widget.receiptId);
      if (mounted) Navigator.of(context).pop();
    }
  }

  Future<void> _pickDate() async {
    final now = DateTime.now();
    // Parse from display format (dd/mm/yyyy) for the date picker initial value
    final isoText = _displayToIso(_dateController.text);
    final picked = await showDatePicker(
      context: context,
      initialDate: DateTime.tryParse(isoText) ?? now,
      firstDate: DateTime(2020),
      lastDate: now.add(const Duration(days: 1)),
      locale: const Locale('he', 'IL'),
    );
    if (picked != null) {
      _dateController.text =
          '${picked.day.toString().padLeft(2, '0')}/${picked.month.toString().padLeft(2, '0')}/${picked.year}';
    }
  }

  Color _confidenceColor(double? confidence) {
    if (confidence == null) return Colors.grey;
    if (confidence >= 0.8) return Colors.green;
    if (confidence >= 0.5) return Colors.orange;
    return Colors.red;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return PopScope(
      canPop: !_isExpenseMode,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop && _isExpenseMode) {
          _cancelExpenseReceipt();
        }
      },
      child: Scaffold(
        appBar: AppBar(
          title: Text(_isExpenseMode ? 'צירוף קבלה' : 'סקירת קבלה'),
          leading: _isExpenseMode
              ? IconButton(
                  icon: const Icon(Icons.close),
                  onPressed: _cancelExpenseReceipt,
                )
              : null,
          actions: [
            if (_receipt != null)
              IconButton(
                icon: const Icon(Icons.image),
                onPressed: _showImagePreview,
                tooltip: 'הצג תמונה',
              ),
          ],
        ),
        body: _isLoading
            ? const Center(child: LoadingIndicator(message: 'הקבלה נטענת'))
            : _receipt == null
                ? const Center(child: Text('הקבלה לא נמצאה'))
                : _buildForm(theme),
        bottomNavigationBar: _receipt != null ? _buildSaveBar(theme) : null,
      ),
    );
  }

  Widget _buildForm(ThemeData theme) {
    final isProcessing = _receipt!.rawOcrText == null;
    final confidences = _receipt!.fieldConfidences ?? {};

    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Expense context banner
          if (_isExpenseMode && widget.reportedAmount != null)
            Container(
              padding: const EdgeInsets.all(14),
              margin: const EdgeInsets.only(bottom: 16),
              decoration: BoxDecoration(
                color: Colors.orange.shade50,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: Colors.orange.shade200),
              ),
              child: Row(
                children: [
                  Icon(Icons.pending_actions, color: Colors.orange.shade700, size: 20),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      'סכום מדווח: ₪${widget.reportedAmount!.toStringAsFixed(2)}',
                      style: theme.textTheme.bodyMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                        color: Colors.orange.shade800,
                      ),
                    ),
                  ),
                ],
              ),
            ),

          // Processing indicator
          if (isProcessing)
            Container(
              padding: const EdgeInsets.all(16),
              margin: const EdgeInsets.only(bottom: 16),
              decoration: BoxDecoration(
                color: Colors.blue.shade50,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: Colors.blue.shade200),
              ),
              child: Row(
                children: [
                  const LoadingIndicator(compact: true, size: 16),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      'מעבד את הקבלה... תוכל לערוך ידנית או לחכות לתוצאות',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: Colors.blue.shade700,
                      ),
                    ),
                  ),
                ],
              ),
            ),

          // Overall confidence
          if (_receipt!.overallConfidence != null)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              margin: const EdgeInsets.only(bottom: 16),
              decoration: BoxDecoration(
                color: _confidenceColor(_receipt!.overallConfidence).withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Row(
                children: [
                  Icon(
                    _receipt!.overallConfidence! >= 0.8
                        ? Icons.check_circle
                        : Icons.info_outline,
                    color: _confidenceColor(_receipt!.overallConfidence),
                    size: 20,
                  ),
                  const SizedBox(width: 8),
                  Text(
                    'ביטחון כללי: ${(_receipt!.overallConfidence! * 100).toStringAsFixed(0)}%',
                    style: theme.textTheme.bodyMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                      color: _confidenceColor(_receipt!.overallConfidence),
                    ),
                  ),
                ],
              ),
            ),

          // Receipt image thumbnail
          GestureDetector(
            onTap: _showImagePreview,
            child: Container(
              height: 120,
              margin: const EdgeInsets.only(bottom: 20),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(12),
                color: Colors.grey.shade100,
              ),
              clipBehavior: Clip.antiAlias,
              child: File(_receipt!.imagePath).existsSync()
                  ? Image.file(
                      File(_receipt!.imagePath),
                      fit: BoxFit.cover,
                      width: double.infinity,
                    )
                  : const Center(
                      child: Icon(Icons.image_not_supported, size: 48),
                    ),
            ),
          ),

          // Merchant Name
          _buildField(
            label: 'שם עסק',
            controller: _merchantController,
            icon: Icons.store,
            confidence: confidences['merchant_name'],
            textInputAction: TextInputAction.next,
          ),
          const SizedBox(height: 16),

          // Receipt Date
          _buildField(
            label: 'תאריך קבלה',
            controller: _dateController,
            icon: Icons.calendar_today,
            confidence: confidences['receipt_date'],
            suffix: IconButton(
              icon: const Icon(Icons.edit_calendar),
              onPressed: _pickDate,
            ),
            keyboardType: TextInputType.datetime,
            hint: 'dd/mm/yyyy',
            inputFormatters: [
              _SlashDateInputFormatter(),
            ],
          ),
          const SizedBox(height: 16),

          // Total Amount + Currency (side by side)
          Row(
            children: [
              Expanded(
                flex: 2,
                child: _buildField(
                  label: 'סכום',
                  controller: _amountController,
                  icon: Icons.payments,
                  confidence: confidences['total_amount'],
                  keyboardType:
                      const TextInputType.numberWithOptions(decimal: true),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _buildCurrencyDropdown(
                  confidence: confidences['currency'],
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),

          // Category picker — tap to open bottom sheet
          GestureDetector(
            onTap: _showCategoryPicker,
            child: InputDecorator(
              decoration: InputDecoration(
                labelText: 'קטגוריה',
                prefixIcon: const Icon(Icons.category),
                suffixIcon: const Icon(Icons.arrow_drop_down),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
                filled: true,
                fillColor: Colors.grey.shade50,
              ),
              child: Text(
                _selectedCategory ?? 'בחר קטגוריה',
                style: TextStyle(
                  fontSize: 18,
                  color: _selectedCategory != null
                      ? Colors.black87
                      : Colors.grey.shade500,
                ),
              ),
            ),
          ),
          const SizedBox(height: 16),

          // Status badge
          _buildStatusBadge(),
          const SizedBox(height: 80), // Space for bottom bar
        ],
      ),
    );
  }

  /// Show a bottom-sheet category picker.
  /// Layout: top 3 (★) → divider → all categories → divider → הוסף קטגוריה.
  /// Custom categories show a small edit icon for renaming.
  void _showCategoryPicker() {
    final svc = CustomCategoryService.instance;
    final all = svc.allCategories;

    final topCats = _topCategories
        .where((c) => all.contains(c))
        .take(3)
        .toList();

    final hasOrphan = _selectedCategory != null && !all.contains(_selectedCategory);

    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) {
        return DraggableScrollableSheet(
          initialChildSize: 0.55,
          minChildSize: 0.3,
          maxChildSize: 0.85,
          expand: false,
          builder: (_, scrollController) {
            return Column(
              children: [
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 10),
                  child: Container(
                    width: 40,
                    height: 4,
                    decoration: BoxDecoration(
                      color: Colors.grey.shade400,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
                const Text('בחר קטגוריה',
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
                const SizedBox(height: 8),
                Expanded(
                  child: ListView(
                    controller: scrollController,
                    children: [
                      if (hasOrphan)
                        _categoryTile(_selectedCategory, _selectedCategory!,
                            isSelected: true, italic: true),

                      if (topCats.isNotEmpty) ...[
                        const Padding(
                          padding: EdgeInsets.only(right: 16, top: 8, bottom: 4),
                          child: Text('נפוצות',
                              style: TextStyle(
                                  fontSize: 13,
                                  color: Colors.grey,
                                  fontWeight: FontWeight.w500)),
                        ),
                        ...topCats.map((cat) => _categoryTile(cat, cat,
                            isSelected: _selectedCategory == cat, star: true)),
                        const Divider(height: 16),
                      ],

                      const Padding(
                        padding: EdgeInsets.only(right: 16, top: 4, bottom: 4),
                        child: Text('כל הקטגוריות',
                            style: TextStyle(
                                fontSize: 13,
                                color: Colors.grey,
                                fontWeight: FontWeight.w500)),
                      ),
                      ...all.map((cat) {
                        final isCustom = svc.customCategories.contains(cat);
                        return _categoryTile(
                          cat,
                          cat,
                          isSelected: _selectedCategory == cat,
                          onEdit: isCustom
                              ? () {
                                  Navigator.pop(ctx);
                                  _showRenameCategoryDialog(cat);
                                }
                              : null,
                        );
                      }),

                      const Divider(height: 16),
                      ListTile(
                        dense: true,
                        leading: Icon(Icons.add_rounded,
                            color: Colors.blue.shade700, size: 22),
                        title: Text('הוסף קטגוריה',
                            style: TextStyle(
                                fontSize: 16,
                                color: Colors.blue.shade700,
                                fontWeight: FontWeight.w600)),
                        onTap: () {
                          Navigator.pop(ctx);
                          _showAddCategoryDialog();
                        },
                      ),
                    ],
                  ),
                ),
              ],
            );
          },
        );
      },
    );
  }

  Widget _categoryTile(String? value, String label,
      {bool isSelected = false,
      bool star = false,
      bool italic = false,
      VoidCallback? onEdit}) {
    return ListTile(
      dense: true,
      selected: isSelected,
      selectedTileColor: Colors.blue.shade50,
      leading: star
          ? Icon(Icons.star_rounded, size: 18, color: Colors.amber.shade700)
          : null,
      title: Text(
        label,
        style: TextStyle(
          fontSize: 16,
          fontStyle: italic ? FontStyle.italic : FontStyle.normal,
          fontWeight: isSelected ? FontWeight.w600 : FontWeight.normal,
        ),
      ),
      trailing: (onEdit != null || isSelected)
          ? Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (onEdit != null)
                  GestureDetector(
                    onTap: onEdit,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      child: Icon(Icons.edit_outlined,
                          size: 18, color: Colors.grey.shade500),
                    ),
                  ),
                if (isSelected)
                  Icon(Icons.check_rounded,
                      color: Colors.blue.shade700, size: 20),
              ],
            )
          : null,
      onTap: () {
        setState(() => _selectedCategory = value);
        Navigator.pop(context);
      },
    );
  }

  // ──────────────── Add / Rename category dialogs ────────────────

  void _showAddCategoryDialog() {
    final controller = TextEditingController();
    String? errorText;

    showDialog(
      context: context,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setDialogState) {
            return AlertDialog(
              title: const Text('הוסף קטגוריה', textAlign: TextAlign.center),
              content: TextField(
                controller: controller,
                autofocus: true,
                textDirection: TextDirection.rtl,
                maxLength: CustomCategoryService.maxNameLength,
                decoration: InputDecoration(
                  hintText: 'שם הקטגוריה',
                  errorText: errorText,
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(ctx),
                  child: const Text('ביטול'),
                ),
                ElevatedButton(
                  onPressed: () async {
                    try {
                      await CustomCategoryService.instance
                          .addCategory(controller.text);
                      if (!ctx.mounted) return;
                      Navigator.pop(ctx);
                      setState(() {
                        _selectedCategory = controller.text.trim();
                      });
                    } on ArgumentError catch (e) {
                      setDialogState(
                          () => errorText = e.message as String?);
                    }
                  },
                  child: const Text('הוסף'),
                ),
              ],
            );
          },
        );
      },
    );
  }

  void _showRenameCategoryDialog(String oldName) {
    final controller = TextEditingController(text: oldName);
    String? errorText;
    bool isRenaming = false;

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setDialogState) {
            return AlertDialog(
              title: const Text('שנה שם קטגוריה', textAlign: TextAlign.center),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextField(
                    controller: controller,
                    autofocus: true,
                    textDirection: TextDirection.rtl,
                    maxLength: CustomCategoryService.maxNameLength,
                    enabled: !isRenaming,
                    decoration: InputDecoration(
                      hintText: 'שם חדש',
                      errorText: errorText,
                    ),
                  ),
                  if (isRenaming) ...[
                    const SizedBox(height: 12),
                    const Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        LoadingIndicator(compact: true, size: 16),
                        SizedBox(width: 10),
                        Text('מעדכן...', style: TextStyle(fontSize: 13)),
                      ],
                    ),
                  ],
                ],
              ),
              actions: [
                TextButton(
                  onPressed: isRenaming ? null : () => Navigator.pop(ctx),
                  child: const Text('ביטול'),
                ),
                ElevatedButton(
                  onPressed: isRenaming
                      ? null
                      : () async {
                          setDialogState(() {
                            errorText = null;
                            isRenaming = true;
                          });
                          try {
                            await CustomCategoryService.instance
                                .renameCategory(oldName, controller.text);
                            if (!ctx.mounted) return;
                            Navigator.pop(ctx);
                            // Refresh the in-memory receipts
                            if (mounted) {
                              final appState = context.read<AppState>();
                              await appState.loadReceipts();
                              setState(() {
                                if (_selectedCategory == oldName) {
                                  _selectedCategory = controller.text.trim();
                                }
                              });
                            }
                          } on ArgumentError catch (e) {
                            setDialogState(() {
                              errorText = e.message as String?;
                              isRenaming = false;
                            });
                          } catch (e) {
                            setDialogState(() {
                              errorText = 'שגיאה: $e';
                              isRenaming = false;
                            });
                          }
                        },
                  child: const Text('שמור'),
                ),
              ],
            );
          },
        );
      },
    );
  }

  Widget _buildField({
    required String label,
    required TextEditingController controller,
    required IconData icon,
    double? confidence,
    Widget? suffix,
    TextInputType? keyboardType,
    TextInputAction? textInputAction,
    String? hint,
    List<TextInputFormatter>? inputFormatters,
    TextDirection? textDirection,
    TextAlign? textAlign,
    bool showPrefixIcon = true,
  }) {
    return TextField(
      controller: controller,
      keyboardType: keyboardType,
      textInputAction: textInputAction ?? TextInputAction.next,
      textDirection: textDirection ?? TextDirection.rtl,
      textAlign: textAlign ?? TextAlign.right,
      inputFormatters: inputFormatters,
      decoration: InputDecoration(
        labelText: label,
        hintText: hint,
        prefixIcon: showPrefixIcon ? Icon(icon) : null,
        suffixIcon: suffix ??
            (confidence != null
                ? Padding(
                    padding: const EdgeInsets.all(12),
                    child: Container(
                      width: 12,
                      height: 12,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: _confidenceColor(confidence),
                      ),
                    ),
                  )
                : null),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
        ),
        filled: true,
        fillColor: Colors.grey.shade50,
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 16, vertical: 18),
      ),
      style: const TextStyle(fontSize: 18),
    );
  }

  Future<void> _showCurrencyRequiredDialog() {
    return showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Currency required'),
        content: const Text('please choose currency'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('OK'),
          ),
        ],
      ),
    );
  }

  Widget _buildCurrencyDropdown({double? confidence}) {
    confidence;
    return Directionality(
      textDirection: TextDirection.ltr,
      child: DropdownButtonFormField<String>(
        value: _selectedCurrency,
        items: _allowedCurrencies
            .map(
              (currency) => DropdownMenuItem<String>(
                value: currency,
                child: Text(currency, style: const TextStyle(fontSize: 15)),
              ),
            )
            .toList(),
        onChanged: (value) {
          setState(() {
            _selectedCurrency = value;
          });
        },
        isExpanded: true,
        decoration: InputDecoration(
          labelText: 'מטבע',
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
          ),
          filled: true,
          fillColor: Colors.grey.shade50,
          contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 14),
        ),
        style: const TextStyle(fontSize: 15, color: Colors.black87),
        dropdownColor: Colors.white,
      ),
    );
  }

  Widget _buildStatusBadge() {
    final status = _receipt!.status;
    final (String label, Color color, IconData icon) = switch (status) {
      ReceiptStatus.captured => ('צולם', Colors.grey, Icons.camera_alt),
      ReceiptStatus.processing => ('מעבד', Colors.blue, Icons.sync),
      ReceiptStatus.reviewed => ('נבדק', Colors.orange, Icons.check),
      ReceiptStatus.synced => ('מסונכרן', Colors.green, Icons.cloud_done),
      ReceiptStatus.error => ('שגיאה', Colors.red, Icons.error),
    };

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withValues(alpha: 0.3)),
      ),
      child: Row(
        children: [
          Icon(icon, color: color, size: 20),
          const SizedBox(width: 8),
          Text(
            'סטטוס: $label',
            style: TextStyle(color: color, fontWeight: FontWeight.w600),
          ),
          const Spacer(),
          Text(
            'ID: ${_receipt!.id.substring(0, 8)}…',
            style: TextStyle(color: Colors.grey.shade500, fontSize: 12),
          ),
        ],
      ),
    );
  }

  Widget _buildSaveBar(ThemeData theme) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: theme.scaffoldBackgroundColor,
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.1),
            blurRadius: 8,
            offset: const Offset(0, -2),
          ),
        ],
      ),
      child: SafeArea(
        child: _isExpenseMode
            ? _buildSaveButton()
            : _buildStandardButtons(),
      ),
    );
  }

  /// Expense-linking mode: only save button
  Widget _buildSaveButton() {
    return SizedBox(
      height: 54,
      child: ElevatedButton.icon(
        onPressed: _isSaving ? null : _save,
        icon: _isSaving
            ? const LoadingIndicator(
                compact: true,
                size: 20,
                color: Colors.white,
              )
            : const Icon(Icons.check, size: 24),
        label: Text(
          _isSaving ? 'שומר...' : 'צרף ושמור',
          style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
        ),
        style: ElevatedButton.styleFrom(
          backgroundColor: Colors.green.shade600,
          foregroundColor: Colors.white,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
          ),
        ),
      ),
    );
  }

  /// Standard receipt view: show save (for un-synced) + delete
  Widget _buildStandardButtons() {
    final isSynced = _receipt!.status == ReceiptStatus.synced;

    return SizedBox(
      height: 54,
      child: Row(
        children: [
          // Delete button — always shown
          Expanded(
            child: ElevatedButton.icon(
              onPressed: (_isDeleting || _isSaving)
                  ? null
                  : _confirmDelete,
              icon: _isDeleting
                  ? const LoadingIndicator(
                      compact: true,
                      size: 16,
                      color: Colors.white,
                    )
                  : const Icon(Icons.delete_outline, size: 20),
              label: Text(
                _isDeleting ? 'מוחק...' : 'מחק קבלה',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                    fontSize: 15, fontWeight: FontWeight.w600),
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
          // Save button — only for un-synced receipts
          if (!isSynced) ...[
            const SizedBox(width: 12),
            Expanded(
              child: ElevatedButton.icon(
                onPressed: _isSaving ? null : _save,
                icon: _isSaving
                    ? const LoadingIndicator(
                        compact: true,
                        size: 16,
                        color: Colors.white,
                      )
                    : const Icon(Icons.check, size: 20),
                label: Text(
                  _isSaving ? 'שומר...' : 'שמור קבלה',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                      fontSize: 15, fontWeight: FontWeight.w600),
                ),
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.green.shade600,
                  foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14),
                  ),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  /// Show confirmation dialog before deleting a receipt.
  Future<void> _confirmDelete() async {
    final proceed = await showDialog<bool>(
      context: context,
      builder: (ctx) => Directionality(
        textDirection: TextDirection.rtl,
        child: AlertDialog(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
          title: Row(
            children: [
              Icon(Icons.warning_amber_rounded,
                  color: Colors.red.shade600, size: 28),
              const SizedBox(width: 8),
              const Text('מחיקת קבלה'),
            ],
          ),
          content: const Text(
            'הקבלה תימחק לצמיתות מהאפליקציה, מהגיליון ב-Google Sheets ומתיקיית הקבלות ב-Google Drive.\n\n'
            'לא ניתן לשחזר את המידע לאחר המחיקה.',
            style: TextStyle(fontSize: 16, height: 1.5),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text(
                'ביטול',
                style: TextStyle(
                  fontSize: 16,
                  color: Colors.grey.shade700,
                ),
              ),
            ),
            ElevatedButton.icon(
              onPressed: () => Navigator.pop(ctx, true),
              icon: const Icon(Icons.delete_outline, size: 20),
              label: const Text('מחק'),
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

    setState(() => _isDeleting = true);
    try {
      final appState = context.read<AppState>();
      await appState.deleteReceiptFully(_receipt!.id);

      if (!mounted) return;

      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('הקבלה נמחקה בהצלחה'),
          backgroundColor: Colors.green,
        ),
      );
      Navigator.pop(context); // Go back to the list
    } catch (e) {
      if (!mounted) return;
      setState(() => _isDeleting = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('שגיאה במחיקה: $e'),
          backgroundColor: Colors.red,
        ),
      );
    }
  }

  void _showImagePreview() {
    if (_receipt == null) return;
    showDialog(
      context: context,
      builder: (context) => Dialog(
        child: InteractiveViewer(
          child: Image.file(File(_receipt!.imagePath)),
        ),
      ),
    );
  }
}
