/// Google Connect Screen — first-launch & returning-user onboarding.
///
/// Shown when the user is not signed in to a Google account.
/// After sign-in:
///   1. FAST PATH — check local config (SharedPreferences), validate → camera
///   2. SLOW PATH — search Drive for existing "הוצאות" folder+spreadsheet → auto-link → camera
///   3. FALLBACK — nothing found → StorageSetupScreen (create new)
///
/// Clean RTL layout with animated status messages during the search.

import 'package:flutter/material.dart';
import 'package:googleapis/drive/v3.dart' as drive;
import '../../services/auth_service.dart';
import '../../services/storage_config_service.dart';
import '../../utils/constants.dart';
import '../camera_capture_screen.dart';
import 'storage_setup_screen.dart';

class GoogleConnectScreen extends StatefulWidget {
  const GoogleConnectScreen({super.key});

  @override
  State<GoogleConnectScreen> createState() => _GoogleConnectScreenState();
}

class _GoogleConnectScreenState extends State<GoogleConnectScreen> {
  bool _isBusy = false;
  String? _statusMessage;

  Future<void> _signIn() async {
    setState(() {
      _isBusy = true;
      _statusMessage = null;
    });

    try {
      final success = await AuthService.instance.signIn();
      if (!mounted) return;

      if (!success) {
        setState(() => _isBusy = false);
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('ההתחברות נכשלה. נסו שוב.'),
            backgroundColor: Colors.red,
          ),
        );
        return;
      }

      // Save the account email
      final email = AuthService.instance.currentUser?.email;
      if (email != null) {
        await StorageConfigService.instance.setAccountEmail(email);
      }

      // ── FAST PATH: local config still valid ──
      final config = StorageConfigService.instance;
      if (config.isFullyConfigured) {
        setState(() => _statusMessage = 'בודק הגדרות קיימות...');
        final validation = await config.validateAccess();
        if (!mounted) return;
        if (validation.allOk) {
          setState(() => _statusMessage = '✓ הכל מוכן!');
          await Future.delayed(const Duration(milliseconds: 500));
          if (!mounted) return;
          _goToCamera();
          return;
        }
        // Config is stale — fall through to Drive search
      }

      // ── SLOW PATH: search Drive for existing resources ──
      setState(() => _statusMessage = 'מחפש תיקיית הוצאות קיימת...');
      final found = await _searchAndLinkExistingResources();
      if (!mounted) return;

