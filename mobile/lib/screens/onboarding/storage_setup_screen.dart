/// Storage Setup Screen — onboarding step after Google sign-in.
///
/// Shows a warm welcome message in Hebrew, then creates a "הוצאות" folder
/// in the user's Google Drive root along with a Sheets spreadsheet inside it.
/// The user can later move the folder anywhere in their Drive — the app
/// references it by ID, so it keeps working regardless of location.

import 'package:flutter/material.dart';
import 'package:googleapis/drive/v3.dart' as drive;
import 'package:googleapis/sheets/v4.dart' as sheets;
import '../../services/auth_service.dart';
import '../../services/storage_config_service.dart';
import '../../utils/constants.dart';
import '../camera_capture_screen.dart';

class StorageSetupScreen extends StatefulWidget {
  /// If true, shows a "storage inaccessible" message instead of the welcome text.
  final bool isRelink;

  const StorageSetupScreen({super.key, this.isRelink = false});

  @override
  State<StorageSetupScreen> createState() => _StorageSetupScreenState();
}

class _StorageSetupScreenState extends State<StorageSetupScreen> {
  bool _isCreating = false;
  String? _error;

  Future<void> _createResources() async {
    setState(() {
      _isCreating = true;
      _error = null;
    });

    try {
      final client = await AuthService.instance.getAuthenticatedClient();
      if (client == null) {
        throw Exception('לא מחובר לחשבון Google');
      }

      try {
        final driveApi = drive.DriveApi(client);

        // 1. Create the "הוצאות" folder in Drive root
        final folderName = AppConstants.driveRootFolderDefaultName;
        final folder = drive.File()
          ..name = folderName
          ..mimeType = 'application/vnd.google-apps.folder'
          ..parents = ['root'];

        final createdFolder = await driveApi.files.create(
          folder,
          $fields: 'id, name',
        );

        debugPrint('StorageSetup: created folder ${createdFolder.id}');

        // 2. Create the "הוצאות" spreadsheet inside that folder
        final sheetName = AppConstants.spreadsheetDefaultName;
        final spreadsheet = drive.File()
          ..name = sheetName
          ..mimeType = 'application/vnd.google-apps.spreadsheet'
          ..parents = [createdFolder.id!];

        final createdSheet = await driveApi.files.create(
          spreadsheet,
          $fields: 'id, name',
        );

        debugPrint('StorageSetup: created spreadsheet ${createdSheet.id}');

        // 2b. Rename the auto-created default tab ("גיליון1" / "Sheet1")
        // to the current year's expenses tab name so the first write
        // finds it immediately (SheetsService also handles this gracefully).
        try {
          final sheetsApi = sheets.SheetsApi(client);
          final ss = await sheetsApi.spreadsheets.get(createdSheet.id!);
          final defaultSheet = ss.sheets?.first;
          if (defaultSheet?.properties != null) {
            final currentYear = DateTime.now().year;
            final yearTabName =
                '${AppConstants.expensesTabPrefix} $currentYear';
            await sheetsApi.spreadsheets.batchUpdate(
              sheets.BatchUpdateSpreadsheetRequest(requests: [
                sheets.Request(
                  updateSheetProperties: sheets.UpdateSheetPropertiesRequest(
                    properties: sheets.SheetProperties(
                      sheetId: defaultSheet!.properties!.sheetId,
                      title: yearTabName,
                    ),
                    fields: 'title',
                  ),
                ),
              ]),
              createdSheet.id!,
            );
            debugPrint('StorageSetup: renamed default tab → "$yearTabName"');
          }
        } catch (e) {
          debugPrint('StorageSetup: could not rename default tab: $e');
          // Not fatal — SheetsService will create year tabs as needed
        }

        // 3. Save all IDs to StorageConfigService
        final configService = StorageConfigService.instance;

        await configService.setFolderConfig(
          folderId: createdFolder.id!,
          folderName: folderName,
        );

        await configService.setSpreadsheetConfig(
          spreadsheetId: createdSheet.id!,
          spreadsheetName: sheetName,
        );

        final email = AuthService.instance.currentUser?.email;
        if (email != null) {
          await configService.setAccountEmail(email);
        }
      } finally {
        client.close();
      }

      // 4. Navigate to the main app
      if (mounted) {
        Navigator.of(context).pushAndRemoveUntil(
          MaterialPageRoute(builder: (_) => const CameraCaptureScreen()),
          (_) => false,
        );
      }
    } catch (e) {
      debugPrint('StorageSetup: creation failed: $e');
      if (mounted) {
        setState(() {
          _error = 'שגיאה ביצירת התיקייה: $e';
          _isCreating = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      body: SafeArea(
        child: _isCreating ? _buildCreatingState(theme) : _buildSetupForm(theme),
      ),
    );
  }

  Widget _buildCreatingState(ThemeData theme) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(
              width: 56,
              height: 56,
              child: CircularProgressIndicator(strokeWidth: 3),
            ),
            const SizedBox(height: 28),
            Text(
              'מכינים הכל בשבילכם...',
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w600,
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 8),
            Text(
              'יוצרים תיקייה וגיליון ב-Google Drive.\nזה ייקח רק רגע.',
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
                height: 1.5,
              ),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSetupForm(ThemeData theme) {
    return SingleChildScrollView(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SizedBox(height: 24),

          // Icon
          Center(
            child: Container(
              width: 88,
              height: 88,
              decoration: BoxDecoration(
                color: theme.colorScheme.primaryContainer,
                borderRadius: BorderRadius.circular(22),
              ),
              child: Icon(
                widget.isRelink ? Icons.refresh : Icons.auto_awesome,
                size: 44,
                color: theme.colorScheme.primary,
              ),
            ),
          ),
          const SizedBox(height: 28),

          // Welcome text or relink message
          if (widget.isRelink) ...[
            Text(
              'צריך לחבר מחדש',
              style: theme.textTheme.headlineSmall?.copyWith(
                fontWeight: FontWeight.bold,
                color: theme.colorScheme.error,
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 12),
            Text(
              'לא הצלחנו לגשת לתיקייה או לגיליון שהיו מקושרים.\n'
              'לא נורא — ניצור חדשים ותוכלו להמשיך כרגיל.',
              style: theme.textTheme.bodyLarge?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
                height: 1.6,
              ),
              textAlign: TextAlign.center,
            ),
          ] else ...[
            Text(
              'כמעט מוכנים! 🎉',
              style: theme.textTheme.headlineSmall?.copyWith(
                fontWeight: FontWeight.bold,
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 16),
            Text(
              'עוד שנייה ותוכלו להתחיל לצלם קבלות.\n\n'
              'אנחנו ניצור לכם תיקייה בשם "הוצאות" ב-Google Drive '
              'שתכיל את כל הקבלות, מסודרות לפי חודש וקטגוריה.\n'
              'בתוכה יהיה גם גיליון Google Sheets שירכז את כל ההוצאות במקום אחד — '
              'ככה תמיד תדעו בדיוק לאן הכסף הולך.',
              style: theme.textTheme.bodyLarge?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
                height: 1.7,
              ),
              textAlign: TextAlign.center,
            ),
          ],

          const SizedBox(height: 32),

          // What will be created — visual summary
          Card(
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(16),
            ),
            color: theme.colorScheme.primaryContainer.withValues(alpha: 0.3),
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: Column(
                children: [
                  Text(
                    'מה ייווצר?',
                    style: theme.textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.bold,
                      color: theme.colorScheme.primary,
                    ),
                  ),
                  const SizedBox(height: 16),
                  _buildInfoRow(
                    theme,
                    Icons.folder,
                    'תיקיית Drive',
                    '"${AppConstants.driveRootFolderDefaultName}"',
                  ),
                  const SizedBox(height: 12),
                  _buildInfoRow(
                    theme,
                    Icons.table_chart,
                    'גיליון Sheets',
                    '"${AppConstants.spreadsheetDefaultName}"',
                  ),
                  const SizedBox(height: 16),
                  Row(
                    children: [
                      Icon(
                        Icons.info_outline,
                        size: 16,
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          'התיקייה תיווצר ב-Drive הראשי. אפשר להזיז אותה אחר כך לאן שתרצו.',
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                            height: 1.4,
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),

          // Error message
          if (_error != null) ...[
            const SizedBox(height: 16),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: theme.colorScheme.errorContainer,
                borderRadius: BorderRadius.circular(10),
              ),
              child: Row(
                children: [
                  Icon(Icons.error_outline,
                      color: theme.colorScheme.error, size: 20),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      _error!,
                      style: TextStyle(
                        color: theme.colorScheme.onErrorContainer,
                        fontSize: 13,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],

          const SizedBox(height: 28),

          // Continue button
          SizedBox(
            width: double.infinity,
            height: 56,
            child: ElevatedButton(
              onPressed: _isCreating ? null : _createResources,
              style: ElevatedButton.styleFrom(
                backgroundColor: theme.colorScheme.primary,
                foregroundColor: theme.colorScheme.onPrimary,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(16),
                ),
              ),
              child: Text(
                widget.isRelink ? 'צור מחדש והמשך' : 'בואו נתחיל!',
                style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
              ),
            ),
          ),

          const SizedBox(height: 24),
        ],
      ),
    );
  }

  Widget _buildInfoRow(
    ThemeData theme,
    IconData icon,
    String label,
    String value,
  ) {
    return Row(
      children: [
        Icon(icon, size: 22, color: theme.colorScheme.primary),
        const SizedBox(width: 10),
        Text(
          '$label: ',
          style: theme.textTheme.bodyMedium?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        Flexible(
          child: Text(
            value,
            style: theme.textTheme.bodyMedium?.copyWith(
              fontWeight: FontWeight.bold,
            ),
          ),
        ),
      ],
    );
  }
}
