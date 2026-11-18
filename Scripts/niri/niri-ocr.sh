#!/bin/bash

error() {
    notify-send "OCR Failed" "$1"
    exit 1
}

tmp=$(mktemp /tmp/ocrshot.XXXXXX.png)
trap 'rm -f "$tmp"' EXIT

niri msg action screenshot --path "$tmp" || error "niri screenshot failed"

inotifywait -q -e close_write "$(dirname "$tmp")" | head -n1 || error "inotifywait failed"

dms cl copy --clear 2>/dev/null || true

magick "$tmp" -resize 300% -type Grayscale -contrast-stretch 0% -sharpen 0x1.0 "$tmp" || error "magick failed"

tesseract "$tmp" stdout -l eng --oem 1 --psm 3 --dpi 300 | dms cl copy || error "tesseract/dms cl copy failed"
