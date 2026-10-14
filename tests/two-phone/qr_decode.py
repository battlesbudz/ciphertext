#!/usr/bin/env python3
"""Decode a SimpleX invitation QR code from a screenshot PNG.

Usage: qr_decode.py <screenshot.png>
Prints the first decoded QR payload containing 'simplex' to stdout.
Exits 0 on success, 1 if no usable QR code found.
"""
import sys

import cv2


def main() -> int:
    if len(sys.argv) != 2:
        print("usage: qr_decode.py <screenshot.png>", file=sys.stderr)
        return 1
    img = cv2.imread(sys.argv[1])
    if img is None:
        print(f"could not read image: {sys.argv[1]}", file=sys.stderr)
        return 1
    detector = cv2.QRCodeDetector()
    # Try the plain image first, then upscaled + grayscale variants.
    candidates = [img]
    gray = cv2.cvtColor(img, cv2.COLOR_BGR2GRAY)
    candidates.append(gray)
    candidates.append(cv2.resize(gray, None, fx=2.0, fy=2.0, interpolation=cv2.INTER_CUBIC))
    for cand in candidates:
        ok, decoded, _points, _straight = detector.detectAndDecodeMulti(cand)
        if ok:
            for payload in decoded:
                if payload and "simplex" in payload:
                    print(payload)
                    return 0
        ok, payload, _points = detector.detectAndDecode(cand)
        if ok and payload and "simplex" in payload:
            print(payload)
            return 0
    print("no simplex QR code found in screenshot", file=sys.stderr)
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
