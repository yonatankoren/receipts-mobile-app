"""
Pydantic schemas for /processReceipt API.
Shared contract between backend and Flutter app.
"""

from pydantic import BaseModel, Field
from typing import Optional


class ProcessReceiptRequest(BaseModel):
    """Metadata sent alongside the receipt image."""
    receipt_id: str = Field(..., description="Stable UUID from the mobile app")
    locale_hint: str = Field(default="he-IL", description="OCR language hint")
    currency_default: str = Field(default="ILS", description="Fallback currency")
    timezone: str = Field(default="Asia/Jerusalem")


class FieldConfidences(BaseModel):
    merchant_name: float = Field(default=0.0, ge=0.0, le=1.0)
    receipt_date: float = Field(default=0.0, ge=0.0, le=1.0)
    total_amount: float = Field(default=0.0, ge=0.0, le=1.0)
    currency: float = Field(default=0.0, ge=0.0, le=1.0)
    overall: float = Field(default=0.0, ge=0.0, le=1.0)


class ProcessReceiptResponse(BaseModel):
    receipt_id: str
    status: str = "ok"                          # "ok" | "needs_retry" | "not_receipt"
    reason: Optional[str] = None                # machine-readable failure reason
    message_he: Optional[str] = None            # Hebrew user-facing message on failure
    merchant_name: Optional[str] = None
    receipt_date: Optional[str] = None          # ISO date string YYYY-MM-DD
    total_amount: Optional[float] = None
    currency: str = "ILS"
    category: Optional[str] = None
    raw_ocr_text: str = ""
    confidence: FieldConfidences = Field(default_factory=FieldConfidences)
    error: Optional[str] = None


# --- Google Sheets column schema (Hebrew) ---
# These are the headers for the Google Sheet.
# The app appends rows matching this order.
SHEETS_COLUMNS = [
    "מזהה קבלה",      # receipt_id (A)
    "תאריך צילום",     # capture_timestamp (B)
    "שם עסק",         # merchant_name (C)
    "תאריך קבלה",     # receipt_date (D)
    "סכום",           # total_amount (E)
    "מטבע",           # currency (F)
    "קטגוריה",        # category (G)
    "קישור לדרייב",   # drive_file_link (H)
    "ביטחון כללי",    # overall confidence (I)
]

