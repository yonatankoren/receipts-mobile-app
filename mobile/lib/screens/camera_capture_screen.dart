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
import 'package:image_picker/image_picker.dart';
import 'package:provider/provider.dart';
import '../providers/app_state.dart';
import '../services/sync_engine.dart';
import '../widgets/sync_status_indicator.dart';
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
    with WidgetsBindingObserver {
  CameraController? _controller;
  List<CameraDescription> _cameras = [];
  bool _isInitialized = false;
  bool _isCapturing = false;
  FlashMode _flashMode = FlashMode.auto;
  String? _error;
  bool _wasOnline = true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _wasOnline = SyncEngine.instance.isOnline;
    SyncEngine.instance.addListener(_onConnectivityChanged);
    _initCamera();
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
  /// 3. Navigate to review screen
  Future<void> _handleCapturedImage(String imagePath) async {
    final appState = context.read<AppState>();

    // Show processing indicator
    _showProcessingOverlay();

    try {
      // Save locally + create receipt
      final receipt = await appState.captureReceipt(imagePath);

      // Try immediate processing (non-blocking — review screen handles loading)
      final processed = await appState.processReceiptNow(receipt.id);

      if (!mounted) return;

      // Dismiss overlay and navigate to review
      Navigator.of(context).pop(); // Remove overlay

      Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => ReviewAndFixScreen(
            receiptId: processed?.id ?? receipt.id,
          ),
        ),
      );
    } catch (e) {
      if (mounted) {
        Navigator.of(context).pop(); // Remove overlay
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('שגיאה: $e')),
        );
      }
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
                  const CircularProgressIndicator(),
                  const SizedBox(height: 20),
                  Text(
                    'מעבד קבלה...',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'שומר ומנתח את הקבלה',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
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
    final isOnline = SyncEngine.instance.isOnline;

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
            const Center(child: CircularProgressIndicator(color: Colors.white)),

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
                    // Sync status
                    const SyncStatusIndicator(),
                    const SizedBox(width: 8),
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

          // Bottom bar: gallery + expenses + capture + receipts
          Positioned(
            bottom: 0,
            left: 0,
            right: 0,
            child: SafeArea(
              child: Padding(
                padding: const EdgeInsets.only(bottom: 24, left: 16, right: 16),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: [
                    // Gallery picker (disabled when offline)
                    _buildBottomButton(
                      icon: Icons.photo_library_outlined,
                      label: 'גלריה',
                      onTap: isOnline ? _pickFromGallery : null,
                      disabled: !isOnline,
                    ),

                    // Pending expenses
                    _buildBottomButton(
                      icon: Icons.pending_actions,
                      label: 'הוצאות',
                      onTap: () => Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (_) => const ExpensesListScreen(),
                        ),
                      ),
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
                                      child: CircularProgressIndicator(
                                        strokeWidth: 3,
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
                  ],
                ),
              ),
            ),
          ),
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

  Widget _buildBottomButton({
    required IconData icon,
    required String label,
    VoidCallback? onTap,
    bool disabled = false,
  }) {
    return GestureDetector(
      onTap: disabled ? null : onTap,
      child: Opacity(
        opacity: disabled ? 0.4 : 1.0,
        child: Column(
          mainAxisSize: MainAxisSize.min,
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

