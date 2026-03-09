"""
LLM-based receipt parser.
Takes raw OCR text and returns structured JSON fields.

Two-tier model strategy to minimise cost:
  1. Primary model (gpt-4.1-nano) — fast and cheap, handles ~80%+ of receipts.
  2. Escalation model (gpt-4.1-mini) — used only when the primary model
     reports low confidence, ensuring quality without overspending.

No internal retries — transient failures are retried by the sync engine
with exponential backoff.
"""

import json
import os
import logging
from typing import Optional

from openai import OpenAI
from schemas import FieldConfidences

logger = logging.getLogger(__name__)

# ── Model configuration ──────────────────────────────────────────────────────
PRIMARY_MODEL = os.environ.get("LLM_MODEL_PRIMARY", "gpt-4.1-nano")
ESCALATION_MODEL = os.environ.get("LLM_MODEL_ESCALATION", "gpt-4.1-mini")

# If the primary model's overall confidence is below this, re-run with
# the escalation model.  Tuned so ≥80% of standard receipts (clear text,
# common merchants) stay on the primary model — they typically score 0.7–0.95.
ESCALATION_THRESHOLD = float(os.environ.get("ESCALATION_THRESHOLD", "0.6"))

SYSTEM_PROMPT = """אתה מערכת לחילוץ נתונים מקבלות. אתה מקבל טקסט גולמי מ-OCR של קבלה ומחזיר JSON מובנה.

כללים:
1. החזר את כל הערכים בעברית כאשר רלוונטי (שם עסק, קטגוריה).
2. תאריך הקבלה בפורמט ISO: YYYY-MM-DD
3. פורמט תאריך ישראלי: dd/mm/yyyy (יום לפני חודש). כלומר 05/03/2025 = 5 במרץ 2025.
4. הסכום הכולל הוא הסכום הסופי לתשלום (כולל מע"מ).
5. מטבע ברירת מחדל: ILS (אלא אם מופיע מטבע אחר בקבלה).
6. דרג את הביטחון שלך בכל שדה מ-0.0 עד 1.0.
7. אם שדה לא ניתן לחילוץ, החזר null עם ביטחון 0.0.
8. קטגוריה — בחר מתוך הרשימה הבאה בלבד:
   שכירות, חשבונות, תקשורת, תחזוקה, בית, הוצאות משרדיות, ביטוחים, הדרכה והתפתחות, פרסום, טכנולוגיה, רכב ודלק, קניות, מזון, ביגוד, פנאי, בילויים, בריאות, תחבורה ציבורית, טיולים, טיפוח, אחר.

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
) -> dict:
    """
    Send OCR text to LLM, get structured receipt data back.

    Two-tier strategy:
      1. Call PRIMARY_MODEL (cheap).
      2. If overall confidence < ESCALATION_THRESHOLD, call ESCALATION_MODEL.
    """
    result = _call_llm(
        ocr_text=ocr_text,
        receipt_id=receipt_id,
        model=PRIMARY_MODEL,
        locale_hint=locale_hint,
        currency_default=currency_default,
    )

    if result.get("error"):
        return result

    overall = result.get("confidence", {}).get("overall", 0.0)
    if overall < ESCALATION_THRESHOLD:
        logger.info(
            f"Escalating {receipt_id}: {PRIMARY_MODEL} confidence {overall:.2f} "
            f"< {ESCALATION_THRESHOLD} — retrying with {ESCALATION_MODEL}"
        )
        result = _call_llm(
            ocr_text=ocr_text,
            receipt_id=receipt_id,
            model=ESCALATION_MODEL,
            locale_hint=locale_hint,
            currency_default=currency_default,
        )

    return result


def _call_llm(
    ocr_text: str,
    receipt_id: str,
    model: str,
    locale_hint: str = "he-IL",
    currency_default: str = "ILS",
) -> dict:
    """Single LLM call.  Returns normalised result or error dict."""
    client = OpenAI(api_key=os.environ.get("OPENAI_API_KEY"))

    user_message = f"""טקסט OCR מקבלה (מזהה: {receipt_id}):
---
{ocr_text}
---

מטבע ברירת מחדל: {currency_default}
שפה: {locale_hint}

חלץ את הנתונים והחזר JSON בלבד."""

    try:
        response = client.chat.completions.create(
            model=model,
            messages=[
                {"role": "system", "content": SYSTEM_PROMPT},
                {"role": "user", "content": user_message},
            ],
            temperature=0.1,
            max_tokens=1000,
            response_format={"type": "json_object"},
        )

        raw_response = response.choices[0].message.content.strip()
        parsed = json.loads(raw_response)

        result = _normalize_parsed(parsed, receipt_id, currency_default)
        logger.info(
            f"LLM ({model}) for {receipt_id}: "
            f"overall_confidence={result['confidence']['overall']:.2f}"
        )
        return result

    except Exception as e:
        logger.error(f"LLM call failed ({model}) for {receipt_id}: {e}")
        return _error_response(receipt_id, f"LLM error ({model}): {e}")


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
