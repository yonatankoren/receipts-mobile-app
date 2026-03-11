/// App-wide constants and configuration defaults.

class AppConstants {
  AppConstants._();

  // --- Default backend URL (override in Settings) ---
  static const String defaultBackendUrl = 'https://receipts-backend-416729458155.me-west1.run.app'; 

  // --- Google Drive folder structure ---
  static const String driveFolderRoot = 'הוצאות';
  static const String driveRootFolderDefaultName = 'הוצאות';
  static const String spreadsheetDefaultName = 'הוצאות';
  // Subfolders created as: הוצאות/YYYY-MM/category/

  // --- Google Sheets ---
  static const List<String> sheetsHeaders = [
    'חודש',
    'שם עסק',
    'סכום',
    'מטבע',
    'קטגוריה',
    'קישור לתמונה',
    'מזהה',
  ];

  /// Number of data columns in the main sheet
  static const int sheetsColumnCount = 7; // A–G

  /// Default tab name for the main receipts sheet (no longer used as fixed name;
  /// tabs are now year-based: "הוצאות YYYY").
  static const String sheetsDefaultTabName = 'קבלות';

  /// Prefix for per-year expenses tab
  static const String expensesTabPrefix = 'הוצאות';

  /// Prefix for per-year totals tab
  static const String totalsTabPrefix = 'סיכום';

  /// Hebrew month names (0-indexed: Jan=0 … Dec=11).
  static const List<String> hebrewMonthNames = [
    'ינואר', 'פברואר', 'מרץ', 'אפריל', 'מאי', 'יוני',
    'יולי', 'אוגוסט', 'ספטמבר', 'אוקטובר', 'נובמבר', 'דצמבר',
  ];

  /// Month background colors (1-indexed: Jan=1 … Dec=12).
  /// Medium-light pastels — saturated enough to visually distinguish months,
  /// while still readable with black text.
  static const Map<int, List<int>> monthColors = {
    1:  [0xBB, 0xDE, 0xFB], // Blue
    2:  [0xCE, 0xB8, 0xEF], // Lavender
    3:  [0xF8, 0xBB, 0xD0], // Pink
    4:  [0xFF, 0xE0, 0xB2], // Peach
    5:  [0xFF, 0xF5, 0x9D], // Yellow
    6:  [0xDC, 0xED, 0xC8], // Lime
    7:  [0xC8, 0xE6, 0xC9], // Green
    8:  [0xB2, 0xDF, 0xDB], // Teal
    9:  [0xB2, 0xEB, 0xF2], // Cyan
    10: [0x90, 0xCA, 0xF9], // Deeper Sky Blue
    11: [0xC5, 0xCA, 0xE9], // Indigo
    12: [0xCF, 0xD8, 0xDC], // Grey-Blue
  };

  // --- Job queue ---
  static const int maxJobRetries = 5;
  static const Duration initialRetryDelay = Duration(seconds: 5);
  static const double retryBackoffMultiplier = 2.0;

  // --- Categories (Hebrew, alphabetical) ---
  static const List<String> categories = [
    'אחר',
    'ביגוד',
    'ביטוחים',
    'בילויים',
    'בית',
    'בריאות',
    'הדרכה והתפתחות',
    'הוצאות משרדיות',
    'חיות מחמד',
    'חשבונות',
    'טיולים',
    'טיפוח',
    'טכנולוגיה',
    'ילדים',
    'מזון',
    'פנאי',
    'פרסום',
    'קניות',
    'רכב ודלק',
    'שכירות',
    'תחבורה ציבורית',
    'תחזוקה',
    'תקשורת',
  ];

  // --- Google OAuth Scopes ---
  // drive.file — only accesses files/folders created by this app (recommended scope).
  // Users can freely move the created folder anywhere in their Drive.
  static const List<String> googleScopes = [
    'https://www.googleapis.com/auth/drive.file',
    'https://www.googleapis.com/auth/spreadsheets',
  ];

  // --- Currency default ---
  static const String defaultCurrency = 'ILS';
  static const String defaultLocale = 'he-IL';
  static const String defaultTimezone = 'Asia/Jerusalem';
}

