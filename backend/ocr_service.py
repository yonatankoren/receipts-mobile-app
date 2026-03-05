"""
Google Cloud Vision OCR service.
Uses Document Text Detection for best results with receipts.

Decision: OCR runs on the backend (not on-device).
Reasons:
  1. GCP API key stays server-side — no secrets in the Flutter app.
  2. Simpler mobile code — app just sends image bytes.
  3. Backend can chain OCR → LLM in one request, fewer round-trips.
  4. Easier to swap OCR provider later without app update.
"""

from typing import List, Optional

from google.cloud import vision


def extract_text_from_image(image_bytes: bytes, language_hints: Optional[List[str]] = None) -> str:
    """
    Run Document Text Detection on raw image bytes.
    Returns the full extracted text string.
    
    Uses DOCUMENT_TEXT_DETECTION (not TEXT_DETECTION) because:
    - Better at understanding document layout / paragraphs
    - Superior handling of multi-line receipts
    - Better Hebrew support with proper reading order
    """
    client = vision.ImageAnnotatorClient()

    image = vision.Image(content=image_bytes)

    # Build image context with language hints for Hebrew
    image_context = vision.ImageContext(
        language_hints=language_hints or ["he", "en"]
    )

    response = client.document_text_detection(
        image=image,
        image_context=image_context,
    )

    if response.error.message:
        raise RuntimeError(
            f"Cloud Vision API error: {response.error.message}"
        )

    # full_text_annotation gives the best structured result
    if response.full_text_annotation:
        return response.full_text_annotation.text

    # Fallback to text_annotations[0] if full_text not available
    if response.text_annotations:
        return response.text_annotations[0].description

    return ""

