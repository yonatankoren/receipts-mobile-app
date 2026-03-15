/// Receipt data model.
/// Maps to the `receipts` table in SQLite and the row in Google Sheets.

class Receipt {
  final String id; // UUID, stable across all systems
  final DateTime captureTimestamp;
  String imagePath; // Local file path (JPEG thumbnail for display)
  String? pdfPath; // Original PDF file path (null for photo receipts)
  String? merchantName;
  String? receiptDate; // ISO date YYYY-MM-DD
  double? totalAmount;
  String currency;
  String? category;
  String? driveFileId;
  String? driveFileLink;
  String? rawOcrText;
  double? overallConfidence;
  Map<String, double>? fieldConfidences; // JSON map
  ReceiptStatus status;
  String? sourceType; // camera, gallery, pdf, share
  DateTime createdAt;
  DateTime updatedAt;

  Receipt({
    required this.id,
    required this.captureTimestamp,
    required this.imagePath,
    this.pdfPath,
    this.merchantName,
    this.receiptDate,
    this.totalAmount,
    this.currency = '',
    this.category,
    this.driveFileId,
    this.driveFileLink,
    this.rawOcrText,
    this.overallConfidence,
    this.fieldConfidences,
    this.status = ReceiptStatus.captured,
    this.sourceType,
    DateTime? createdAt,
    DateTime? updatedAt,
  })  : createdAt = createdAt ?? DateTime.now(),
        updatedAt = updatedAt ?? DateTime.now();

  /// Month key for grouping: "YYYY-MM"
  String get monthKey {
    final date = receiptDate != null
        ? DateTime.tryParse(receiptDate!) ?? captureTimestamp
        : captureTimestamp;
    return '${date.year}-${date.month.toString().padLeft(2, '0')}';
  }

  /// Drive folder name for this receipt's month
  String get driveFolderName => monthKey;

  /// Whether all sync jobs are complete
  bool get isFullySynced => status == ReceiptStatus.synced;

  /// Whether the receipt has been processed (OCR + parse done)
  bool get isProcessed =>
      status == ReceiptStatus.reviewed ||
      status == ReceiptStatus.synced ||
      rawOcrText != null;

  /// Parse a DB timestamp that may be int (epoch ms) or ISO-8601 string.
  static DateTime _parseDateTime(dynamic value) {
    if (value == null) return DateTime.now();
    if (value is int) return DateTime.fromMillisecondsSinceEpoch(value);
    if (value is String) return DateTime.tryParse(value) ?? DateTime.now();
    return DateTime.now();
  }

