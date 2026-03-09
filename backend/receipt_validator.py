"""
Post-OCR receipt validation.

Computes a receipt-likeliness score from OCR text using rule-based heuristics.
Decides whether the text looks enough like a receipt to justify an LLM call.

All thresholds are constants at the top for easy tuning.
"""

import logging
import re
from typing import Optional

logger = logging.getLogger(__name__)

# ── Configurable thresholds ──────────────────────────────────────────────────
MIN_TEXT_LENGTH = 15              # Below this → almost certainly not useful
GOOD_TEXT_LENGTH = 30             # At least this many chars → +1 point
MIN_TEXT_LINES = 3                # At least this many lines → +1 point
PASS_SCORE = 4                    # Minimum score to proceed to LLM
GARBAGE_RATIO_THRESHOLD = 0.5     # If more than 50% non-useful chars → negative signal

# ── Hebrew receipt keywords ──────────────────────────────────────────────────
HEBREW_KEYWORDS = [
    'סה"כ',      # total
    'סה״כ',      # total (alternative quotation mark)
    'סהכ',       # total (no quotes, common OCR miss)
    'מע"מ',      # VAT
    'מע״מ',      # VAT (alternative)
    'מעמ',       # VAT (no quotes)
    'תאריך',     # date
    'קבלה',      # receipt
    'חשבונית',   # invoice
    'סכום',      # amount
    'לתשלום',    # payable / to pay
    'שולם',      # paid
    'תשלום',     # payment
    'מזומן',     # cash
    'אשראי',     # credit
    'עוסק',      # business (עוסק מורשה / עוסק פטור)
    'ח.פ',       # company number
    'ע.מ',       # authorized dealer
]

# ── English receipt keywords (case-insensitive matching) ─────────────────────
ENGLISH_KEYWORDS = [
    'total',
    'vat',
    'date',
    'receipt',
    'invoice',
    'amount',
    'payable',
    'subtotal',
    'tax',
    'change',
    'cash',
    'credit',
    'visa',
    'mastercard',
]

# ── VAT-specific keywords (stronger signal) ─────────────────────────────────
VAT_KEYWORDS = ['מע"מ', 'מע״מ', 'מעמ', 'vat', 'tax']

# ── Regex patterns ───────────────────────────────────────────────────────────
# Amount patterns: 123.45 or 123,45 or ₪123 etc.
AMOUNT_PATTERN = re.compile(
    r'(?:₪|NIS|ILS)?\s*\d+[.,]\d{1,2}'
    r'|\d+[.,]\d{1,2}\s*(?:₪|NIS|ILS)?',
    re.IGNORECASE,
)

# Date patterns: dd/mm/yyyy, dd-mm-yyyy, dd.mm.yyyy, etc.
DATE_PATTERN = re.compile(
    r'\d{1,2}[/.\-]\d{1,2}[/.\-]\d{2,4}'
)

# Any number pattern (for "has any numbers at all" check)
ANY_NUMBER_PATTERN = re.compile(r'\d+')

# Useful characters: letters (any script), digits, common punctuation
USEFUL_CHAR_PATTERN = re.compile(r'[\w\d.,;:!?₪$€\-/\'"()%+]', re.UNICODE)


