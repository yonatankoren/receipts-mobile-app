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
import 'package:provider/provider.dart';
import '../models/receipt.dart';
import '../providers/app_state.dart';
import '../utils/constants.dart';

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
  Receipt? _receipt;
  bool _isLoading = true;
  bool _isSaving = false;

  // Controllers for editable fields
  final _merchantController = TextEditingController();
  final _dateController = TextEditingController();
  final _amountController = TextEditingController();
  final _currencyController = TextEditingController();
  String? _selectedCategory;

  /// Whether this screen is in expense-linking mode
  bool get _isExpenseMode => widget.linkedExpenseId != null;

  @override
  void initState() {
    super.initState();
    _loadReceipt();
  }

  @override
  void dispose() {
    _merchantController.dispose();
    _dateController.dispose();
    _amountController.dispose();
    _currencyController.dispose();
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

  void _populateFields(Receipt receipt) {
    _merchantController.text = receipt.merchantName ?? '';
    _dateController.text = receipt.receiptDate ?? '';
    _amountController.text =
        receipt.totalAmount?.toStringAsFixed(2) ?? '';
    _currencyController.text = receipt.currency;
    _selectedCategory = receipt.category;
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

    final appState = context.read<AppState>();
    final receiptAmount = double.tryParse(_amountController.text);

    // --- Duplicate detection (runs before any write) ---
    {
      final tempReceipt = _receipt!.copyWith(
        merchantName: _merchantController.text.isNotEmpty
            ? _merchantController.text
            : null,
        receiptDate: _dateController.text.isNotEmpty
            ? _dateController.text
            : null,
        totalAmount: receiptAmount,
      );

      final duplicate = await appState.checkForDuplicate(tempReceipt);
      if (duplicate != null && mounted) {
        final proceed = await _showDuplicateWarning(duplicate);
        if (proceed != true) return; // User cancelled
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

      final updated = _receipt!.copyWith(
        merchantName: _merchantController.text.isNotEmpty
            ? _merchantController.text
            : null,
        receiptDate: _dateController.text.isNotEmpty
            ? _dateController.text
            : null,
        totalAmount: finalAmount,
        currency: _currencyController.text.isNotEmpty
            ? _currencyController.text
            : 'ILS',
        category: _selectedCategory,
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

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(_isExpenseMode
                ? 'הקבלה צורפה בהצלחה ✓'
                : 'הקבלה נשמרה בהצלחה ✓'),
            backgroundColor: Colors.green,
            duration: const Duration(seconds: 2),
          ),
        );
        // Pop back — in expense mode, go back to the expenses list
        Navigator.of(context).pop();
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('שגיאה בשמירה: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
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
                        Icons.calendar_today, 'תאריך', existing.receiptDate!,
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
    final picked = await showDatePicker(
      context: context,
      initialDate: DateTime.tryParse(_dateController.text) ?? now,
      firstDate: DateTime(2020),
      lastDate: now.add(const Duration(days: 1)),
      locale: const Locale('he', 'IL'),
    );
    if (picked != null) {
      _dateController.text =
          '${picked.year}-${picked.month.toString().padLeft(2, '0')}-${picked.day.toString().padLeft(2, '0')}';
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
            ? const Center(child: CircularProgressIndicator())
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
                  const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
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
            hint: 'YYYY-MM-DD',
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
                child: _buildField(
                  label: 'מטבע',
                  controller: _currencyController,
                  icon: Icons.currency_exchange,
                  confidence: confidences['currency'],
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),

          // Category dropdown
          InputDecorator(
            decoration: InputDecoration(
              labelText: 'קטגוריה',
              prefixIcon: const Icon(Icons.category),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
              ),
              filled: true,
              fillColor: Colors.grey.shade50,
            ),
            child: DropdownButtonHideUnderline(
              child: DropdownButton<String?>(
                value: _selectedCategory,
                isExpanded: true,
                hint: const Text('בחר קטגוריה'),
                items: [
                  const DropdownMenuItem<String?>(
                    value: null,
                    child: Text('ללא'),
                  ),
                  ...AppConstants.categories.map(
                    (cat) => DropdownMenuItem(value: cat, child: Text(cat)),
                  ),
                ],
                onChanged: (val) => setState(() => _selectedCategory = val),
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

  Widget _buildField({
    required String label,
    required TextEditingController controller,
    required IconData icon,
    double? confidence,
    Widget? suffix,
    TextInputType? keyboardType,
    TextInputAction? textInputAction,
    String? hint,
  }) {
    return TextField(
      controller: controller,
      keyboardType: keyboardType,
      textInputAction: textInputAction ?? TextInputAction.next,
      textDirection: TextDirection.rtl,
      decoration: InputDecoration(
        labelText: label,
        hintText: hint,
        prefixIcon: Icon(icon),
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
        child: SizedBox(
          height: 54,
          child: ElevatedButton.icon(
            onPressed: _isSaving ? null : _save,
            icon: _isSaving
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: Colors.white,
                    ),
                  )
                : const Icon(Icons.check, size: 24),
            label: Text(
              _isSaving
                  ? 'שומר...'
                  : (_isExpenseMode ? 'צרף ושמור' : 'שמור קבלה'),
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
        ),
      ),
    );
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