  // --- Serialization ---

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'capture_timestamp': captureTimestamp.millisecondsSinceEpoch,
      'image_path': imagePath,
      'pdf_path': pdfPath,
      'merchant_name': merchantName,
      'receipt_date': receiptDate,
      'total_amount': totalAmount,
      'currency': currency,
      'category': category,
      'drive_file_id': driveFileId,
      'drive_file_link': driveFileLink,
      'raw_ocr_text': rawOcrText,
      'overall_confidence': overallConfidence,
      'field_confidences': fieldConfidences != null
          ? _encodeConfidences(fieldConfidences!)
          : null,
      'status': status.name,
      'source_type': sourceType,
      'created_at': createdAt.millisecondsSinceEpoch,
      'updated_at': updatedAt.millisecondsSinceEpoch,
    };
  }

  factory Receipt.fromMap(Map<String, dynamic> map) {
    return Receipt(
      id: map['id'] as String,
      captureTimestamp:
          DateTime.fromMillisecondsSinceEpoch(map['capture_timestamp'] as int),
      imagePath: map['image_path'] as String,
      pdfPath: map['pdf_path'] as String?,
      merchantName: map['merchant_name'] as String?,
      receiptDate: map['receipt_date'] as String?,
      totalAmount: map['total_amount'] != null
          ? (map['total_amount'] as num).toDouble()
          : null,
      currency: (map['currency'] as String?) ?? '',
      category: map['category'] as String?,
      driveFileId: map['drive_file_id'] as String?,
      driveFileLink: map['drive_file_link'] as String?,
      rawOcrText: map['raw_ocr_text'] as String?,
      overallConfidence: map['overall_confidence'] != null
          ? (map['overall_confidence'] as num).toDouble()
          : null,
      fieldConfidences: map['field_confidences'] != null
          ? _decodeConfidences(map['field_confidences'] as String)
          : null,
      status: ReceiptStatus.values.firstWhere(
        (e) => e.name == (map['status'] as String? ?? 'captured'),
        orElse: () => ReceiptStatus.captured,
      ),
      sourceType: map['source_type'] as String?,
      createdAt: map['created_at'] != null
          ? DateTime.fromMillisecondsSinceEpoch(map['created_at'] as int)
          : DateTime.now(),
      updatedAt: _parseDateTime(map['updated_at']),
    );
  }

  Receipt copyWith({
    String? merchantName,
    String? receiptDate,
    double? totalAmount,
    String? currency,
    String? category,
    String? driveFileId,
    String? driveFileLink,
    String? rawOcrText,
    double? overallConfidence,
    Map<String, double>? fieldConfidences,
    ReceiptStatus? status,
    String? imagePath,
    String? pdfPath,
    String? sourceType,
    bool clearPdfPath = false,
  }) {
    return Receipt(
      id: id,
      captureTimestamp: captureTimestamp,
      imagePath: imagePath ?? this.imagePath,
      pdfPath: clearPdfPath ? null : (pdfPath ?? this.pdfPath),
      merchantName: merchantName ?? this.merchantName,
      receiptDate: receiptDate ?? this.receiptDate,
      totalAmount: totalAmount ?? this.totalAmount,
      currency: currency ?? this.currency,
      category: category ?? this.category,
      driveFileId: driveFileId ?? this.driveFileId,
      driveFileLink: driveFileLink ?? this.driveFileLink,
      rawOcrText: rawOcrText ?? this.rawOcrText,
      overallConfidence: overallConfidence ?? this.overallConfidence,
      fieldConfidences: fieldConfidences ?? this.fieldConfidences,
      status: status ?? this.status,
      sourceType: sourceType ?? this.sourceType,
      createdAt: createdAt,
      updatedAt: DateTime.now(),
    );
  }

  /// Encode confidence map to a simple "key:val,key:val" string for SQLite
  static String _encodeConfidences(Map<String, double> map) {
    return map.entries.map((e) => '${e.key}:${e.value}').join(',');
  }

  static Map<String, double> _decodeConfidences(String encoded) {
    if (encoded.isEmpty) return {};
    final map = <String, double>{};
    for (final part in encoded.split(',')) {
      final kv = part.split(':');
      if (kv.length == 2) {
        map[kv[0]] = double.tryParse(kv[1]) ?? 0.0;
      }
    }
    return map;
  }

  /// Sheets month value in MM/YYYY format (e.g. "03/2025").
  String get sheetsMonth {
    final date = receiptDate != null
        ? DateTime.tryParse(receiptDate!) ?? captureTimestamp
        : captureTimestamp;
    return '${date.month.toString().padLeft(2, '0')}/${date.year}';
  }

  /// The receipt year (e.g. 2025).
  int get receiptYear {
    final date = receiptDate != null
        ? DateTime.tryParse(receiptDate!) ?? captureTimestamp
        : captureTimestamp;
    return date.year;
  }

  /// Numeric sort key for the month: YYYYMM (e.g. 202503).
  int get monthSortKey {
    final date = receiptDate != null
        ? DateTime.tryParse(receiptDate!) ?? captureTimestamp
        : captureTimestamp;
    return date.year * 100 + date.month;
  }

  /// Row values matching the 7-column Sheets layout:
  /// חודש | שם עסק | סכום | מטבע | קטגוריה | קישור לתמונה | מזהה
  List<dynamic> toSheetsRow() {
    // Use HYPERLINK formula so the cell shows short text instead of a raw URL
    final linkCell = (driveFileLink != null && driveFileLink!.isNotEmpty)
        ? '=HYPERLINK("${driveFileLink!}","צפה בקובץ")'
        : '';

    return [
      sheetsMonth,
      merchantName ?? '',
      totalAmount?.toString() ?? '',
      currency,
      category ?? '',
      linkCell,
      id,
    ];
  }
}

enum ReceiptStatus {
  captured,    // Photo taken, not yet processed
  processing,  // OCR/parse in progress
  reviewed,    // User reviewed, ready to sync
  synced,      // Fully synced (Drive + Sheets)
  error,       // Processing failed
}

