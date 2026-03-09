"""
Receipts backend — tiny FastAPI service.

Endpoints:
  POST /processReceipt  — accepts image + metadata, runs OCR + LLM, returns structured JSON.
  POST /parseReceipt     — accepts raw OCR text + metadata, runs LLM only, returns structured JSON.
  GET  /health           — health check.

Run:
  uvicorn main:app --host 0.0.0.0 --port 8080
"""

import logging
import os

from dotenv import load_dotenv
from fastapi import Depends, FastAPI, File, Form, UploadFile, HTTPException
from fastapi.middleware.cors import CORSMiddleware

from schemas import ProcessReceiptRequest, ProcessReceiptResponse, FieldConfidences
from ocr_service import extract_text_from_image
from llm_parser import parse_receipt_text
from image_quality import check_image_quality
from receipt_validator import validate_ocr_text
from validation_responses import build_validation_failure
from auth import require_auth

load_dotenv()

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

app = FastAPI(title="Receipts Backend", version="1.0.0")

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_methods=["*"],
    allow_headers=["*"],
)


@app.get("/health")
async def health():
    return {"status": "ok"}


@app.post("/processReceipt", response_model=ProcessReceiptResponse)
async def process_receipt(
    image: UploadFile = File(...),
    receipt_id: str = Form(...),
    locale_hint: str = Form(default="he-IL"),
    currency_default: str = Form(default="ILS"),
    timezone: str = Form(default="Asia/Jerusalem"),
    user_email: str = Depends(require_auth),
):
    """
    Full pipeline: Image → quality checks → OCR → receipt validation → LLM parse → structured JSON.
    
    The app sends the receipt image + metadata.
    Backend runs image quality checks, Cloud Vision OCR, receipt validation,
    then LLM extraction, returns fields + confidences.
    Validation failures return early without calling the LLM.
    """
    # 1. Read image bytes
    image_bytes = await image.read()
    if len(image_bytes) == 0:
        raise HTTPException(status_code=400, detail="Empty image file")
    
    if len(image_bytes) > 20 * 1024 * 1024:  # 20 MB limit
        raise HTTPException(status_code=400, detail="Image too large (max 20 MB)")

    logger.info(f"Processing receipt {receipt_id}: {len(image_bytes)} bytes (user: {user_email})")

    # 2. Image quality checks (BEFORE OCR to save API calls)
    quality_result = check_image_quality(image_bytes)
    if not quality_result["passed"]:
        reason = quality_result["reason"]
        logger.warning(
            f"Image quality failed for {receipt_id}: {reason} "
            f"(details: {quality_result['details']})"
        )
        return build_validation_failure(receipt_id, reason)

    # 3. OCR
    try:
        language_hints = []
        if locale_hint.startswith("he"):
            language_hints = ["he", "en"]
        elif locale_hint.startswith("en"):
            language_hints = ["en"]
        else:
            language_hints = [locale_hint[:2], "en"]

        ocr_text = extract_text_from_image(image_bytes, language_hints)
        logger.info(f"OCR for {receipt_id}: {len(ocr_text)} chars extracted")
    except Exception as e:
        logger.error(f"OCR failed for {receipt_id}: {e}")
        raise HTTPException(status_code=502, detail=f"OCR failed: {e}")

    if not ocr_text.strip():
        logger.warning(f"No text extracted for {receipt_id}")
        return build_validation_failure(receipt_id, "unreadable_receipt")

    # 4. OCR quality + receipt-likeliness validation (BEFORE LLM)
    validation_result = validate_ocr_text(ocr_text)
    if not validation_result["passed"]:
        reason = validation_result["reason"] or "unreadable_receipt"
        logger.warning(
            f"Receipt validation failed for {receipt_id}: {reason} "
            f"(score: {validation_result['score']}, signals: {validation_result['signals']})"
        )
        return build_validation_failure(receipt_id, reason)

    # 5. LLM Parse (only reached if all validation passed)
    try:
        parsed = parse_receipt_text(
            ocr_text=ocr_text,
            receipt_id=receipt_id,
            locale_hint=locale_hint,
            currency_default=currency_default,
        )
    except Exception as e:
        logger.error(f"LLM parsing failed for {receipt_id}: {e}")
        return ProcessReceiptResponse(
            receipt_id=receipt_id,
            raw_ocr_text=ocr_text,
            confidence=FieldConfidences(overall=0.0),
            error=f"LLM parsing failed: {e}",
        )

    # 6. Build success response
    conf = parsed.get("confidence", {})
    return ProcessReceiptResponse(
        receipt_id=parsed.get("receipt_id", receipt_id),
        status="ok",
        merchant_name=parsed.get("merchant_name"),
        receipt_date=parsed.get("receipt_date"),
        total_amount=parsed.get("total_amount"),
        currency=parsed.get("currency", currency_default),
        category=parsed.get("category"),
        raw_ocr_text=ocr_text,
        confidence=FieldConfidences(
            merchant_name=conf.get("merchant_name", 0.0),
            receipt_date=conf.get("receipt_date", 0.0),
            total_amount=conf.get("total_amount", 0.0),
            currency=conf.get("currency", 0.0),
            overall=conf.get("overall", 0.0),
        ),
        error=parsed.get("error"),
    )


