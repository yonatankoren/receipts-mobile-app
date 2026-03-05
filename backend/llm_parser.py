"""
LLM-based receipt parser.
Takes raw OCR text and returns structured JSON fields.

The LLM is responsible for understanding varied receipt layouts,
Hebrew text, and extracting structured data. OCR just provides raw text.
"""

import json
import os
import logging
from typing import Optional

from openai import OpenAI
from schemas import FieldConfidences

logger = logging.getLogger(__name__)

SYSTEM_PROMPT = """אתה מערכת לחילוץ נתונים מקבלות. אתה מקבל טקסט גולמי מ-OCR של קבלה ומחזיר JSON מובנה.

כללים:
1. החזר את כל הערכים בעברית כאשר רלוונטי (שם עסק, קטגוריה).
2. תאריך הקבלה בפורמט ISO: YYYY-MM-DD
3. הסכום הכולל הוא הסכום הסופי לתשלום (כולל מע"מ).
4. מטבע ברירת מחדל: ILS (אלא אם מופיע מטבע אחר בקבלה).
5. דרג את הביטחון שלך בכל שדה מ-0.0 עד 1.0.
6. אם שדה לא ניתן לחילוץ, החזר null עם ביטחון 0.0.
7. קטגוריה: נסה לזהות (מזון, תחבורה, קניות, מסעדות, דלק, בריאות, אחר). אם לא בטוח, החזר null.

החזר אך ורק JSON תקין בפורמט הבא, ללא טקסט נוסף:
{
  "merchant_name": "שם העסק או null",
  "receipt_date": "YYYY-MM-DD או null",
  "total_amount": 123.45,
  "currency": "ILS",
  "category": "קטגוריה או null",
  "confidence": {
    "merchant_name": 0.95,
    "receipt_date": 0.90,
    "total_amount": 0.85,
    "currency": 0.99,
    "overall": 0.92
  }
}"""


def parse_receipt_text(
    ocr_text: str,
    receipt_id: str,
    locale_hint: str = "he-IL",
    currency_default: str = "ILS",
    retry_count: int = 0,
) -> dict:
    """
    Send OCR text to LLM, get structured receipt data back.
    
    Implements validation + retry:
    - First attempt: standard prompt
    - If JSON invalid, retry once with stricter instructions
    - If still invalid, return best-effort with low confidence + error message
    """
    client = OpenAI(api_key=os.environ.get("OPENAI_API_KEY"))
    model = os.environ.get("LLM_MODEL", "gpt-4o")

    user_message = f"""טקסט OCR מקבלה (מזהה: {receipt_id}):
---
{ocr_text}
---

מטבע ברירת מחדל: {currency_default}
שפה: {locale_hint}

חלץ את הנתונים והחזר JSON בלבד."""

    if retry_count > 0:
        user_message += "\n\nחשוב מאוד: החזר אך ורק JSON תקין. ללא הסברים, ללא markdown, רק JSON."

    try:
        response = client.chat.completions.create(
            model=model,
            messages=[
                {"role": "system", "content": SYSTEM_PROMPT},
                {"role": "user", "content": user_message},
            ],
            temperature=0.1,  # Low temperature for deterministic extraction
            max_tokens=1000,
            response_format={"type": "json_object"},
        )

        raw_response = response.choices[0].message.content.strip()
        parsed = json.loads(raw_response)

        # Validate and normalize the response
        return _normalize_parsed(parsed, receipt_id, currency_default)

    except json.JSONDecodeError as e:
        if retry_count < 1:
            logger.warning(f"JSON parse failed for {receipt_id}, retrying: {e}")
            return parse_receipt_text(
                ocr_text, receipt_id, locale_hint, currency_default,
                retry_count=retry_count + 1,
            )
        logger.error(f"JSON parse failed after retry for {receipt_id}: {e}")
        return _error_response(receipt_id, f"JSON parsing failed: {e}")

    except Exception as e:
        if retry_count < 1:
            logger.warning(f"LLM call failed for {receipt_id}, retrying: {e}")
            return parse_receipt_text(
                ocr_text, receipt_id, locale_hint, currency_default,
                retry_count=retry_count + 1,
            )
        logger.error(f"LLM call failed after retry for {receipt_id}: {e}")
        return _error_response(receipt_id, f"LLM error: {e}")


def _normalize_parsed(parsed: dict, receipt_id: str, currency_default: str) -> dict:
    """Validate and normalize the LLM output to match our schema."""
    confidence = parsed.get("confidence", {})
    
    return {
        "receipt_id": receipt_id,
        "merchant_name": parsed.get("merchant_name"),
        "receipt_date": parsed.get("receipt_date"),
        "total_amount": _safe_float(parsed.get("total_amount")),
        "currency": parsed.get("currency", currency_default),
        "category": parsed.get("category"),
        "confidence": {
            "merchant_name": _clamp(confidence.get("merchant_name", 0.0)),
            "receipt_date": _clamp(confidence.get("receipt_date", 0.0)),
            "total_amount": _clamp(confidence.get("total_amount", 0.0)),
            "currency": _clamp(confidence.get("currency", 0.0)),
            "overall": _clamp(confidence.get("overall", 0.0)),
        },
        "error": None,
    }


def _error_response(receipt_id: str, error_msg: str) -> dict:
    """Return a best-effort response with low confidence when parsing fails."""
    return {
        "receipt_id": receipt_id,
        "merchant_name": None,
        "receipt_date": None,
        "total_amount": None,
        "currency": "ILS",
        "category": None,
        "confidence": {
            "merchant_name": 0.0,
            "receipt_date": 0.0,
            "total_amount": 0.0,
            "currency": 0.0,
            "overall": 0.0,
        },
        "error": error_msg,
    }


def _safe_float(val) -> Optional[float]:
    if val is None:
        return None
    try:
        return float(val)
    except (ValueError, TypeError):
        return None


def _clamp(val, lo=0.0, hi=1.0) -> float:
    try:
        return max(lo, min(hi, float(val)))
    except (ValueError, TypeError):
        return 0.0

