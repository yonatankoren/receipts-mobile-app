/// App-wide constants and configuration defaults.

class AppConstants {
  AppConstants._();

  // --- Default backend URL (override in Settings) ---
  static const String defaultBackendUrl = 'https://receipts-backend-416729458155.me-west1.run.app'; 

  // --- Google Drive folder structure ---
  static const String driveFolderRoot = 'Receipts';
  // Subfolders created as: Receipts/YYYY-MM/

  // --- Google Sheets ---
  static const List<String> sheetsHeaders = [
    'חודש',
    'שם עסק',
    'סכום',
    'מטבע',
    'קטגוריה',
    'קישור לתמונה',
  ];

  /// Number of data columns in the main sheet
  static const int sheetsColumnCount = 6; // A–F

  /// Name of the totals summary tab
  static const String totalSheetName = 'סיכום';

  /// Month background colors (1-indexed: Jan=1 … Dec=12).
  /// Light pastels in a smooth visual progression.
  static const Map<int, List<int>> monthColors = {
    1:  [0xDC, 0xEE, 0xFB], // Light Blue
    2:  [0xE8, 0xDE, 0xF8], // Light Lavender
    3:  [0xFC, 0xE4, 0xEC], // Light Pink
    4:  [0xFF, 0xF3, 0xE0], // Light Peach
    5:  [0xFF, 0xFD, 0xE7], // Light Yellow
    6:  [0xF1, 0xF8, 0xE9], // Light Lime
    7:  [0xE8, 0xF5, 0xE9], // Light Green
    8:  [0xE0, 0xF2, 0xF1], // Light Teal
    9:  [0xE0, 0xF7, 0xFA], // Light Cyan
    10: [0xE3, 0xF2, 0xFD], // Light Sky
    11: [0xE8, 0xEA, 0xF6], // Light Indigo
    12: [0xEC, 0xEF, 0xF1], // Light Grey-Blue
  };

  // --- Job queue ---
  static const int maxJobRetries = 5;
  static const Duration initialRetryDelay = Duration(seconds: 5);
  static const double retryBackoffMultiplier = 2.0;

  // --- Categories (Hebrew) ---
  static const List<String> categories = [
    'מזון',
    'מסעדות',
    'תחבורה',
    'דלק',
    'קניות',
    'בריאות',
    'חשבונות',
    'בילויים',
    'אחר',
  ];

  // --- Google OAuth Scopes ---
  static const List<String> googleScopes = [
    'https://www.googleapis.com/auth/drive.file',
    'https://www.googleapis.com/auth/spreadsheets',
  ];

  // --- Currency default ---
  static const String defaultCurrency = 'ILS';
  static const String defaultLocale = 'he-IL';
  static const String defaultTimezone = 'Asia/Jerusalem';
}

