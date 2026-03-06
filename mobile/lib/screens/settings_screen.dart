/// Settings Screen — Google sign-in, storage info, backend config, debug info.
///
/// Features:
///   - Google Sign-In status + button
///   - Storage section: linked Drive folder + Spreadsheet with open/change
///   - Backend URL configuration
///   - Debug: storage usage, pending jobs, recent errors

import 'package:flutter/material.dart';
import 'package:googleapis/drive/v3.dart' as drive;
import 'package:url_launcher/url_launcher.dart';
import '../services/auth_service.dart';
import '../services/backend_service.dart';
import '../services/drive_service.dart';
import '../services/sheets_service.dart';
import '../services/storage_config_service.dart';
import '../services/sync_engine.dart';
import '../services/image_service.dart';
import '../db/database_helper.dart';
import '../utils/constants.dart';
import '../widgets/drive_folder_picker.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  bool _isLoading = true;
  int _pendingJobs = 0;
  int _totalReceipts = 0;
  String _storageUsage = '';
  bool _backendHealthy = false;

  @override
  void initState() {
    super.initState();
    _loadSettings();
  }

  Future<void> _loadSettings() async {
    final pendingJobs = await DatabaseHelper.instance.getPendingJobCount();
    final receipts = await DatabaseHelper.instance.getAllReceipts();
    final storageBytes = await ImageService.instance.getTotalStorageBytes();
    final healthy = await BackendService.instance.isHealthy();

    if (mounted) {
      setState(() {
        _pendingJobs = pendingJobs;
        _totalReceipts = receipts.length;
        _storageUsage = _formatBytes(storageBytes);
        _backendHealthy = healthy;
        _isLoading = false;
      });
    }
  }

  Future<void> _openUrl(String url) async {
    final uri = Uri.parse(url);
    if (await canLaunchUrl(uri)) {
      // Use inAppBrowserView (Chrome Custom Tab) to respect ?authuser=
      // and avoid the native app account chooser dialog.
      await launchUrl(uri, mode: LaunchMode.inAppBrowserView);
    }
  }

  Future<void> _changeFolder() async {
    final result = await showDriveFolderPicker(context);
    if (result != null) {
      await StorageConfigService.instance.setFolderConfig(
        folderId: result.folderId,
        folderName: result.folderName,
      );
      if (mounted) {
        setState(() {});
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('התיקייה שונתה ל: ${result.folderName} ✓'),
            backgroundColor: Colors.green,
          ),
        );
      }
    }
  }

  Future<void> _changeSpreadsheet() async {
    // Show a dialog to let the user enter a spreadsheet ID or create a new one
    final config = StorageConfigService.instance;
    final controller = TextEditingController(
      text: config.spreadsheetId ?? '',
    );

    final result = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('שינוי גיליון'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              'הזינו מזהה גיליון חדש, או לחצו "צור חדש" ליצירת גיליון חדש בתיקייה הנוכחית.',
              style: TextStyle(fontSize: 13),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: controller,
              decoration: InputDecoration(
                labelText: 'מזהה גיליון (Spreadsheet ID)',
                hintText: 'מזהה מה-URL של הגיליון',
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('ביטול'),
          ),
          TextButton(
            onPressed: () async {
              // Create a new spreadsheet in the current folder
              final folderId = config.receiptsRootFolderId;
              if (folderId == null) {
                Navigator.pop(ctx);
                return;
              }

              try {
                final client =
                    await AuthService.instance.getAuthenticatedClient();
                if (client == null) return;

                try {
                  final driveApi = drive.DriveApi(client);
                  final spreadsheet = drive.File()
                    ..name = AppConstants.spreadsheetDefaultName
                    ..mimeType = 'application/vnd.google-apps.spreadsheet'
                    ..parents = [folderId];

                  final created = await driveApi.files
                      .create(spreadsheet, $fields: 'id, name');
                  if (ctx.mounted) Navigator.pop(ctx, created.id);
                } finally {
                  client.close();
                }
              } catch (e) {
                if (ctx.mounted) {
                  ScaffoldMessenger.of(ctx).showSnackBar(
                    SnackBar(content: Text('שגיאה: $e')),
                  );
                }
              }
            },
            child: const Text('צור חדש'),
          ),
          ElevatedButton(
            onPressed: () {
              final text = controller.text.trim();
              if (text.isNotEmpty) Navigator.pop(ctx, text);
            },
            child: const Text('שמור'),
          ),
        ],
      ),
    );

    controller.dispose();

    if (result != null && result.isNotEmpty) {
      await config.setSpreadsheetConfig(
        spreadsheetId: result,
        spreadsheetName: AppConstants.spreadsheetDefaultName,
      );
      if (mounted) {
        setState(() {});
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('הגיליון שונה ✓'),
            backgroundColor: Colors.green,
          ),
        );
      }
    }
  }

  String _formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final authService = AuthService.instance;
    final config = StorageConfigService.instance;

    return Scaffold(
      appBar: AppBar(
        title: const Text('הגדרות'),
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                // Google Account Section
                _buildSectionHeader(theme, 'חשבון גוגל', Icons.account_circle),
                Card(
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: ListenableBuilder(
                      listenable: authService,
                      builder: (context, _) {
                        if (authService.isSignedIn) {
                          return Column(
                            children: [
                              Row(
                                children: [
                                  CircleAvatar(
                                    backgroundImage: authService
                                                .currentUser?.photoUrl !=
                                            null
                                        ? NetworkImage(
                                            authService.currentUser!.photoUrl!)
                                        : null,
                                    child: authService
                                                .currentUser?.photoUrl ==
                                            null
                                        ? const Icon(Icons.person)
                                        : null,
                                  ),
                                  const SizedBox(width: 12),
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Text(
                                          authService.currentUser
                                                  ?.displayName ??
                                              '',
                                          style: theme.textTheme.titleSmall,
                                        ),
                                        Text(
                                          authService.currentUser?.email ?? '',
                                          style: theme.textTheme.bodySmall,
                                        ),
                                      ],
                                    ),
                                  ),
                                  const Icon(Icons.check_circle,
                                      color: Colors.green, size: 20),
                                ],
                              ),
                              const SizedBox(height: 12),
                              SizedBox(
                                width: double.infinity,
                                child: OutlinedButton(
                                  onPressed: () async {
                                    await authService.signOut();
                                  },
                                  child: const Text('התנתק'),
                                ),
                              ),
                            ],
                          );
                        } else {
                          return SizedBox(
                            width: double.infinity,
                            height: 48,
                            child: ElevatedButton.icon(
                              onPressed: () async {
                                final success = await authService.signIn();
                                if (!success && mounted) {
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    const SnackBar(
                                        content:
                                            Text('ההתחברות נכשלה')),
                                  );
                                }
                              },
                              icon: const Icon(Icons.login),
                              label: const Text('התחבר עם גוגל'),
                              style: ElevatedButton.styleFrom(
                                backgroundColor: Colors.blue,
                                foregroundColor: Colors.white,
                              ),
                            ),
                          );
                        }
                      },
                    ),
                  ),
                ),
                const SizedBox(height: 24),

                // Storage Section
                _buildSectionHeader(theme, 'אחסון', Icons.cloud),
                Card(
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: ListenableBuilder(
                      listenable: config,
                      builder: (context, _) {
                        final folderName = config.receiptsRootFolderName;
                        final sheetName = config.spreadsheetName;

                        if (folderName == null && sheetName == null) {
                          return const Padding(
                            padding: EdgeInsets.symmetric(vertical: 8),
                            child: Text(
                              'האחסון לא הוגדר. חזרו למסך הראשי להגדרה.',
                              style: TextStyle(color: Colors.grey),
                            ),
                          );
                        }

                        return Column(
                          children: [
                            // Drive folder
                            _buildStorageRow(
                              theme,
                              icon: Icons.folder,
                              label: 'תיקיית Drive',
                              value: folderName ?? 'לא הוגדרה',
                              onOpen: () async {
                                final link = await DriveService.instance
                                    .getRootFolderLink();
                                if (link != null) _openUrl(link);
                              },
                              onChangeTap: _changeFolder,
                              changeLabel: 'שינוי תיקייה',
                            ),
                            const Divider(height: 24),
                            // Spreadsheet
                            _buildStorageRow(
                              theme,
                              icon: Icons.table_chart,
                              label: 'גיליון Sheets',
                              value: sheetName ?? 'לא הוגדר',
                              onOpen: () {
                                final link = SheetsService.instance
                                    .getSpreadsheetLink();
                                if (link != null) _openUrl(link);
                              },
                              onChangeTap: _changeSpreadsheet,
                              changeLabel: 'שינוי גיליון',
                            ),
                          ],
                        );
                      },
                    ),
                  ),
                ),
                const SizedBox(height: 24),

                // Backend Status
                _buildSectionHeader(theme, 'שרת עיבוד', Icons.dns),
                Card(
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: ListTile(
                    leading: Icon(
                      _backendHealthy
                          ? Icons.check_circle
                          : Icons.error,
                      color: _backendHealthy ? Colors.green : Colors.red,
                      size: 28,
                    ),
                    title: Text(
                      _backendHealthy
                          ? 'השרת פעיל ומוכן'
                          : 'השרת לא זמין',
                      style: TextStyle(
                        fontWeight: FontWeight.w600,
                        color: _backendHealthy ? Colors.green : Colors.red,
                      ),
                    ),
                    subtitle: Text(
                      _backendHealthy
                          ? 'עיבוד קבלות יתבצע כרגיל'
                          : 'קבלות ישמרו מקומית ויעובדו כשהשרת יחזור',
                      style: TextStyle(
                        fontSize: 12,
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 24),

                // Debug / Status
                _buildSectionHeader(theme, 'מידע ודיבאג', Icons.info),
                Card(
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Column(
                    children: [
                      ListTile(
                        leading: const Icon(Icons.receipt),
                        title: const Text('סך הכל קבלות'),
                        trailing: Text('$_totalReceipts',
                            style: theme.textTheme.titleMedium),
                      ),
                      const Divider(height: 1),
                      ListTile(
                        leading: Icon(
                          Icons.sync,
                          color: _pendingJobs > 0 ? Colors.orange : Colors.green,
                        ),
                        title: const Text('משימות בתור'),
                        trailing: Text(
                          '$_pendingJobs',
                          style: theme.textTheme.titleMedium?.copyWith(
                            color:
                                _pendingJobs > 0 ? Colors.orange : Colors.green,
                          ),
                        ),
                      ),
                      const Divider(height: 1),
                      ListTile(
                        leading: const Icon(Icons.storage),
                        title: const Text('אחסון מקומי'),
                        trailing: Text(_storageUsage,
                            style: theme.textTheme.titleMedium),
                      ),
                      const Divider(height: 1),
                      ListTile(
                        leading: const Icon(Icons.wifi),
                        title: const Text('חיבור'),
                        trailing: ListenableBuilder(
                          listenable: SyncEngine.instance,
                          builder: (_, __) => Text(
                            SyncEngine.instance.isOnline
                                ? 'מחובר ✓'
                                : 'לא מחובר',
                            style: TextStyle(
                              color: SyncEngine.instance.isOnline
                                  ? Colors.green
                                  : Colors.red,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 32),
              ],
            ),
    );
  }

  Widget _buildStorageRow(
    ThemeData theme, {
    required IconData icon,
    required String label,
    required String value,
    required VoidCallback onOpen,
    required VoidCallback onChangeTap,
    required String changeLabel,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(icon, size: 20, color: theme.colorScheme.primary),
            const SizedBox(width: 8),
            Text(
              label,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
        const SizedBox(height: 4),
        Text(
          value,
          style: theme.textTheme.titleSmall?.copyWith(
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            TextButton.icon(
              onPressed: onOpen,
              icon: const Icon(Icons.open_in_new, size: 16),
              label: const Text('פתח'),
              style: TextButton.styleFrom(
                padding:
                    const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                textStyle: const TextStyle(fontSize: 13),
              ),
            ),
            const SizedBox(width: 8),
            TextButton.icon(
              onPressed: onChangeTap,
              icon: const Icon(Icons.edit, size: 16),
              label: Text(changeLabel),
              style: TextButton.styleFrom(
                padding:
                    const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                textStyle: const TextStyle(fontSize: 13),
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildSectionHeader(ThemeData theme, String title, IconData icon) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8, top: 8),
      child: Row(
        children: [
          Icon(icon, size: 20, color: theme.colorScheme.primary),
          const SizedBox(width: 8),
          Text(
            title,
            style: theme.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.bold,
              color: theme.colorScheme.primary,
            ),
          ),
        ],
      ),
    );
  }
}
