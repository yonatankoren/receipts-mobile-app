/// Shared Import Screen — receives files from Android Share and processes them.
///
/// Handles:
///   - Single file (image or PDF) → process → review screen
///   - Multiple files → process sequentially → receipts list
///   - Errors → friendly Hebrew message with option to go to camera
///
/// Reuses [ReceiptImportService] for all processing logic.

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../models/receipt_validation_exception.dart';
import '../providers/app_state.dart';
import '../services/pdf_import_service.dart';
import '../services/receipt_import_service.dart';
import '../widgets/loading_indicator.dart';
import 'review_and_fix_screen.dart';

class SharedImportScreen extends StatefulWidget {
  final List<String> filePaths;

  const SharedImportScreen({super.key, required this.filePaths});

  @override
  State<SharedImportScreen> createState() => _SharedImportScreenState();
}

class _SharedImportScreenState extends State<SharedImportScreen> {
  String _statusMessage = 'מייבא קבלה…';
  bool _hasError = false;
  String? _errorMessage;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _processFiles());
  }

  Future<void> _processFiles() async {
    final appState = context.read<AppState>();
    final isSingle = widget.filePaths.length == 1;

    try {
      if (isSingle) {
        await _processSingleFile(appState);
      } else {
        await _processMultipleFiles(appState);
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _hasError = true;
        _errorMessage = _friendlyError(e);
      });
    }
  }

  Future<void> _processSingleFile(AppState appState) async {
    final result = await ReceiptImportService.instance.importFile(
      filePath: widget.filePaths.first,
      appState: appState,
      onProgress: (msg) {
        if (mounted) setState(() => _statusMessage = msg);
      },
    );

    if (!mounted) return;

    Navigator.of(context).pushReplacement(
      MaterialPageRoute(
        builder: (_) => ReviewAndFixScreen(receiptId: result.receiptId),
      ),
    );
  }

  Future<void> _processMultipleFiles(AppState appState) async {
    final total = widget.filePaths.length;
    setState(() => _statusMessage = 'מייבא $total קבלות…');

    final results = await ReceiptImportService.instance.importFiles(
      filePaths: widget.filePaths,
      appState: appState,
      onFileProgress: (index, total, msg) {
        if (mounted) {
          setState(() => _statusMessage = 'קבלה ${index + 1} מתוך $total: $msg');
        }
      },
    );

    if (!mounted) return;

    if (results.isEmpty) {
      setState(() {
        _hasError = true;
        _errorMessage = 'לא הצלחנו לייבא את הקבצים. נסה שוב.';
      });
      return;
    }

    // Replace this screen with the last result's review (becomes bottom of chain),
    // then push remaining in reverse so the first-processed receipt is on top.
    // User flow: Review[0] → pop → Review[1] → ... → Review[last] → pop → home
    final nav = Navigator.of(context);
    nav.pushReplacement(
      MaterialPageRoute(
        builder: (_) => ReviewAndFixScreen(receiptId: results.last.receiptId),
      ),
    );
    for (int i = results.length - 2; i >= 0; i--) {
      nav.push(
        MaterialPageRoute(
          builder: (_) => ReviewAndFixScreen(receiptId: results[i].receiptId),
        ),
      );
    }
  }

  String _friendlyError(Object error) {
    if (error is UnsupportedFileException) return error.messageHe;
    if (error is ImportException) return error.messageHe;
    if (error is ReceiptValidationException) return error.messageHe;
    return 'לא הצלחנו לעבד את הקובץ. נסה שוב.';
  }

  @override
  Widget build(BuildContext context) {
    if (_hasError) {
      return Scaffold(
        body: SafeArea(
          child: Center(
            child: Padding(
              padding: const EdgeInsets.all(32),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 72,
                    height: 72,
                    decoration: BoxDecoration(
                      color: Colors.orange.withValues(alpha: 0.1),
                      shape: BoxShape.circle,
                    ),
                    child: const Icon(
                      Icons.warning_amber_rounded,
                      color: Colors.orange,
                      size: 40,
                    ),
                  ),
                  const SizedBox(height: 24),
                  Text(
                    _errorMessage ?? 'שגיאה לא צפויה',
                    textAlign: TextAlign.center,
                    textDirection: TextDirection.rtl,
                    style: const TextStyle(
                      fontSize: 17,
                      fontWeight: FontWeight.w500,
                      height: 1.5,
                    ),
                  ),
                  const SizedBox(height: 32),
                  ElevatedButton.icon(
                    onPressed: () => Navigator.of(context).pop(),
                    icon: const Icon(Icons.camera_alt, size: 20),
                    label: const Text('חזרה למצלמה'),
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
            ),
          ),
        ),
      );
    }

    return Scaffold(
      backgroundColor: Colors.black,
      body: Center(
        child: Card(
          margin: const EdgeInsets.all(32),
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                LoadingIndicator(message: _statusMessage),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
