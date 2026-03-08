/// Exception thrown when the backend rejects a receipt image
/// due to quality or content validation failure.
///
/// Carries structured info from the backend so the UI can show
/// a user-friendly Hebrew message and appropriate action buttons.

class ReceiptValidationException implements Exception {
  /// "needs_retry" or "not_receipt"
  final String status;

  /// Machine-readable reason, e.g. "blurry_image", "non_receipt_image"
  final String reason;

  /// Hebrew user-facing message from the backend
  final String messageHe;

  /// The receipt ID that was being processed
  final String receiptId;

  const ReceiptValidationException({
    required this.status,
    required this.reason,
    required this.messageHe,
    required this.receiptId,
  });

  bool get isRetryable => status == 'needs_retry';
  bool get isNotReceipt => status == 'not_receipt';

  @override
  String toString() =>
      'ReceiptValidationException($status, $reason): $messageHe';
}


