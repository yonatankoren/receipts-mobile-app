/// Settings Screen — Google sign-in, configuration, debug info.
///
/// Features:
///   - Google Sign-In status + button
///   - Backend URL configuration
///   - Spreadsheet ID configuration
///   - Drive folder info
///   - Debug: storage usage, pending jobs, recent errors

import 'package:flutter/material.dart';
import '../services/auth_service.dart';
import '../services/backend_service.dart';
import '../services/sheets_service.dart';
import '../services/sync_engine.dart';
import '../services/image_service.dart';
import '../db/database_helper.dart';
import '../utils/constants.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  final _backendUrlController = TextEditingController();
  final _spreadsheetIdController = TextEditingController();
  final _sheetNameController = TextEditingController();

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

  @override
  void dispose() {
    _backendUrlController.dispose();
    _spreadsheetIdController.dispose();
    _sheetNameController.dispose();
    super.dispose();
  }

  Future<void> _loadSettings() async {
    final backendUrl = await BackendService.instance.getBackendUrl();
    final spreadsheetId = await SheetsService.instance.getSpreadsheetId();
    final sheetName = await SheetsService.instance.getSheetName();
    final pendingJobs = await DatabaseHelper.instance.getPendingJobCount();
    final receipts = await DatabaseHelper.instance.getAllReceipts();
    final storageBytes = await ImageService.instance.getTotalStorageBytes();
    final healthy = await BackendService.instance.isHealthy();

    if (mounted) {
      setState(() {
        _backendUrlController.text = backendUrl;
        _spreadsheetIdController.text = spreadsheetId ?? '';
        _sheetNameController.text = sheetName;
        _pendingJobs = pendingJobs;
        _totalReceipts = receipts.length;
        _storageUsage = _formatBytes(storageBytes);
        _backendHealthy = healthy;
        _isLoading = false;
      });
    }
  }

  Future<void> _saveSettings() async {
    await BackendService.instance.setBackendUrl(_backendUrlController.text);
    await SheetsService.instance
        .setSpreadsheetId(_spreadsheetIdController.text);
    await SheetsService.instance.setSheetName(_sheetNameController.text);

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('ההגדרות נשמרו ✓'),
          backgroundColor: Colors.green,
        ),
      );
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

                // Backend Configuration
                _buildSectionHeader(theme, 'שרת Backend', Icons.dns),
                Card(
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      children: [
                        TextField(
                          controller: _backendUrlController,
                          decoration: InputDecoration(
                            labelText: 'כתובת השרת',
                            hintText: AppConstants.defaultBackendUrl,
                            prefixIcon: const Icon(Icons.link),
                            suffixIcon: Icon(
                              _backendHealthy
                                  ? Icons.check_circle
                                  : Icons.error,
                              color: _backendHealthy
                                  ? Colors.green
                                  : Colors.red,
                            ),
                            border: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(12),
                            ),
                          ),
                          keyboardType: TextInputType.url,
                        ),
                        const SizedBox(height: 8),
                        Text(
                          _backendHealthy
                              ? 'השרת פעיל ✓'
                              : 'השרת לא זמין',
                          style: TextStyle(
                            color:
                                _backendHealthy ? Colors.green : Colors.red,
                            fontSize: 13,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 24),

                // Google Sheets Configuration
                _buildSectionHeader(
                    theme, 'Google Sheets', Icons.table_chart),
                Card(
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      children: [
                        TextField(
                          controller: _spreadsheetIdController,
                          decoration: InputDecoration(
                            labelText: 'מזהה הגיליון (Spreadsheet ID)',
                            hintText: 'מזהה מה-URL של הגיליון',
                            prefixIcon: const Icon(Icons.key),
                            border: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(12),
                            ),
                          ),
                        ),
                        const SizedBox(height: 12),
                        TextField(
                          controller: _sheetNameController,
                          decoration: InputDecoration(
                            labelText: 'שם הגיליון (Tab)',
                            hintText: 'קבלות',
                            prefixIcon: const Icon(Icons.tab),
                            border: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(12),
                            ),
                          ),
                        ),
                      ],
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
                const SizedBox(height: 24),

                // Force sync button
                SizedBox(
                  width: double.infinity,
                  height: 48,
                  child: OutlinedButton.icon(
                    onPressed: () {
                      SyncEngine.instance.runPendingJobs();
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('מסנכרן...')),
                      );
                    },
                    icon: const Icon(Icons.sync),
                    label: const Text('סנכרן עכשיו'),
                  ),
                ),
                const SizedBox(height: 12),

                // Save button
                SizedBox(
                  width: double.infinity,
                  height: 54,
                  child: ElevatedButton.icon(
                    onPressed: _saveSettings,
                    icon: const Icon(Icons.save),
                    label: const Text('שמור הגדרות',
                        style: TextStyle(fontSize: 16)),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Theme.of(context).colorScheme.primary,
                      foregroundColor: Colors.white,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(14),
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 32),
              ],
            ),
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

