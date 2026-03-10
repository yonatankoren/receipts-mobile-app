/// Export Months Screen — lets user select months to export as ZIP.
///
/// Features:
///   - Year selector (only years with receipts)
///   - Month list with checkboxes and receipt counts
///   - Disabled months (0 receipts) with elegant styling
///   - "שלח" button (always visible)
///   - "שלח לרואה החשבון" button (if accountant email configured)
///   - First-time educational popup
///   - Info icon when accountant not configured

import 'package:flutter/material.dart';

import '../db/database_helper.dart';
import '../services/accountant_config_service.dart';
import '../services/auth_service.dart';
import '../services/export_service.dart';
import '../services/share_service.dart';
import '../utils/constants.dart';
import '../widgets/loading_indicator.dart';
import 'settings_screen.dart';

class ExportMonthsScreen extends StatefulWidget {
  const ExportMonthsScreen({super.key});

  @override
  State<ExportMonthsScreen> createState() => _ExportMonthsScreenState();
}

class _ExportMonthsScreenState extends State<ExportMonthsScreen> {
  bool _isLoading = true;
  Map<String, int> _monthCounts = {}; // "YYYY-MM" → count
  List<int> _availableYears = [];
  int _selectedYear = DateTime.now().year;
  final Set<String> _selectedMonths = {};

  @override
  void initState() {
    super.initState();
    _loadData();
    _checkFirstTimePopup();
  }

  Future<void> _loadData() async {
    // Only count receipts synced to Drive — those are the ones we can export.
    final counts = await DatabaseHelper.instance.getMonthCountsSynced();
    final years = <int>{};
    for (final key in counts.keys) {
      final parts = key.split('-');
      if (parts.length == 2) {
        years.add(int.tryParse(parts[0]) ?? DateTime.now().year);
      }
    }

    final sortedYears = years.toList()..sort((a, b) => b.compareTo(a));

    if (mounted) {
      setState(() {
        _monthCounts = counts;
        _availableYears = sortedYears;
        _selectedYear =
            sortedYears.isNotEmpty ? sortedYears.first : DateTime.now().year;
        _isLoading = false;
      });
    }
  }

  // ─── First-time popup ────────────────────────────────────────

