"""
Image quality checks for receipt images.

Runs lightweight heuristics BEFORE OCR to reject clearly bad images
(blurry, too dark, too small) without wasting API calls.

Uses Pillow + numpy — no OpenCV dependency.
"""

import io
import logging
from typing import Optional

import numpy as np
from PIL import Image

logger = logging.getLogger(__name__)

# ── Configurable thresholds ──────────────────────────────────────────────────
BLUR_LAPLACIAN_THRESHOLD = 50.0        # Below this → blurry (lowered to reduce false positives)
BRIGHTNESS_TOO_DARK = 40.0            # Average grayscale below this → too dark
MIN_WIDTH = 200                        # Minimum image width in pixels
MIN_HEIGHT = 200                       # Minimum image height in pixels


def check_image_quality(image_bytes: bytes) -> dict:
    """
    Run image quality checks on raw image bytes.

    Returns:
        {
            "passed": bool,
            "reason": str | None,       # machine-readable reason if failed
            "details": {
                "width": int,
                "height": int,
                "blur_score": float,
                "avg_brightness": float,
            }
        }
    """
    try:
        img = Image.open(io.BytesIO(image_bytes))
    except Exception as e:
        logger.warning(f"Image quality: cannot open image: {e}")
        return {
            "passed": False,
            "reason": "invalid_image",
            "details": {"error": str(e)},
        }

    # Record original dimensions for the resolution check
    orig_width, orig_height = img.size

    # Downsample to ≤800×800 for analysis — blur detection and brightness
    # work identically on a thumbnail, but use ~15× less memory and CPU.
    img.thumbnail((800, 800))

    width, height = orig_width, orig_height

    # Convert to grayscale for analysis
    gray = img.convert("L")
    gray_array = np.array(gray, dtype=np.float64)

    # ── Resolution check ─────────────────────────────────────────────────
    if width < MIN_WIDTH or height < MIN_HEIGHT:
        logger.info(
            f"Image quality: too small ({width}x{height}), "
            f"min {MIN_WIDTH}x{MIN_HEIGHT}"
        )
        return _result(False, "image_too_small", width, height, 0.0, 0.0)

    # ── Brightness check ─────────────────────────────────────────────────
    avg_brightness = float(np.mean(gray_array))

    if avg_brightness < BRIGHTNESS_TOO_DARK:
        logger.info(
            f"Image quality: too dark (avg brightness {avg_brightness:.1f}, "
            f"threshold {BRIGHTNESS_TOO_DARK})"
        )
        return _result(False, "image_too_dark", width, height, 0.0, avg_brightness)

    # ── Blur detection (variance of Laplacian) ───────────────────────────
    blur_score = _laplacian_variance(gray_array)

    if blur_score < BLUR_LAPLACIAN_THRESHOLD:
        logger.info(
            f"Image quality: blurry (laplacian variance {blur_score:.1f}, "
            f"threshold {BLUR_LAPLACIAN_THRESHOLD})"
        )
        return _result(False, "blurry_image", width, height, blur_score, avg_brightness)

    # ── All checks passed ────────────────────────────────────────────────
    logger.info(
        f"Image quality: passed "
        f"(size {width}x{height}, blur {blur_score:.1f}, brightness {avg_brightness:.1f})"
    )
    return _result(True, None, width, height, blur_score, avg_brightness)


def _laplacian_variance(gray_array: np.ndarray) -> float:
    """
    Compute variance of Laplacian as a blur metric.
    Higher value = sharper image, lower value = blurrier.

    Uses a simple 3x3 Laplacian kernel convolved via numpy.
    """
    # Laplacian kernel
    # [0,  1, 0]
    # [1, -4, 1]
    # [0,  1, 0]
    h, w = gray_array.shape

    if h < 3 or w < 3:
        return 0.0

    # Pad-free Laplacian via shifted arrays
    center = gray_array[1:-1, 1:-1]
    top = gray_array[:-2, 1:-1]
    bottom = gray_array[2:, 1:-1]
    left = gray_array[1:-1, :-2]
    right = gray_array[1:-1, 2:]

    laplacian = top + bottom + left + right - 4.0 * center

    return float(np.var(laplacian))


def _result(
    passed: bool,
    reason: Optional[str],
    width: int,
    height: int,
    blur_score: float,
    avg_brightness: float,
) -> dict:
    return {
        "passed": passed,
        "reason": reason,
        "details": {
            "width": width,
            "height": height,
            "blur_score": round(blur_score, 2),
            "avg_brightness": round(avg_brightness, 2),
        },
    }