@app.post("/ocrOnly")
async def ocr_only(
    image: UploadFile = File(...),
    locale_hint: str = Form(default="he-IL"),
    user_email: str = Depends(require_auth),
):
    """
    OCR-only endpoint: Image → Cloud Vision OCR → raw text.
    Used for PDF page-by-page processing where OCR and LLM are separate steps.
    """
    image_bytes = await image.read()
    if len(image_bytes) == 0:
        raise HTTPException(status_code=400, detail="Empty image file")

    if len(image_bytes) > 20 * 1024 * 1024:
        raise HTTPException(status_code=400, detail="Image too large (max 20 MB)")

    language_hints = []
    if locale_hint.startswith("he"):
        language_hints = ["he", "en"]
    elif locale_hint.startswith("en"):
        language_hints = ["en"]
    else:
        language_hints = [locale_hint[:2], "en"]

    try:
        ocr_text = extract_text_from_image(image_bytes, language_hints)
        logger.info(f"OCR-only: {len(ocr_text)} chars extracted (user: {user_email})")
    except Exception as e:
        logger.error(f"OCR-only failed: {e}")
        raise HTTPException(status_code=502, detail=f"OCR failed: {e}")

    return {"ocr_text": ocr_text}


@app.post("/parseReceipt", response_model=ProcessReceiptResponse)
async def parse_receipt_endpoint(
    receipt_id: str = Form(...),
    ocr_text: str = Form(...),
    locale_hint: str = Form(default="he-IL"),
    currency_default: str = Form(default="ILS"),
    timezone: str = Form(default="Asia/Jerusalem"),
    user_email: str = Depends(require_auth),
):
    """
    LLM-only pipeline: takes raw OCR text, returns structured JSON.
    Use this if OCR was done elsewhere.
    """
    if not ocr_text.strip():
        return ProcessReceiptResponse(
            receipt_id=receipt_id,
            raw_ocr_text="",
            confidence=FieldConfidences(overall=0.0),
            error="Empty OCR text",
        )

    try:
        parsed = parse_receipt_text(
            ocr_text=ocr_text,
            receipt_id=receipt_id,
            locale_hint=locale_hint,
            currency_default=currency_default,
        )
    except Exception as e:
        logger.error(f"LLM parsing failed for {receipt_id}: {e}")
        return ProcessReceiptResponse(
            receipt_id=receipt_id,
            raw_ocr_text=ocr_text,
            confidence=FieldConfidences(overall=0.0),
            error=f"LLM parsing failed: {e}",
        )

    conf = parsed.get("confidence", {})
    return ProcessReceiptResponse(
        receipt_id=parsed.get("receipt_id", receipt_id),
        status="ok",
        merchant_name=parsed.get("merchant_name"),
        receipt_date=parsed.get("receipt_date"),
        total_amount=parsed.get("total_amount"),
        currency=parsed.get("currency", currency_default),
        category=parsed.get("category"),
        raw_ocr_text=ocr_text,
        confidence=FieldConfidences(
            merchant_name=conf.get("merchant_name", 0.0),
            receipt_date=conf.get("receipt_date", 0.0),
            total_amount=conf.get("total_amount", 0.0),
            currency=conf.get("currency", 0.0),
            overall=conf.get("overall", 0.0),
        ),
        error=parsed.get("error"),
    )


if __name__ == "__main__":
    import uvicorn
    host = os.environ.get("HOST", "0.0.0.0")
    port = int(os.environ.get("PORT", 8080))
    uvicorn.run(app, host=host, port=port)
