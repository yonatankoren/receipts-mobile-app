"""
Structured validation failure responses.

Centralized builders for each validation failure type so that
main.py stays clean and all Hebrew messages live in one place.
"""

from schemas import ProcessReceiptResponse, FieldConfidences

# ── Failure reason → Hebrew user-facing message ─────────────────────────────
FAILURE_MESSAGES = {
    "blurry_image": "התמונה מטושטשת מדי. נסה לצלם שוב.",
    "image_too_dark": "התמונה חשוכה מדי. נסה לצלם במקום מואר יותר.",
    "image_too_small": "התמונה קטנה מדי. נסה לצלם ברזולוציה גבוהה יותר.",
    "unreadable_receipt": "לא הצלחנו לקרוא את הקבלה. נסה לצלם שוב כך שכל הקבלה תופיע בבירור.",
    "non_receipt_image": "נראה שהתמונה אינה קבלה.",
    "invalid_image": "לא ניתן לפתוח את הקובץ כתמונה. נסה לצלם שוב.",
}

# ── Reasons that indicate "not a receipt" vs "needs retry" ───────────────────
NOT_RECEIPT_REASONS = {"non_receipt_image"}


def build_validation_failure(
    receipt_id: str,
    reason: str,
) -> ProcessReceiptResponse:
    """
    Build a ProcessReceiptResponse for a validation failure.
    
    Sets status to 'not_receipt' or 'needs_retry' based on the reason,
    and includes the appropriate Hebrew message.
    """
    status = "not_receipt" if reason in NOT_RECEIPT_REASONS else "needs_retry"
    message_he = FAILURE_MESSAGES.get(reason, "שגיאה בעיבוד התמונה. נסה שוב.")

    return ProcessReceiptResponse(
        receipt_id=receipt_id,
        status=status,
        reason=reason,
        message_he=message_he,
        raw_ocr_text="",
        confidence=FieldConfidences(overall=0.0),
    )

