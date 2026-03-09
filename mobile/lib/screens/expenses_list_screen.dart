/// Expenses List Screen — pending expenses without receipts.
///
/// Features:
///   - List of expenses sorted by date (descending)
///   - Each item shows name + date; tap for details
///   - FAB to add new expense
///   - "Attach receipt" action from detail bottom sheet
///   - All Hebrew UI

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:camera/camera.dart';
import 'package:image_picker/image_picker.dart';
import '../models/expense.dart';
import '../models/receipt_validation_exception.dart';
import '../providers/app_state.dart';
import 'review_and_fix_screen.dart';
import '../widgets/loading_indicator.dart';

class ExpensesListScreen extends StatefulWidget {
  const ExpensesListScreen({super.key});

  @override
  State<ExpensesListScreen> createState() => _ExpensesListScreenState();
}

class _ExpensesListScreenState extends State<ExpensesListScreen> {
  @override
  void initState() {
    super.initState();
    context.read<AppState>().loadExpenses();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: const Text('הוצאות ממתינות'),
      ),
      body: Consumer<AppState>(
        builder: (context, appState, _) {
          final expenses = appState.expenses;

          if (expenses.isEmpty) {
            return Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.receipt_long, size: 80, color: Colors.grey.shade300),
                  const SizedBox(height: 16),
                  Text(
                    'אין הוצאות ממתינות',
                    style: theme.textTheme.titleLarge?.copyWith(
                      color: Colors.grey.shade500,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'הוסף הוצאה שתשלם ללא קבלה',
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: Colors.grey.shade400,
                    ),
                  ),
                ],
              ),
            );
          }

          return ListView.builder(
            padding: const EdgeInsets.only(top: 8, bottom: 80),
            itemCount: expenses.length,
            itemBuilder: (context, index) {
              return _buildExpenseCard(context, expenses[index], theme);
            },
          );
        },
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _showAddExpenseDialog(context),
        icon: const Icon(Icons.add),
        label: const Text('הוספת הוצאה'),
      ),
    );
  }

  Widget _buildExpenseCard(
    BuildContext context,
    Expense expense,
    ThemeData theme,
  ) {
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () => _showExpenseDetail(context, expense),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              // Icon
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  color: Colors.orange.shade50,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(
                  Icons.pending_actions,
                  color: Colors.orange.shade700,
                  size: 24,
                ),
              ),
              const SizedBox(width: 12),

              // Name + date
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      expense.name,
                      style: theme.textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 4),
                    Text(
                      _formatDate(expense.date),
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: Colors.grey.shade600,
                      ),
                    ),
                  ],
                ),
              ),

              // Amount
              Text(
                '₪${expense.amount.toStringAsFixed(2)}',
                style: theme.textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.w600,
                  color: theme.colorScheme.primary,
                ),
              ),

              const SizedBox(width: 4),
              Icon(Icons.chevron_left, color: Colors.grey.shade400, size: 20),
            ],
          ),
        ),
      ),
    );
  }

  void _showExpenseDetail(BuildContext context, Expense expense) {
    final theme = Theme.of(context);

    showModalBottomSheet(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (sheetContext) {
        return Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Handle
              Center(
                child: Container(
                  width: 40,
                  height: 4,
                  decoration: BoxDecoration(
                    color: Colors.grey.shade300,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              const SizedBox(height: 20),

              // Title
              Text(
                expense.name,
                style: theme.textTheme.titleLarge?.copyWith(
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 16),

              // Details
              _buildDetailRow(theme, 'תאריך', _formatDate(expense.date), Icons.calendar_today),
              const SizedBox(height: 10),
              _buildDetailRow(theme, 'סכום', '₪${expense.amount.toStringAsFixed(2)}', Icons.payments),
              const SizedBox(height: 10),
              _buildDetailRow(theme, 'שולם ל', expense.paidTo, Icons.store),
              const SizedBox(height: 24),

              // Attach receipt button
              SizedBox(
                height: 52,
                child: ElevatedButton.icon(
                  onPressed: () {
                    Navigator.pop(sheetContext); // Close bottom sheet
                    _attachReceipt(context, expense);
                  },
                  icon: const Icon(Icons.camera_alt, size: 22),
                  label: const Text(
                    'צרף קבלה',
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
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
              const SizedBox(height: 12),

              // Delete expense button
              SizedBox(
                height: 44,
                child: OutlinedButton.icon(
                  onPressed: () {
                    Navigator.pop(sheetContext);
                    _confirmDeleteExpense(context, expense);
                  },
                  icon: const Icon(Icons.delete_outline, size: 20),
                  label: const Text('מחק הוצאה'),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: Colors.red,
                    side: const BorderSide(color: Colors.red),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 16),
            ],
          ),
        );
      },
    );
  }

  Widget _buildDetailRow(ThemeData theme, String label, String value, IconData icon) {
    return Row(
      children: [
        Icon(icon, size: 20, color: theme.colorScheme.primary),
        const SizedBox(width: 10),
        Text(
          '$label: ',
          style: theme.textTheme.bodyMedium?.copyWith(
            color: Colors.grey.shade600,
          ),
        ),
        Expanded(
          child: Text(
            value,
            style: theme.textTheme.bodyMedium?.copyWith(
              fontWeight: FontWeight.w600,
            ),
            textAlign: TextAlign.start,
          ),
        ),
      ],
    );
  }

  void _confirmDeleteExpense(BuildContext context, Expense expense) {
    showDialog(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('מחיקת הוצאה'),
        content: Text('למחוק את "${expense.name}"?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('ביטול'),
          ),
          TextButton(
            onPressed: () {
              Navigator.pop(dialogContext);
              context.read<AppState>().deleteExpense(expense.id);
            },
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: const Text('מחק'),
          ),
        ],
      ),
    );
  }

  /// Open camera to attach a receipt to this expense
  Future<void> _attachReceipt(BuildContext context, Expense expense) async {
    // Capture context-dependent objects before any async gaps
    final appState = context.read<AppState>();
    final navigator = Navigator.of(context);
    final messenger = ScaffoldMessenger.of(context);

    // Show capture options: camera or gallery
    final source = await showModalBottomSheet<String>(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Center(
              child: Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: Colors.grey.shade300,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            const SizedBox(height: 20),
            Text(
              'צרף קבלה ל"${expense.name}"',
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
            ),
            const SizedBox(height: 16),
            ListTile(
              leading: const Icon(Icons.camera_alt),
              title: const Text('צלם קבלה'),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              onTap: () => Navigator.pop(ctx, 'camera'),
            ),
            ListTile(
              leading: const Icon(Icons.photo_library),
              title: const Text('בחר מהגלריה'),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              onTap: () => Navigator.pop(ctx, 'gallery'),
            ),
            const SizedBox(height: 16),
          ],
        ),
      ),
    );

    if (source == null || !mounted) return;

    String? imagePath;

    if (source == 'camera') {
      imagePath = await _captureFromCamera();
    } else {
      final picker = ImagePicker();
      final picked = await picker.pickImage(
        source: ImageSource.gallery,
        imageQuality: 90,
      );
      imagePath = picked?.path;
    }

    if (imagePath == null || !mounted) return;

    // Show processing overlay
    _showProcessingOverlay();

    try {
      // Capture receipt WITHOUT enqueuing sync jobs
      final receipt = await appState.captureReceiptForExpense(imagePath);

      // Process immediately (OCR + LLM)
      final processed = await appState.processReceiptNow(receipt.id);

      if (!mounted) return;

      // Dismiss overlay
      navigator.pop();

      // Navigate to review screen with expense context
      navigator.push(
        MaterialPageRoute(
          builder: (_) => ReviewAndFixScreen(
            receiptId: processed?.id ?? receipt.id,
            linkedExpenseId: expense.id,
            reportedAmount: expense.amount,
          ),
        ),
      );
    } on ReceiptValidationException catch (e) {
      if (mounted) {
        navigator.pop(); // Dismiss overlay
        _showValidationFailureDialog(e, expense);
      }
    } catch (e) {
      if (mounted) {
        navigator.pop(); // Dismiss overlay
        messenger.showSnackBar(
          SnackBar(content: Text('שגיאה: $e')),
        );
      }
    }
  }

  /// Show a user-friendly dialog when the backend rejects the image.
  void _showValidationFailureDialog(
    ReceiptValidationException error,
    Expense expense,
  ) {
    final IconData icon;
    final Color iconColor;

    switch (error.reason) {
      case 'blurry_image':
        icon = Icons.blur_on;
        iconColor = Colors.orange;
        break;
      case 'image_too_dark':
        icon = Icons.brightness_low;
        iconColor = Colors.blueGrey;
        break;
      case 'image_too_small':
        icon = Icons.photo_size_select_small;
        iconColor = Colors.red;
        break;
      case 'non_receipt_image':
        icon = Icons.receipt_long;
        iconColor = Colors.red;
        break;
      default:
        icon = Icons.error_outline;
        iconColor = Colors.orange;
    }

    showDialog(
      context: context,
      barrierDismissible: true,
      builder: (dialogContext) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 8),
            Container(
              width: 72,
              height: 72,
              decoration: BoxDecoration(
                color: iconColor.withValues(alpha: 0.1),
                shape: BoxShape.circle,
              ),
              child: Icon(icon, color: iconColor, size: 40),
            ),
            const SizedBox(height: 20),
            Text(
              error.messageHe,
              textAlign: TextAlign.center,
              textDirection: TextDirection.rtl,
              style: const TextStyle(
                fontSize: 17,
                fontWeight: FontWeight.w500,
                height: 1.5,
              ),
            ),
            const SizedBox(height: 8),
          ],
        ),
        actionsAlignment: MainAxisAlignment.center,
        actions: [
          ElevatedButton.icon(
            onPressed: () {
              Navigator.pop(dialogContext);
              // Re-open the attach receipt flow
              _attachReceipt(context, expense);
            },
            icon: const Icon(Icons.camera_alt, size: 20),
            label: const Text('צלם שוב'),
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.green.shade600,
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// Capture a photo using the device camera
  Future<String?> _captureFromCamera() async {
    try {
      final cameras = await availableCameras();
      if (cameras.isEmpty) return null;

      final backCamera = cameras.firstWhere(
        (c) => c.lensDirection == CameraLensDirection.back,
        orElse: () => cameras.first,
      );

      final controller = CameraController(
        backCamera,
        ResolutionPreset.high,
        enableAudio: false,
        imageFormatGroup: ImageFormatGroup.jpeg,
      );

      await controller.initialize();

      if (!mounted) {
        controller.dispose();
        return null;
      }

      // Use ImagePicker for simpler camera capture in this context
      controller.dispose();

      final picker = ImagePicker();
      final picked = await picker.pickImage(
        source: ImageSource.camera,
        imageQuality: 90,
      );
      return picked?.path;
    } catch (e) {
      // Fallback to ImagePicker
      final picker = ImagePicker();
      final picked = await picker.pickImage(
        source: ImageSource.camera,
        imageQuality: 90,
      );
      return picked?.path;
    }
  }

  void _showProcessingOverlay() {
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
                  const LoadingIndicator(message: 'שומר ומנתח את הקבלה'),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  void _showAddExpenseDialog(BuildContext context) {
    final nameController = TextEditingController();
    final amountController = TextEditingController();
    final paidToController = TextEditingController();
    String selectedDate = _todayIso();

    showDialog(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (ctx, setDialogState) {
          return AlertDialog(
            title: const Text('הוצאה חדשה'),
            content: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextField(
                    controller: nameController,
                    textDirection: TextDirection.rtl,
                    decoration: InputDecoration(
                      labelText: 'תיאור ההוצאה',
                      prefixIcon: const Icon(Icons.description),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                    textInputAction: TextInputAction.next,
                  ),
                  const SizedBox(height: 12),
                  InkWell(
                    onTap: () async {
                      final picked = await showDatePicker(
                        context: ctx,
                        initialDate: DateTime.tryParse(selectedDate) ?? DateTime.now(),
                        firstDate: DateTime(2020),
                        lastDate: DateTime.now().add(const Duration(days: 1)),
                        locale: const Locale('he', 'IL'),
                      );
                      if (picked != null) {
                        setDialogState(() {
                          selectedDate =
                              '${picked.year}-${picked.month.toString().padLeft(2, '0')}-${picked.day.toString().padLeft(2, '0')}';
                        });
                      }
                    },
                    child: InputDecorator(
                      decoration: InputDecoration(
                        labelText: 'תאריך',
                        prefixIcon: const Icon(Icons.calendar_today),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                      child: Text(_formatDate(selectedDate)),
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: amountController,
                    keyboardType:
                        const TextInputType.numberWithOptions(decimal: true),
                    decoration: InputDecoration(
                      labelText: 'סכום (₪)',
                      prefixIcon: const Icon(Icons.payments),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                    textInputAction: TextInputAction.next,
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: paidToController,
                    textDirection: TextDirection.rtl,
                    decoration: InputDecoration(
                      labelText: 'שולם ל',
                      prefixIcon: const Icon(Icons.store),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                    textInputAction: TextInputAction.done,
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialogContext),
                child: const Text('ביטול'),
              ),
              ElevatedButton(
                onPressed: () {
                  final name = nameController.text.trim();
                  final amountText = amountController.text.trim();
                  final paidTo = paidToController.text.trim();
                  final amount = double.tryParse(amountText);

                  if (name.isEmpty || amount == null || paidTo.isEmpty) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('יש למלא את כל השדות')),
                    );
                    return;
                  }

                  context.read<AppState>().addExpense(
                        name: name,
                        date: selectedDate,
                        amount: amount,
                        paidTo: paidTo,
                      );

                  Navigator.pop(dialogContext);
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text('ההוצאה נוספה ✓'),
                      backgroundColor: Colors.green,
                    ),
                  );
                },
                style: ElevatedButton.styleFrom(
                  backgroundColor: Theme.of(context).colorScheme.primary,
                  foregroundColor: Colors.white,
                ),
                child: const Text('שמור'),
              ),
            ],
          );
        },
      ),
    );
  }

  String _todayIso() {
    final now = DateTime.now();
    return '${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';
  }

  String _formatDate(String isoDate) {
    try {
      final parts = isoDate.split('-');
      return '${parts[2]}/${parts[1]}/${parts[0]}';
    } catch (_) {
      return isoDate;
    }
  }
}

