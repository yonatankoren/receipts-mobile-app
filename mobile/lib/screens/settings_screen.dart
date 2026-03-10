/// Settings Screen — Google sign-in, storage info, backend config, debug info.
///
/// Features:
///   - Google Sign-In status + button
///   - Storage section: linked Drive folder + Spreadsheet with open/change
///   - Backend URL configuration
///   - Debug: storage usage, pending jobs, recent errors

import 'package:flutter/material.dart';
import 'package:googleapis/drive/v3.dart' as drive;
import 'package:googleapis/sheets/v4.dart' as sheets;
import '../services/auth_service.dart';
import '../services/accountant_config_service.dart';
import '../services/backend_service.dart';
import '../services/storage_config_service.dart';
import '../services/sync_engine.dart';
import '../services/image_service.dart';
import '../db/database_helper.dart';
import '../utils/constants.dart';
import '../widgets/loading_indicator.dart';
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

  final _accountantEmailController = TextEditingController();
  final _ccEmailsController = TextEditingController();

  @override
  void initState() {
    super.initState();
    _accountantEmailController.text =
        AccountantConfigService.instance.accountantEmail ?? '';
    _ccEmailsController.text =
        AccountantConfigService.instance.ccEmails.join(', ');
    _loadSettings();
  }

  @override
  void dispose() {
    _accountantEmailController.dispose();
    _ccEmailsController.dispose();
    super.dispose();
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
      // Validate the spreadsheet and check for conflicting tabs before saving
      if (!mounted) return;

      // Show a loading indicator while checking
      showDialog(
        context: context,
        barrierDismissible: false,
        builder: (_) => const PopScope(
          canPop: false,
          child: Center(child: LoadingIndicator()),
        ),
      );

      List<String> conflictingTabs;
      try {
        conflictingTabs = await _checkForConflictingTabs(result);
      } catch (e) {
        if (mounted) {
          Navigator.of(context).pop(); // dismiss loading
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('לא ניתן לגשת לגיליון — בדקו את המזהה ונסו שוב.'),
            ),
          );
        }
        return;
      }

      if (!mounted) return;
      Navigator.of(context).pop(); // dismiss loading

      // If conflicting tabs found, warn the user
      if (conflictingTabs.isNotEmpty) {
        final proceed = await _showTabConflictWarning(conflictingTabs);
        if (proceed != true) return; // user cancelled
      }

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

  /// Check if a spreadsheet already has tabs that look like app-managed tabs
  /// (e.g. "הוצאות 2025", "סיכום 2026").
  /// Returns the list of matching tab names, or an empty list if none found.
  /// Throws on API errors (invalid ID, no access, etc.).
  Future<List<String>> _checkForConflictingTabs(String spreadsheetId) async {
    final client = await AuthService.instance.getAuthenticatedClient();
    if (client == null) {
      throw Exception('Not authenticated');
    }

    try {
      final api = sheets.SheetsApi(client);
      final spreadsheet = await api.spreadsheets.get(spreadsheetId);

      final yearPattern = RegExp(r'^\d{4}$');
      final expensesPrefix = AppConstants.expensesTabPrefix;
      final totalsPrefix = AppConstants.totalsTabPrefix;

      final conflicting = <String>[];
      for (final sheet in spreadsheet.sheets ?? <sheets.Sheet>[]) {
        final title = sheet.properties?.title ?? '';
        // Check for "הוצאות YYYY" or "סיכום YYYY"
        for (final prefix in [expensesPrefix, totalsPrefix]) {
          if (title.startsWith(prefix) && title.length > prefix.length) {
            final suffix = title.substring(prefix.length).trim();
            if (yearPattern.hasMatch(suffix)) {
              conflicting.add(title);
            }
          }
        }
      }

      return conflicting;
    } finally {
      client.close();
    }
  }

  /// Show a warning dialog listing conflicting tabs and let the user decide.
  /// Returns `true` if the user chose to proceed, `false`/`null` otherwise.
  Future<bool?> _showTabConflictWarning(List<String> conflictingTabs) {
    final tabList = conflictingTabs.map((t) => '• $t').join('\n');

    return showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: Row(
          children: [
            Icon(Icons.warning_amber_rounded, color: Colors.orange.shade700, size: 28),
            const SizedBox(width: 8),
            const Expanded(
              child: Text(
                'גיליון עם תוכן קיים',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
              ),
            ),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'בגיליון שבחרת נמצאו לשוניות שהאפליקציה משתמשת בהן לניהול הוצאות:',
              textDirection: TextDirection.rtl,
              style: TextStyle(fontSize: 14, height: 1.5),
            ),
            const SizedBox(height: 12),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.orange.shade50,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: Colors.orange.shade200),
              ),
              child: Text(
                tabList,
                textDirection: TextDirection.rtl,
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  color: Colors.orange.shade900,
                ),
              ),
            ),
            const SizedBox(height: 12),
            const Text(
              'אם תמשיך, קבלות חדשות יתווספו לתוך הלשוניות הקיימות ועלולות להתערבב עם התוכן שכבר שם.\n\nאם אינך בטוח, מומלץ ליצור גיליון חדש.',
              textDirection: TextDirection.rtl,
              style: TextStyle(fontSize: 14, height: 1.5),
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
              backgroundColor: Colors.orange.shade600,
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
            ),
            child: const Text('המשך בכל זאת'),
          ),
        ],
      ),
    );
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
          ? const Center(child: LoadingIndicator())
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
                            // Drive folder (read-only — user can move it freely in Drive)
                            _buildStorageInfoRow(
                              theme,
                              icon: Icons.folder,
                              label: 'תיקיית Drive',
                              value: folderName ?? 'לא הוגדרה',
                              hint: 'ניתן להזיז את התיקייה בתוך Google Drive',
                            ),
                            const Divider(height: 24),
                            // Spreadsheet
                            _buildStorageRow(
                              theme,
                              icon: Icons.table_chart,
                              label: 'גיליון Sheets',
                              value: sheetName ?? 'לא הוגדר',
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

                // Accountant Section
                _buildSectionHeader(theme, 'רואה חשבון', Icons.mail_outline),
                Card(
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: _buildAccountantContent(theme),
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
    );
  }

  /// Read-only storage info row (no change button) — used for the Drive folder
  /// which users can move freely inside Google Drive.
  Widget _buildStorageInfoRow(
    ThemeData theme, {
    required IconData icon,
    required String label,
    required String value,
    String? hint,
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
        if (hint != null) ...[
          const SizedBox(height: 4),
          Text(
            hint,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
              fontSize: 11,
            ),
          ),
        ],
      ],
    );
  }

  // ─── Accountant section ───────────────────────────────────────

  Widget _buildAccountantContent(ThemeData theme) {
    final config = AccountantConfigService.instance;
    final hasEmail = config.hasAccountantEmail;

    if (!hasEmail) {
      // No accountant configured — show description + "הוסף" button
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'הגדר מייל של רואה החשבון כדי לשלוח קבלות בקלות דרך Gmail.',
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
            textDirection: TextDirection.rtl,
          ),
          const SizedBox(height: 16),
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              onPressed: () => _showAccountantDialog(context),
              icon: const Icon(Icons.add, size: 20),
              label: const Text('הוסף'),
              style: FilledButton.styleFrom(
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
                padding: const EdgeInsets.symmetric(vertical: 12),
              ),
            ),
          ),
        ],
      );
    }

    // Accountant configured — show current values + "ערוך" button
    final ccText =
        config.ccEmails.isNotEmpty ? config.ccEmails.join(', ') : '—';

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _buildAccountantInfoRow(
          theme,
          Icons.email_outlined,
          'מייל',
          config.accountantEmail!,
        ),
        const SizedBox(height: 10),
        _buildAccountantInfoRow(
          theme,
          Icons.people_outline,
          'העתק (CC)',
          ccText,
        ),
        const SizedBox(height: 16),
        SizedBox(
          width: double.infinity,
          child: OutlinedButton.icon(
            onPressed: () => _showAccountantDialog(context),
            icon: const Icon(Icons.edit, size: 18),
            label: const Text('ערוך'),
            style: OutlinedButton.styleFrom(
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
              padding: const EdgeInsets.symmetric(vertical: 12),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildAccountantInfoRow(
    ThemeData theme,
    IconData icon,
    String label,
    String value,
  ) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: 18, color: theme.colorScheme.onSurfaceVariant),
        const SizedBox(width: 8),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                label,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                value,
                style: theme.textTheme.bodyMedium,
                textDirection: TextDirection.ltr,
              ),
            ],
          ),
        ),
      ],
    );
  }

  Future<void> _showAccountantDialog(BuildContext ctx) async {
    final config = AccountantConfigService.instance;
    final emailCtrl = TextEditingController(
      text: config.accountantEmail ?? '',
    );
    final ccCtrl = TextEditingController(
      text: config.ccEmails.join(', '),
    );

    final confirmed = await showDialog<bool>(
      context: ctx,
      builder: (dialogCtx) {
        final theme = Theme.of(dialogCtx);
        return AlertDialog(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
          title: Row(
            children: [
              Icon(Icons.mail_outline, color: theme.colorScheme.primary),
              const SizedBox(width: 8),
              const Text('פרטי רואה חשבון'),
            ],
          ),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: emailCtrl,
                  decoration: InputDecoration(
                    labelText: 'מייל רואה חשבון',
                    hintText: 'accountant@example.com',
                    prefixIcon: const Icon(Icons.email_outlined),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                  keyboardType: TextInputType.emailAddress,
                  textDirection: TextDirection.ltr,
                ),
                const SizedBox(height: 16),
                TextField(
                  controller: ccCtrl,
                  decoration: InputDecoration(
                    labelText: 'העתק (CC)',
                    hintText: 'כתובות נוספות, מופרדות בפסיק',
                    prefixIcon: const Icon(Icons.people_outline),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                  keyboardType: TextInputType.emailAddress,
                  textDirection: TextDirection.ltr,
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogCtx, false),
              child: const Text('ביטול'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(dialogCtx, true),
              child: const Text('אישור'),
            ),
          ],
        );
      },
    );

    if (confirmed == true) {
      final email = emailCtrl.text.trim();
      final ccList = ccCtrl.text
          .split(',')
          .map((e) => e.trim())
          .where((e) => e.isNotEmpty)
          .toList();

      await config.setAccountantEmail(email.isEmpty ? null : email);
      await config.setCcEmails(ccList);

      // Update the old controllers too (kept for compatibility)
      _accountantEmailController.text = email;
      _ccEmailsController.text = ccList.join(', ');

      setState(() {});

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: const Text('פרטי רואה חשבון הוגדרו בהצלחה'),
            backgroundColor: Colors.green.shade600,
            behavior: SnackBarBehavior.floating,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(10),
            ),
          ),
        );
      }
    }

    emailCtrl.dispose();
    ccCtrl.dispose();
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
