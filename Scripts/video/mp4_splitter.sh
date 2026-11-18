#!/usr/bin/env bash
set -e

input="$1"

if [[ -z "$input" || ! -f "$input" ]]; then
  echo "Usage: $0 input.mp4"
  exit 1
fi

TARGET_MB=450
TARGET_BYTES=$((TARGET_MB * 1024 * 1024))

base="${input%.*}"
ext="${input##*.}"

filesize=$(stat -c%s "$input")
duration=$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$input")

parts=$(( (filesize + TARGET_BYTES - 1) / TARGET_BYTES ))
part_duration=$(awk "BEGIN {print $duration / $parts}")

echo "File size: $filesize bytes"
echo "Duration: $duration seconds"
echo "Splitting into $parts parts (~${TARGET_MB}MB target)"

for i in $(seq 0 $((parts - 1))); do
  start=$(awk "BEGIN {print $i * $part_duration}")
  out="${base}_part$((i+1)).${ext}"

  echo "Creating $out (start=$start, duration=$part_duration)"

  ffmpeg -y \
    -ss "$start" \
    -i "$input" \
    -t "$part_duration" \
    -c copy \
    -avoid_negative_ts make_zero \
    "$out"
done