  void _checkFirstTimePopup() {
    final config = AccountantConfigService.instance;
    if (!config.hasSeenExportIntro) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _showFirstTimePopup();
      });
    }
  }

  void _showFirstTimePopup() {
    AccountantConfigService.instance.markExportIntroSeen();
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 8),
            Container(
              width: 64,
              height: 64,
              decoration: BoxDecoration(
                color: Colors.blue.shade50,
                shape: BoxShape.circle,
              ),
              child: Icon(
                Icons.lightbulb_outline,
                color: Colors.blue.shade400,
                size: 32,
              ),
            ),
            const SizedBox(height: 20),
            const Text(
              'טיפ קטן 💡',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 12),
            const Text(
              'אפשר להגדיר את כתובת המייל של רואה החשבון '
              'בהגדרות, ואז לשלוח קבלות ישירות ב-Gmail '
              'בלחיצה אחת.',
              style: TextStyle(fontSize: 15, height: 1.6),
              textAlign: TextAlign.center,
              textDirection: TextDirection.rtl,
            ),
          ],
        ),
        actionsAlignment: MainAxisAlignment.center,
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('הבנתי'),
          ),
          ElevatedButton(
            onPressed: () {
              Navigator.pop(ctx);
              Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const SettingsScreen()),
              );
            },
            style: ElevatedButton.styleFrom(
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
            ),
            child: const Text('פתח הגדרות'),
          ),
        ],
      ),
    );
  }

  // ─── Accountant info popup ───────────────────────────────────

  void _showAccountantInfoPopup() {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 8),
            Icon(Icons.mail_outline, color: Colors.blue.shade400, size: 40),
            const SizedBox(height: 16),
            const Text(
              'ניתן להגדיר את כתובת המייל של רואה החשבון '
              'בהגדרות, וכך לשלוח קבלות ישירות דרך Gmail.',
              style: TextStyle(fontSize: 15, height: 1.6),
              textAlign: TextAlign.center,
              textDirection: TextDirection.rtl,
            ),
          ],
        ),
        actionsAlignment: MainAxisAlignment.center,
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('הבנתי'),
          ),
          ElevatedButton(
            onPressed: () {
              Navigator.pop(ctx);
              Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const SettingsScreen()),
              );
            },
            style: ElevatedButton.styleFrom(
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
            ),
            child: const Text('פתח הגדרות'),
          ),
        ],
      ),
    );
  }

  // ─── Month helpers ───────────────────────────────────────────

  int _getMonthCount(int month) {
    final key = '$_selectedYear-${month.toString().padLeft(2, '0')}';
    return _monthCounts[key] ?? 0;
  }

  void _toggleMonth(int month) {
    final key = '$_selectedYear-${month.toString().padLeft(2, '0')}';
    setState(() {
      if (_selectedMonths.contains(key)) {
        _selectedMonths.remove(key);
      } else {
        _selectedMonths.add(key);
      }
    });
  }

  // ─── Export flow ─────────────────────────────────────────────

  Future<void> _startExport({required bool viaGmail}) async {
    if (_selectedMonths.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('בחר לפחות חודש אחד לייצוא'),
          backgroundColor: Colors.orange,
        ),
      );
      return;
    }

    final progressNotifier = ValueNotifier<String>('אוסף את הקבלות…');
    _showLoadingOverlay(progressNotifier);

    try {
      // Get user name for ZIP filename
      final userName =
          AuthService.instance.currentUser?.displayName ?? 'User';

      // Create ZIP
      final zipPath = await ExportService.instance.createExportZip(
        monthKeys: _selectedMonths.toList(),
        userName: userName,
        onProgress: (msg) => progressNotifier.value = msg,
      );

      if (!mounted) return;
      Navigator.of(context).pop(); // dismiss loading

      // Share or send via Gmail
      if (viaGmail) {
        final config = AccountantConfigService.instance;
        final months = _selectedMonths.toList()..sort();
        final subject = 'קבלות ${_formatMonthsForSubject(months)}';

        await ShareService.sendViaGmail(
          filePath: zipPath,
          recipientEmail: config.accountantEmail!,
          ccEmails: config.ccEmails,
          subject: subject,
        );
      } else {
        await ShareService.shareFile(filePath: zipPath);
      }
    } catch (e) {
      if (mounted) {
        // Dismiss loading if still showing
        if (Navigator.of(context).canPop()) {
          Navigator.of(context).pop();
        }
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('משהו השתבש. נסה שוב.'),
            backgroundColor: Colors.red,
          ),
        );
        debugPrint('ExportMonthsScreen: export failed: $e');
      }
    } finally {
      progressNotifier.dispose();
    }
  }

  String _formatMonthsForSubject(List<String> monthKeys) {
    return monthKeys.map((mk) {
      final parts = mk.split('-');
      return '${parts[1]}/${parts[0].substring(2)}';
    }).join(', ');
  }

  void _showLoadingOverlay(ValueNotifier<String> progressNotifier) {
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
                      style: TextStyle(
                        fontSize: 15,
                        color: Colors.grey.shade600,
                        fontWeight: FontWeight.w500,
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

  // ─── Build ───────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: const Text('ייצוא קבלות'),
        actions: [
          // Info icon — disappears once accountant email is set
          ListenableBuilder(
            listenable: AccountantConfigService.instance,
            builder: (context, _) {
              if (AccountantConfigService.instance.hasAccountantEmail) {
                return const SizedBox.shrink();
              }
              return IconButton(
                icon: Icon(
                  Icons.info_outline,
                  color: theme.colorScheme.primary.withValues(alpha: 0.6),
                  size: 22,
                ),
                tooltip: 'הגדרת רואה חשבון',
                onPressed: _showAccountantInfoPopup,
              );
            },
          ),
        ],
      ),
      body: _isLoading
          ? const Center(child: LoadingIndicator(message: 'טוען נתונים…'))
          : _availableYears.isEmpty
              ? _buildEmptyState(theme)
              : Column(
                  children: [
                    Expanded(
                      child: ListView(
                        padding: const EdgeInsets.symmetric(horizontal: 16),
                        children: [
                          const SizedBox(height: 16),
                          _buildYearSelector(theme),
                          const SizedBox(height: 20),
                          ...List.generate(
                            12,
                            (i) => _buildMonthTile(theme, i + 1),
                          ),
                          const SizedBox(height: 16),
                        ],
                      ),
                    ),
                    // Bottom buttons — reactive to accountant config changes
                    ListenableBuilder(
                      listenable: AccountantConfigService.instance,
                      builder: (context, _) => _buildBottomButtons(theme),
                    ),
                  ],
                ),
    );
  }

  // ─── Empty state ─────────────────────────────────────────────

  Widget _buildEmptyState(ThemeData theme) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.receipt_long, size: 72, color: Colors.grey.shade300),
          const SizedBox(height: 16),
          Text(
            'אין קבלות לייצוא',
            style: theme.textTheme.titleLarge?.copyWith(
              color: Colors.grey.shade500,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'צלם קבלות כדי שתוכל לייצא אותן',
            style: theme.textTheme.bodyMedium?.copyWith(
              color: Colors.grey.shade400,
            ),
          ),
        ],
      ),
    );
  }

  // ─── Year selector ──────────────────────────────────────────

  Widget _buildYearSelector(ThemeData theme) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: _availableYears.map((year) {
        final isSelected = year == _selectedYear;
        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4),
          child: ChoiceChip(
            label: Text('$year'),
            selected: isSelected,
            onSelected: (_) {
              setState(() {
                _selectedYear = year;
                // Clear selections from other years
                _selectedMonths
                    .removeWhere((mk) => !mk.startsWith('$year-'));
              });
            },
            selectedColor: theme.colorScheme.primary,
            labelStyle: TextStyle(
              color: isSelected ? Colors.white : theme.colorScheme.onSurface,
              fontWeight: FontWeight.w600,
            ),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(20),
            ),
          ),
        );
      }).toList(),
    );
  }

  // ─── Month tile ─────────────────────────────────────────────

  Widget _buildMonthTile(ThemeData theme, int month) {
    final count = _getMonthCount(month);
    final isEnabled = count > 0;
    final monthKey = '$_selectedYear-${month.toString().padLeft(2, '0')}';
    final isSelected = _selectedMonths.contains(monthKey);
    final monthName = AppConstants.hebrewMonthNames[month - 1];

    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: isEnabled ? () => _toggleMonth(month) : null,
          borderRadius: BorderRadius.circular(12),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(12),
              color: isSelected
                  ? theme.colorScheme.primary.withValues(alpha: 0.06)
                  : null,
            ),
            child: Row(
              children: [
                // Checkbox
                _buildCheckbox(isEnabled, isSelected, theme),
                const SizedBox(width: 14),
                // Month name
                Expanded(
                  child: Text(
                    monthName,
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight:
                          isEnabled ? FontWeight.w500 : FontWeight.w400,
                      color: isEnabled
                          ? theme.colorScheme.onSurface
                          : theme.colorScheme.onSurface
                              .withValues(alpha: 0.35),
                    ),
                  ),
                ),
                // Receipt count badge
                if (count > 0)
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 4,
                    ),
                    decoration: BoxDecoration(
                      color: isSelected
                          ? theme.colorScheme.primary
                              .withValues(alpha: 0.12)
                          : theme.colorScheme.surfaceContainerHighest,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Text(
                      '$count',
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: isSelected
                            ? theme.colorScheme.primary
                            : theme.colorScheme.onSurfaceVariant,
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

  Widget _buildCheckbox(bool isEnabled, bool isSelected, ThemeData theme) {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 200),
      width: 22,
      height: 22,
      decoration: BoxDecoration(
        color: isSelected ? theme.colorScheme.primary : Colors.transparent,
        border: Border.all(
          color: isEnabled
              ? (isSelected
                  ? theme.colorScheme.primary
                  : Colors.grey.shade400)
              : Colors.grey.shade300,
          width: 2,
        ),
        borderRadius: BorderRadius.circular(6),
      ),
      child: isSelected
          ? const Icon(Icons.check_rounded, size: 16, color: Colors.white)
          : null,
    );
  }

  // ─── Bottom buttons ─────────────────────────────────────────

  Widget _buildBottomButtons(ThemeData theme) {
    final hasAccountant = AccountantConfigService.instance.hasAccountantEmail;

    return Container(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 12),
      decoration: BoxDecoration(
        color: theme.scaffoldBackgroundColor,
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.06),
            blurRadius: 8,
            offset: const Offset(0, -2),
          ),
        ],
      ),
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // שלח — always visible
            SizedBox(
              width: double.infinity,
              height: 50,
              child: ElevatedButton.icon(
                onPressed: () => _startExport(viaGmail: false),
                icon: const Icon(Icons.share_outlined, size: 20),
                label: const Text(
                  'שלח',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
                ),
                style: ElevatedButton.styleFrom(
                  backgroundColor: theme.colorScheme.primary,
                  foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14),
                  ),
                ),
              ),
            ),
            // שלח לרואה החשבון — only if accountant configured
            if (hasAccountant) ...[
              const SizedBox(height: 10),
              SizedBox(
                width: double.infinity,
                height: 50,
                child: OutlinedButton.icon(
                  onPressed: () => _startExport(viaGmail: true),
                  icon: const Icon(Icons.email_outlined, size: 20),
                  label: const Text(
                    'שלח לרואה החשבון',
                    style:
                        TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
                  ),
                  style: OutlinedButton.styleFrom(
                    side: BorderSide(color: theme.colorScheme.primary),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14),
                    ),
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