def validate_ocr_text(ocr_text: str) -> dict:
    """
    Validate OCR text for receipt-likeliness.

    Returns:
        {
            "passed": bool,
            "score": int,
            "reason": str | None,       # machine-readable reason if failed
            "signals": {
                "text_length": int,
                "line_count": int,
                "has_amounts": bool,
                "amount_count": int,
                "has_dates": bool,
                "hebrew_keywords_found": list[str],
                "english_keywords_found": list[str],
                "has_vat_keyword": bool,
                "garbage_ratio": float,
                "has_any_numbers": bool,
            }
        }
    """
    text = ocr_text.strip()
    text_lower = text.lower()

    # ── Gather signals ───────────────────────────────────────────────────
    text_length = len(text)
    lines = [l for l in text.split('\n') if l.strip()]
    line_count = len(lines)

    amounts = AMOUNT_PATTERN.findall(text)
    dates = DATE_PATTERN.findall(text)
    has_any_numbers = bool(ANY_NUMBER_PATTERN.search(text))

    hebrew_kw_found = [kw for kw in HEBREW_KEYWORDS if kw in text]
    english_kw_found = [kw for kw in ENGLISH_KEYWORDS if kw in text_lower]
    has_vat = any(kw in text_lower or kw in text for kw in VAT_KEYWORDS)

    # Garbage ratio: fraction of characters that are not "useful"
    if text_length > 0:
        useful_count = len(USEFUL_CHAR_PATTERN.findall(text))
        garbage_ratio = 1.0 - (useful_count / text_length)
    else:
        garbage_ratio = 1.0

    signals = {
        "text_length": text_length,
        "line_count": line_count,
        "has_amounts": len(amounts) > 0,
        "amount_count": len(amounts),
        "has_dates": len(dates) > 0,
        "hebrew_keywords_found": hebrew_kw_found,
        "english_keywords_found": english_kw_found,
        "has_vat_keyword": has_vat,
        "garbage_ratio": round(garbage_ratio, 3),
        "has_any_numbers": has_any_numbers,
    }

    # ── Compute score ────────────────────────────────────────────────────
    score = 0

    # Positive signals
    if text_length >= GOOD_TEXT_LENGTH:
        score += 1
    if line_count >= MIN_TEXT_LINES:
        score += 1
    if len(amounts) > 0:
        score += 1
    if len(dates) > 0:
        score += 1
    if len(hebrew_kw_found) > 0 or len(english_kw_found) > 0:
        score += 1
    if has_vat:
        score += 1

    # Negative signals
    if text_length < MIN_TEXT_LENGTH:
        score -= 2
    if not has_any_numbers:
        score -= 2
    if len(hebrew_kw_found) == 0 and len(english_kw_found) == 0:
        score -= 1
    if len(hebrew_kw_found) == 0 and len(english_kw_found) == 0 and not has_vat:
        score -= 1  # Extra penalty: no receipt keywords at all
    if len(amounts) == 0:
        score -= 1  # Receipts almost always have decimal amounts
    if garbage_ratio > GARBAGE_RATIO_THRESHOLD:
        score -= 1

    # ── Determine pass/fail ──────────────────────────────────────────────
    passed = score >= PASS_SCORE
    reason = _determine_reason(passed, score, signals)

    logger.info(
        f"Receipt validation: score={score}, passed={passed}, "
        f"reason={reason}, text_len={text_length}, lines={line_count}, "
        f"amounts={len(amounts)}, dates={len(dates)}, "
        f"he_kw={len(hebrew_kw_found)}, en_kw={len(english_kw_found)}"
    )

    return {
        "passed": passed,
        "score": score,
        "reason": reason,
        "signals": signals,
    }


def _determine_reason(passed: bool, score: int, signals: dict) -> Optional[str]:
    """Determine the most specific failure reason for user feedback."""
    if passed:
        return None

    # Very little text — probably unreadable
    if signals["text_length"] < MIN_TEXT_LENGTH:
        return "unreadable_receipt"

    # No numbers at all and no receipt keywords — probably not a receipt
    if not signals["has_any_numbers"] and not signals["hebrew_keywords_found"] and not signals["english_keywords_found"]:
        return "non_receipt_image"

    # Has some text but no receipt-like patterns
    if not signals["has_amounts"] and not signals["has_any_numbers"]:
        return "non_receipt_image"

    # Some text and numbers but no receipt keywords or structure
    if not signals["hebrew_keywords_found"] and not signals["english_keywords_found"] and not signals["has_amounts"]:
        return "non_receipt_image"

    # Default: unreadable receipt (has some signals but not enough)
    return "unreadable_receipt"