      if (found) {
        setState(() => _statusMessage = '✓ מצאנו את ההוצאות שלך!');
        await Future.delayed(const Duration(milliseconds: 800));
        if (!mounted) return;
        _goToCamera();
      } else {
        _goToSetup();
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('שגיאה: $e'), backgroundColor: Colors.red),
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _isBusy = false;
          _statusMessage = null;
        });
      }
    }
  }

  // ──────────────────── Drive search ────────────────────

  /// Search Drive for an existing "הוצאות" folder that contains a
  /// "הוצאות" spreadsheet. If found, save the IDs and return true.
  /// With drive.file scope, only app-created files are visible — which is
  /// exactly what we want for reconnection.
  /// Folders are sorted by most recently modified — the freshest wins.
  Future<bool> _searchAndLinkExistingResources() async {
    final client = await AuthService.instance.getAuthenticatedClient();
    if (client == null) return false;

    try {
      final driveApi = drive.DriveApi(client);
      final folderName = AppConstants.driveRootFolderDefaultName; // "הוצאות"

      // Search for folders and spreadsheets named "הוצאות" in parallel
      final results = await Future.wait([
        driveApi.files.list(
          q: "name = '$folderName' "
              "and mimeType = 'application/vnd.google-apps.folder' "
              "and trashed = false",
          spaces: 'drive',
          orderBy: 'modifiedTime desc',
          pageSize: 20,
          $fields: 'files(id, name)',
        ),
        driveApi.files.list(
          q: "name = '$folderName' "
              "and mimeType = 'application/vnd.google-apps.spreadsheet' "
              "and trashed = false",
          spaces: 'drive',
          pageSize: 50,
          $fields: 'files(id, name, parents)',
        ),
      ]);

      final folders = results[0].files ?? [];
      final sheets = results[1].files ?? [];

      if (folders.isEmpty) return false;

      // Find the most recently modified folder that has a spreadsheet inside
      for (final folder in folders) {
        final matchingSheet = sheets
            .where((s) =>
                s.parents != null && s.parents!.contains(folder.id))
            .firstOrNull;

        if (matchingSheet != null) {
          // Found a valid pair — link it
          await StorageConfigService.instance.setFolderConfig(
            folderId: folder.id!,
            folderName: folder.name!,
          );
          await StorageConfigService.instance.setSpreadsheetConfig(
            spreadsheetId: matchingSheet.id!,
            spreadsheetName: matchingSheet.name!,
          );
          debugPrint(
            'Reconnect: linked folder=${folder.id}, sheet=${matchingSheet.id}',
          );
          return true;
        }
      }

      return false;
    } catch (e) {
      debugPrint('Drive search error: $e');
      return false; // Silently fall through to setup screen
    } finally {
      client.close();
    }
  }

  // ──────────────────── Navigation ────────────────────

  void _goToCamera() {
    Navigator.of(context).pushAndRemoveUntil(
      MaterialPageRoute(builder: (_) => const CameraCaptureScreen()),
      (_) => false,
    );
  }

  void _goToSetup() {
    Navigator.of(context).pushReplacement(
      MaterialPageRoute(builder: (_) => const StorageSetupScreen()),
    );
  }

  // ──────────────────── UI ────────────────────

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 32),
          child: Column(
            children: [
              const Spacer(flex: 2),

              // App icon
              Container(
                width: 100,
                height: 100,
                decoration: BoxDecoration(
                  color: theme.colorScheme.primaryContainer,
                  borderRadius: BorderRadius.circular(24),
                ),
                child: Icon(
                  Icons.receipt_long,
                  size: 52,
                  color: theme.colorScheme.primary,
                ),
              ),
              const SizedBox(height: 32),

              // Title
              Text(
                'קבלות: ניהול הוצאות קליל',
                style: theme.textTheme.headlineMedium?.copyWith(
                  fontWeight: FontWeight.bold,
                  color: theme.colorScheme.onSurface,
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 12),

              // Subtitle
              Text(
                'צלמו קבלות, שמרו אותן \nוראו את כל ההוצאות במקום אחד.',
                style: theme.textTheme.bodyLarge?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                  height: 1.5,
                ),
                textAlign: TextAlign.center,
              ),

              const Spacer(flex: 3),

              // Status message (shown during search after sign-in)
              AnimatedSwitcher(
                duration: const Duration(milliseconds: 300),
                child: _statusMessage != null
                    ? Padding(
                        key: ValueKey(_statusMessage),
                        padding: const EdgeInsets.only(bottom: 20),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            if (!_statusMessage!.startsWith('✓'))
                              const SizedBox(
                                width: 18,
                                height: 18,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            else
                              Icon(
                                Icons.check_circle,
                                size: 20,
                                color: Colors.green.shade600,
                              ),
                            const SizedBox(width: 10),
                            Flexible(
                              child: Text(
                                _statusMessage!.replaceFirst('✓ ', ''),
                                style: theme.textTheme.bodyMedium?.copyWith(
                                  color: _statusMessage!.startsWith('✓')
                                      ? Colors.green.shade700
                                      : theme.colorScheme.onSurfaceVariant,
                                  fontWeight: _statusMessage!.startsWith('✓')
                                      ? FontWeight.w600
                                      : FontWeight.normal,
                                ),
                              ),
                            ),
                          ],
                        ),
                      )
                    : const SizedBox.shrink(key: ValueKey('empty')),
              ),

              // Sign in button
              SizedBox(
                width: double.infinity,
                height: 56,
                child: ElevatedButton.icon(
                  onPressed: _isBusy ? null : _signIn,
                  icon: _isBusy
                      ? const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.login, size: 22),
                  label: Text(
                    _isBusy ? 'מתחבר...' : 'התחבר לחשבון Google',
                    style: const TextStyle(fontSize: 17),
                  ),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: theme.colorScheme.primary,
                    foregroundColor: theme.colorScheme.onPrimary,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(16),
                    ),
                  ),
                ),
              ),

              const SizedBox(height: 16),

              // Info text
              Text(
                'נדרשת גישה ל-Google Drive ו-Google Sheets\nלשמירת הקבלות והנתונים.',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
                textAlign: TextAlign.center,
              ),

              const Spacer(flex: 1),
            ],
          ),
        ),
      ),
    );
  }
}
