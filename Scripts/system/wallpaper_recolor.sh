#!/usr/bin/env bash
#
# wallpaper_recolor.sh — re-theme a wallpaper to a red/blue palette.
#
# Technique: a luminance GRADIENT MAP, not a hue rotation. Each pixel keeps its
# brightness; that brightness is then painted through a designed red<->blue ramp
# (deep blue in the shadows -> purple bridge -> red -> warm highlight).
#
# This works where hue-rotation failed: a painted sunset's warm/cool light logic
# fights a forced red-vs-blue hue remap (the purple/magenta it wants to delete is
# the natural bridge between its blue and pink, so removing it reads muddy). By
# driving colour from luminance instead, the dark sky lands blue and the sunlit
# clouds land red *because that is where the light already was* — cohesive, and
# all the cloud detail survives since detail comes from luminance.
#
# Modes:
#   gmap  (default)  full gradient map. Ramps: split (bold red/blue, default),
#                    cohesive (gentler), crimson (moodier navy).
#   tone             split-tone: keeps the original image, only cools the
#                    shadows and warms the highlights. Subtle.
#
# Red/blue anchors are pulled from the MajorPicks page's inline SVG duotone
# filters + theme-color (http://amongos.local/league-of-legends) and used to
# nudge the ramp's blue/red ends; if unreachable the ramp is used as designed.
#
# Output is always a NEW file (never overwrites the input, never changes the
# live wallpaper unless you pass --set).
#
# Usage:
#   wallpaper_recolor.sh [INPUT] [-o OUT] [--mode gmap|tone] [--ramp NAME]
#                        [--mix F] [--sat F] [--no-fetch] [--set]
#
# Tunables (env or flags):
#   MODE   gmap | tone                                   (default gmap)
#   RAMP   split | cohesive | crimson                    (default split)
#   MIX    0..1 blend with the original image            (default 1.0 = full)
#   SAT    saturation multiplier applied after mapping   (default 1.0)
#   LO/HI  percentiles used to normalise luminance       (default 2 / 98)

set -euo pipefail

INPUT="${INPUT:-$HOME/Pictures/Wallpaper/m56JqrU_edited.png}"
SUFFIX="${SUFFIX:-_redblue}"
OUTPUT=""
URL="${URL:-http://amongos.local/league-of-legends}"
DO_FETCH=1
DO_SET=0

MODE="${MODE:-gmap}"
RAMP="${RAMP:-split}"
MIX="${MIX:-1.0}"
SAT="${SAT:-1.0}"
LO="${LO:-2}"
HI="${HI:-98}"
BLUE_HUE="${BLUE_HUE:-}"
RED_HUE="${RED_HUE:-}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    -o|--output) OUTPUT="$2"; shift 2 ;;
    --suffix)    SUFFIX="$2"; shift 2 ;;
    --mode)      MODE="$2"; shift 2 ;;
    --ramp)      RAMP="$2"; shift 2 ;;
    --mix)       MIX="$2"; shift 2 ;;
    --sat)       SAT="$2"; shift 2 ;;
    --url)       URL="$2"; shift 2 ;;
    --no-fetch)  DO_FETCH=0; shift ;;
    --set)       DO_SET=1; shift ;;
    -h|--help)   sed -n '2,40p' "$0"; exit 0 ;;
    -*)          echo "unknown option: $1" >&2; exit 2 ;;
    *)           INPUT="$1"; shift ;;
  esac
done

[[ -f "$INPUT" ]] || { echo "input not found: $INPUT" >&2; exit 1; }
if [[ -z "$OUTPUT" ]]; then
  dir="$(dirname "$INPUT")"; base="$(basename "$INPUT")"; stem="${base%.*}"
  OUTPUT="$dir/${stem}${SUFFIX}.png"
fi

# ---- pull red/blue anchors from the palette page (best-effort) -------------
# The page is a client-rendered SPA, but its static HTML embeds the red & blue
# duotone ramps as inline SVG filters plus <meta name="theme-color">.
if [[ $DO_FETCH -eq 1 ]]; then
  html="$(curl -s -m 6 "$URL" 2>/dev/null || true)"
  if [[ -n "$html" ]]; then
    read -r f_blue f_red < <(
      HTML="$html" python3 - <<'PY'
import os, re, colorsys
html = os.environ["HTML"]
def hue(r, g, b): return colorsys.rgb_to_hsv(r, g, b)[0] * 360.0
def ramp(fid):
    m = re.search(r'id="'+re.escape(fid)+r'".*?</filter>', html, re.S)
    if not m: return None
    b, vals = m.group(0), {}
    for ch in "RGB":
        mm = re.search(r'feFunc'+ch+r'[^>]*tableValues="([\d.\s]+)"', b)
        if not mm: return None
        vals[ch] = [float(x) for x in mm.group(1).split()]
    return (vals["R"][0], vals["G"][0], vals["B"][0])
blue_h = red_h = None
lo = ramp("mp-duotone-blue")
if lo: blue_h = hue(*lo)
lo = ramp("mp-duotone-red")
if lo: red_h = hue(*lo)
m = re.search(r'name="theme-color"\s+content="#([0-9A-Fa-f]{6})"', html)
if m:  # theme-color is the canonical brand blue
    hx = m.group(1)
    blue_h = hue(*[int(hx[i:i+2], 16)/255 for i in (0, 2, 4)])
print(f"{blue_h if blue_h is not None else ''} {red_h if red_h is not None else ''}")
PY
    ) || true
    [[ -z "$BLUE_HUE" && -n "${f_blue:-}" ]] && BLUE_HUE="$f_blue"
    [[ -z "$RED_HUE"  && -n "${f_red:-}"  ]] && RED_HUE="$f_red"
    if [[ -n "${f_blue:-}${f_red:-}" ]]; then
      echo "palette: fetched blue=${f_blue:-?} red=${f_red:-?}"
    else
      echo "palette: page reachable but no duotone data; using ramp as designed"
    fi
  else
    echo "palette: $URL unreachable, using ramp as designed" >&2
  fi
