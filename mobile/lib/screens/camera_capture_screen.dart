/// Camera Capture Screen — the default launch screen.
///
/// UX requirements:
///   - Camera opens INSTANTLY (no extra taps)
///   - Flash toggle
///   - Large capture button
///   - Gallery fallback for picking existing photos
///   - After capture: quick preview → auto-navigate to review

import 'package:flutter/material.dart';
import 'package:camera/camera.dart';
import 'package:file_picker/file_picker.dart';
import 'package:image_picker/image_picker.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';
import '../models/receipt_validation_exception.dart';
import '../providers/app_state.dart';
import '../services/drive_service.dart';
import '../services/pdf_import_service.dart';
import '../services/receipt_import_service.dart';
import '../services/sync_engine.dart';
import '../widgets/loading_indicator.dart';
import 'review_and_fix_screen.dart';
import 'receipts_list_screen.dart';
import 'expenses_list_screen.dart';
import 'settings_screen.dart';

class CameraCaptureScreen extends StatefulWidget {
  const CameraCaptureScreen({super.key});

  @override
  State<CameraCaptureScreen> createState() => _CameraCaptureScreenState();
}

class _CameraCaptureScreenState extends State<CameraCaptureScreen>
    with WidgetsBindingObserver, AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;

  CameraController? _controller;
  List<CameraDescription> _cameras = [];
  bool _isInitialized = false;
  bool _isCapturing = false;
  FlashMode _flashMode = FlashMode.auto;
  String? _error;
  bool _wasOnline = true;
  bool _isImportMenuOpen = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _wasOnline = SyncEngine.instance.isOnline;
    SyncEngine.instance.addListener(_onConnectivityChanged);
    _initCamera();
    // Load expenses so the badge count is available
    WidgetsBinding.instance.addPostFrameCallback((_) {
      context.read<AppState>().loadExpenses();
    });
  }

  @override
  void dispose() {
    SyncEngine.instance.removeListener(_onConnectivityChanged);
    WidgetsBinding.instance.removeObserver(this);
    _controller?.dispose();
    super.dispose();
  }

  void _onConnectivityChanged() {
    final isOnline = SyncEngine.instance.isOnline;
    if (isOnline && !_wasOnline && mounted) {
      // Connection restored — show snackbar
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: const Row(
            children: [
              Icon(Icons.wifi, color: Colors.white, size: 20),
              SizedBox(width: 8),
              Text('החיבור חזר!'),
            ],
          ),
          backgroundColor: Colors.green,
          duration: const Duration(seconds: 3),
          behavior: SnackBarBehavior.floating,
          margin: const EdgeInsets.only(bottom: 80, left: 16, right: 16),
        ),
      );
    }
    _wasOnline = isOnline;
    if (mounted) setState(() {});
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (_controller == null || !_controller!.value.isInitialized) return;

    if (state == AppLifecycleState.inactive) {
      _controller?.dispose();
    } else if (state == AppLifecycleState.resumed) {
      _initCamera();
    }
  }

  Future<void> _initCamera() async {
    try {
      _cameras = await availableCameras();
      if (_cameras.isEmpty) {
        setState(() => _error = 'לא נמצאו מצלמות');
        return;
      }

      // Prefer back camera
      final backCamera = _cameras.firstWhere(
        (c) => c.lensDirection == CameraLensDirection.back,
        orElse: () => _cameras.first,
      );

      _controller = CameraController(
        backCamera,
        ResolutionPreset.high, // Good quality for OCR
        enableAudio: false,
        imageFormatGroup: ImageFormatGroup.jpeg,
      );

      await _controller!.initialize();
      await _controller!.setFlashMode(_flashMode);

      if (mounted) {
        setState(() {
          _isInitialized = true;
          _error = null;
        });
      }
    } catch (e) {
      setState(() => _error = 'שגיאה באתחול המצלמה: $e');
    }
  }

  Future<void> _capturePhoto() async {
    if (_controller == null || !_controller!.value.isInitialized || _isCapturing) {
      return;
    }

    setState(() => _isCapturing = true);

    try {
      final xFile = await _controller!.takePicture();

      if (!mounted) return;

      // Show quick preview then process
      _handleCapturedImage(xFile.path);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('שגיאה בצילום: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _isCapturing = false);
    }
  }

  Future<void> _pickFromGallery() async {
    final picker = ImagePicker();
    final picked = await picker.pickImage(
      source: ImageSource.gallery,
      imageQuality: 90,
    );

    if (picked != null && mounted) {
      _handleCapturedImage(picked.path);
    }
  }

  /// After capturing or picking an image:
  /// 1. Save locally & create receipt
  /// 2. Try immediate processing
  /// 3. Navigate to review screen (or show validation failure)
  Future<void> _handleCapturedImage(String imagePath) async {
    final appState = context.read<AppState>();

    _showProcessingOverlay();

    try {
      final result = await ReceiptImportService.instance.importFile(
        filePath: imagePath,
        appState: appState,
      );

      if (!mounted) return;
      Navigator.of(context).pop();

      Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => ReviewAndFixScreen(receiptId: result.receiptId),
        ),
      );
    } on ReceiptValidationException catch (e) {
      if (mounted) {
        Navigator.of(context).pop();
        _showValidationFailureDialog(e);
      }
    } catch (e) {
      if (mounted) {
        Navigator.of(context).pop();
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('שגיאה: $e')),
        );
      }
    }
  }

  /// Show a user-friendly dialog when the backend rejects the image.
  void _showValidationFailureDialog(ReceiptValidationException error) {
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
              // Return to camera — user is already on the camera screen
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

  void _toggleFlash() {
    setState(() {
      switch (_flashMode) {
        case FlashMode.auto:
          _flashMode = FlashMode.always;
          break;
        case FlashMode.always:
          _flashMode = FlashMode.off;
          break;
        case FlashMode.off:
          _flashMode = FlashMode.auto;
          break;
        default:
          _flashMode = FlashMode.auto;
      }
    });
    _controller?.setFlashMode(_flashMode);
  }

  Future<void> _openDriveFolder() async {
    final link = await DriveService.instance.getRootFolderLink();
    if (link != null) {
      final uri = Uri.parse(link);
      if (await canLaunchUrl(uri)) {
        await launchUrl(uri, mode: LaunchMode.inAppBrowserView);
      }
    }
  }

  IconData get _flashIcon {
    switch (_flashMode) {
      case FlashMode.auto:
        return Icons.flash_auto;
      case FlashMode.always:
        return Icons.flash_on;
      case FlashMode.off:
        return Icons.flash_off;
      default:
        return Icons.flash_auto;
    }
  }

  String get _flashLabel {
    switch (_flashMode) {
      case FlashMode.auto:
        return 'אוטומטי';
      case FlashMode.always:
        return 'פלאש';
      case FlashMode.off:
        return 'כבוי';
      default:
        return '';
    }
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final isOnline = SyncEngine.instance.isOnline;
    final appState = context.watch<AppState>();
    final pendingExpenses = appState.expenses.length;

    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          // Main content area: camera preview OR offline message
          if (!isOnline)
            // Offline view — centered message
            const Center(
              child: Padding(
                padding: EdgeInsets.all(32),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.wifi_off, color: Colors.white54, size: 72),
                    SizedBox(height: 20),
                    Text(
                      'אין קליטה, נסה שוב מאוחר יותר',
                      style: TextStyle(
                        color: Colors.white70,
                        fontSize: 18,
                        fontWeight: FontWeight.w500,
                      ),
                      textAlign: TextAlign.center,
                    ),
                  ],
                ),
              ),
            )
          else if (_isInitialized && _controller != null)
            Positioned.fill(
              child: CameraPreview(_controller!),
            )
          else if (_error != null)
            Center(
              child: Padding(
                padding: const EdgeInsets.all(32),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.error_outline, color: Colors.white54, size: 64),
                    const SizedBox(height: 16),
                    Text(_error!, style: const TextStyle(color: Colors.white70)),
                    const SizedBox(height: 16),
                    ElevatedButton(
                      onPressed: _initCamera,
                      child: const Text('נסה שוב'),
                    ),
                  ],
                ),
              ),
            )
          else
            const Center(child: LoadingIndicator(color: Colors.white)),

          // Top bar: flash + sync indicator + navigation
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: SafeArea(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
                child: Row(
                  children: [
                    // Flash toggle (hidden when offline)
                    if (isOnline)
                      _buildTopButton(
                        icon: _flashIcon,
                        label: _flashLabel,
                        onTap: _toggleFlash,
                      ),
                    const Spacer(),
                    // Settings
                    _buildTopButton(
                      icon: Icons.settings,
                      onTap: () => Navigator.push(
                        context,
                        MaterialPageRoute(builder: (_) => const SettingsScreen()),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),

          // Bottom bar: add + expenses + capture + receipts + drive
          Positioned(
            bottom: 0,
            left: 0,
            right: 0,
            child: SafeArea(
              child: Padding(
                padding: const EdgeInsets.only(bottom: 24, left: 12, right: 12),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: [
                    // Import menu trigger (replaces Gallery)
                    _buildAddButton(isOnline),

                    // Pending expenses (with badge)
                    _buildBottomButton(
                      icon: Icons.pending_actions,
                      label: 'ממתינות',
                      badgeCount: pendingExpenses,
                      onTap: () async {
                        await Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (_) => const ExpensesListScreen(),
                          ),
                        );
                        if (mounted) {
                          context.read<AppState>().loadExpenses();
                        }
                      },
                    ),

                    // Capture button (disabled when offline)
                    GestureDetector(
                      onTap: (!isOnline || _isCapturing) ? null : _capturePhoto,
                      child: Opacity(
                        opacity: isOnline ? 1.0 : 0.4,
                        child: Container(
                          width: 80,
                          height: 80,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            border: Border.all(color: Colors.white, width: 4),
                            color: _isCapturing ? Colors.grey : Colors.white24,
                          ),
                          child: Center(
                            child: Container(
                              width: 64,
                              height: 64,
                              decoration: const BoxDecoration(
                                shape: BoxShape.circle,
                                color: Colors.white,
                              ),
                              child: _isCapturing
                                  ? const Padding(
                                      padding: EdgeInsets.all(16),
                                      child: LoadingIndicator(
                                        compact: true,
                                        size: 20,
                                      ),
                                    )
                                  : const Icon(
                                      Icons.camera_alt,
                                      color: Colors.black87,
                                      size: 32,
                                    ),
                            ),
                          ),
                        ),
                      ),
                    ),

                    // Receipts list
                    _buildBottomButton(
                      icon: Icons.receipt_long,
                      label: 'קבלות',
                      onTap: () => Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (_) => const ReceiptsListScreen(),
                        ),
                      ),
                    ),

                    // Drive folder (disabled when offline)
                    _buildBottomButton(
                      icon: Icons.folder_open,
                      label: 'Drive',
                      onTap: isOnline ? _openDriveFolder : null,
                      disabled: !isOnline,
                    ),
                  ],
                ),
              ),
            ),
          ),

          // Import menu overlay (backdrop + floating options)
          if (_isImportMenuOpen) ...[
            // Dim backdrop — closes menu on tap
            Positioned.fill(
              child: GestureDetector(
                onTap: () => setState(() => _isImportMenuOpen = false),
                child: Container(color: Colors.black54),
              ),
            ),
            // Menu items directly above the "+" button (RTL: first Row item is on the RIGHT)
            Builder(builder: (context) {
              final screenWidth = MediaQuery.of(context).size.width;
              final safeBottom = MediaQuery.of(context).viewPadding.bottom;
              final availableWidth = screenWidth - 24; // 12px padding each side
              // 5 items: add(52) + expenses(52) + camera(80) + receipts(52) + drive(52) = 288
              final gap = (availableWidth - 288) / 6;
              // In RTL, first item is rightmost. Icon right edge distance from screen right:
              final menuRight = 12.0 + gap;
              final baseBottom = safeBottom + 24 + 5 + 18 + 52 + 8;

              return Positioned(
                bottom: baseBottom,
                right: menuRight,
                child: TweenAnimationBuilder<double>(
                  tween: Tween(begin: 0.0, end: 1.0),
                  duration: const Duration(milliseconds: 220),
                  curve: Curves.easeOutCubic,
                  builder: (context, value, child) => Opacity(
                    opacity: value,
                    child: Transform.translate(
                      offset: Offset(0, 16 * (1 - value)),
                      child: child,
                    ),
                  ),
                  // Force LTR so icon is on the RIGHT, text on the LEFT —
                  // matching the "+" button position on the right side.
                  child: Directionality(
                    textDirection: TextDirection.ltr,
                    child: Column(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      _buildImportMenuItem(
                        icon: Icons.description_outlined,
                        label: 'מסמך',
                        onTap: _pickDocument,
                      ),
                      const SizedBox(height: 10),
                      _buildImportMenuItem(
                        icon: Icons.photo_library_outlined,
                        label: 'תמונה',
                        onTap: () {
                          setState(() => _isImportMenuOpen = false);
                          _pickFromGallery();
                        },
                      ),
                    ],
                  ),
                  ),
                ),
              );
            }),
          ],
        ],
      ),
    );
  }

  Widget _buildTopButton({
    required IconData icon,
    String? label,
    required VoidCallback onTap,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: Colors.black38,
          borderRadius: BorderRadius.circular(20),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, color: Colors.white, size: 22),
            if (label != null) ...[
              const SizedBox(width: 4),
              Text(
                label,
                style: const TextStyle(color: Colors.white, fontSize: 12),
              ),
            ],
          ],
        ),
      ),
    );
  }

  // ─── Import menu ──────────────────────────────────────────────

  Widget _buildAddButton(bool isOnline) {
    return GestureDetector(
      onTap: isOnline
          ? () => setState(() => _isImportMenuOpen = !_isImportMenuOpen)
          : null,
      child: Opacity(
        opacity: isOnline ? 1.0 : 0.4,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 52,
              height: 52,
              decoration: BoxDecoration(
                color: _isImportMenuOpen ? Colors.white24 : Colors.black38,
                borderRadius: BorderRadius.circular(16),
              ),
              child: AnimatedRotation(
                turns: _isImportMenuOpen ? 0.125 : 0.0, // 45° → ×
                duration: const Duration(milliseconds: 200),
                child: const Icon(
                  Icons.add_rounded,
                  color: Colors.white,
                  size: 30,
                ),
              ),
            ),
            const SizedBox(height: 4),
            const Text(
              'הוספה',
              style: TextStyle(color: Colors.white70, fontSize: 11),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildImportMenuItem({
    required IconData icon,
    required String label,
    required VoidCallback onTap,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        textDirection: TextDirection.ltr,
        children: [
          Text(
            label,
            style: const TextStyle(
              color: Colors.white70,
              fontSize: 12,
              fontWeight: FontWeight.w500,
            ),
          ),
          const SizedBox(width: 8),
          Container(
            width: 52,
            height: 52,
            decoration: BoxDecoration(
              color: Colors.black38,
              borderRadius: BorderRadius.circular(16),
            ),
            child: Icon(icon, color: Colors.white, size: 26),
          ),
        ],
      ),
    );
  }

  // ─── Document import ─────────────────────────────────────────

  Future<void> _pickDocument() async {
    setState(() => _isImportMenuOpen = false);

    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['pdf'],
    );

    if (result == null || result.files.isEmpty || !mounted) return;

    final file = result.files.first;
    final path = file.path;
    if (path == null) return;

    final ext = file.extension?.toLowerCase() ?? '';

    if (ext == 'pdf') {
      await _handlePdfImport(path);
      return;
    }

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('סוג קובץ לא נתמך — ניתן להעלות תמונות או PDF'),
        ),
      );
    }
  }

  Future<void> _handlePdfImport(String pdfPath) async {
    final progressNotifier = ValueNotifier<String>('טוען מסמך...');
    _showPdfProcessingOverlay(progressNotifier);

    try {
      final result = await ReceiptImportService.instance.importFile(
        filePath: pdfPath,
        appState: context.read<AppState>(),
        onProgress: (msg) => progressNotifier.value = msg,
      );

      if (!mounted) return;
      Navigator.of(context).pop();

      Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => ReviewAndFixScreen(receiptId: result.receiptId),
        ),
      );
    } on ImportException catch (e) {
      if (mounted) {
        Navigator.of(context).pop();
        _showImportErrorDialog(e.messageHe);
      }
    } on ReceiptValidationException catch (e) {
      if (mounted) {
        Navigator.of(context).pop();
        _showValidationFailureDialog(e);
      }
    } catch (e) {
      if (mounted) {
        Navigator.of(context).pop();
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('שגיאה בעיבוד המסמך: $e')),
        );
      }
    } finally {
      progressNotifier.dispose();
    }
  }

  void _showPdfProcessingOverlay(ValueNotifier<String> progressNotifier) {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => PopScope(
        canPop: false,
        child: Center(
          child: Card(
            margin: const EdgeInsets.all(32),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(20),
            ),
            child: Padding(
              padding: const EdgeInsets.all(32),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const LoadingIndicator(),
                  const SizedBox(height: 16),
                  ValueListenableBuilder<String>(
                    valueListenable: progressNotifier,
                    builder: (_, msg, __) => Text(
                      msg,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                            color: Colors.grey.shade600,
                          ),
                      textAlign: TextAlign.center,
                      textDirection: TextDirection.rtl,
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

  void _showImportErrorDialog(String message) {
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
                color: Colors.orange.withValues(alpha: 0.1),
                shape: BoxShape.circle,
              ),
              child: const Icon(
                Icons.warning_amber_rounded,
                color: Colors.orange,
                size: 40,
              ),
            ),
            const SizedBox(height: 20),
            Text(
              message,
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
          ElevatedButton(
            onPressed: () => Navigator.pop(dialogContext),
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.grey.shade700,
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
            ),
            child: const Text('הבנתי'),
          ),
        ],
      ),
    );
  }

  // ─── Bottom bar buttons ──────────────────────────────────────

  Widget _buildBottomButton({
    required IconData icon,
    required String label,
    VoidCallback? onTap,
    bool disabled = false,
    int badgeCount = 0,
  }) {
    return GestureDetector(
      onTap: disabled ? null : onTap,
      child: Opacity(
        opacity: disabled ? 0.4 : 1.0,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Stack(
              clipBehavior: Clip.none,
              children: [
                Container(
                  width: 52,
                  height: 52,
                  decoration: BoxDecoration(
                    color: Colors.black38,
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: Icon(icon, color: Colors.white, size: 26),
                ),
                if (badgeCount > 0)
                  Positioned(
                    top: -5,
                    left: -5,
                    child: Container(
                      constraints: const BoxConstraints(
                        minWidth: 20,
                        minHeight: 20,
                      ),
                      padding: const EdgeInsets.symmetric(horizontal: 4),
                      decoration: BoxDecoration(
                        color: Colors.red.shade600,
                        shape: badgeCount > 9
                            ? BoxShape.rectangle
                            : BoxShape.circle,
                        borderRadius: badgeCount > 9
                            ? BorderRadius.circular(10)
                            : null,
                      ),
                      alignment: Alignment.center,
                      child: Text(
                        '$badgeCount',
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 11,
                          fontWeight: FontWeight.bold,
                          height: 1,
                        ),
                      ),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              label,
              style: const TextStyle(color: Colors.white70, fontSize: 11),
            ),
          ],
        ),
      ),
    );
  }
}