fi

echo "recolor: $INPUT"
echo "     ->  $OUTPUT"
echo "  mode=$MODE ramp=$RAMP mix=$MIX sat=$SAT"

INPUT="$INPUT" OUTPUT="$OUTPUT" MODE="$MODE" RAMP="$RAMP" MIX="$MIX" SAT="$SAT" \
LO="$LO" HI="$HI" BLUE_HUE="${BLUE_HUE:-}" RED_HUE="${RED_HUE:-}" \
python3 - <<'PY'
import os, colorsys
import numpy as np
from PIL import Image

INPUT  = os.environ["INPUT"];  OUTPUT = os.environ["OUTPUT"]
MODE   = os.environ["MODE"];   RAMPN  = os.environ["RAMP"]
MIX    = float(os.environ["MIX"]); SAT = float(os.environ["SAT"])
LO     = float(os.environ["LO"]);  HI  = float(os.environ["HI"])
_b = os.environ.get("BLUE_HUE", ""); _r = os.environ.get("RED_HUE", "")
BLUE_HUE = float(_b) if _b else None
RED_HUE  = float(_r) if _r else None

img = Image.open(INPUT)
has_alpha = img.mode in ("RGBA", "LA") or "transparency" in img.info
alpha = img.convert("RGBA").getchannel("A") if has_alpha else None
a = np.asarray(img.convert("RGB"), dtype=np.float64) / 255.0

# Luminance drives everything; normalise it so the ramp spans the real range.
Y = 0.2126*a[..., 0] + 0.7152*a[..., 1] + 0.0722*a[..., 2]
lo, hi = np.percentile(Y, LO), np.percentile(Y, HI)
Yn = np.clip((Y - lo) / max(hi - lo, 1e-6), 0.0, 1.0)

# Ramps are (position, hex). Lightness rises monotonically so detail survives.
RAMPS = {
    "split":    [(0.00,"060810"),(0.26,"172a4d"),(0.46,"2c2836"),(0.62,"7a2333"),
                 (0.80,"c4383a"),(0.94,"ef8a55"),(1.00,"ffe3c2")],
    "cohesive": [(0.00,"05070f"),(0.22,"14233f"),(0.42,"3a2b52"),(0.60,"8a2f45"),
                 (0.78,"cf4436"),(0.90,"ec7a4e"),(1.00,"ffe0bc")],
    "crimson":  [(0.00,"04060d"),(0.30,"111f3a"),(0.50,"241a2c"),(0.66,"5e1f2e"),
                 (0.82,"a83043"),(0.95,"e06a52"),(1.00,"ffd9ad")],
}
stops = RAMPS.get(RAMPN, RAMPS["split"])
pos  = np.array([s[0] for s in stops])
cols = np.array([[int(s[1][i:i+2], 16)/255 for i in (0, 2, 4)] for s in stops])

# The ramp was designed around blue 217 / red 2. If the site gave us different
# anchors, rotate each stop's hue by an amount interpolated across the ramp so
# the blue end tracks their blue and the red end tracks their red.
if BLUE_HUE is not None or RED_HUE is not None:
    db = (BLUE_HUE - 217.0) if BLUE_HUE is not None else 0.0
    dr = (RED_HUE  -   2.0) if RED_HUE  is not None else 0.0
    db = ((db + 180) % 360) - 180
    dr = ((dr + 180) % 360) - 180
    for i, p in enumerate(pos):
        shift = db + (dr - db) * float(p)
        h, s_, v_ = colorsys.rgb_to_hsv(*cols[i])
        cols[i] = colorsys.hsv_to_rgb(((h*360.0 + shift) % 360.0)/360.0, s_, v_)

if MODE == "tone":
    # Split-tone: keep the original, cool the shadows and warm the highlights,
    # renormalised so each pixel's luminance is preserved.
    shadow = np.array([0.10, 0.16, 0.34]); high = np.array([0.90, 0.30, 0.24])
    t = Yn[..., None]
    tint = shadow*(1-t) + high*t
    tl = np.clip(0.2126*tint[...,0:1] + 0.7152*tint[...,1:2] + 0.0722*tint[...,2:3], 1e-3, 1)
    res = a*(1-0.42) + (tint * (Y[..., None]/tl))*0.42
else:
    res = np.stack([np.interp(Yn, pos, cols[:, c]) for c in range(3)], -1)

# MIX eases back toward the untouched original.
if MIX < 1.0:
    res = a*(1.0 - MIX) + res*MIX

if SAT != 1.0:
    g = (0.2126*res[...,0] + 0.7152*res[...,1] + 0.0722*res[...,2])[..., None]
    res = g + (res - g)*SAT

res = np.clip(res, 0.0, 1.0)
out = Image.fromarray((res*255.0 + 0.5).astype(np.uint8), "RGB")
if alpha is not None:
    out = out.convert("RGBA"); out.putalpha(alpha)
out.save(OUTPUT)
print(f"wrote {OUTPUT} ({out.width}x{out.height})")
PY

if [[ $DO_SET -eq 1 ]]; then
  if command -v swww >/dev/null 2>&1; then
    swww img "$OUTPUT" && echo "set as wallpaper via swww"
  else
    echo "swww not found; skip --set" >&2
  fi
fi
