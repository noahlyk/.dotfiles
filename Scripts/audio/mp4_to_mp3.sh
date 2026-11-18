#!/bin/bash

# Check if ffmpeg is installed
if ! command -v ffmpeg &> /dev/null; then
    echo "ffmpeg could not be found, please install it first."
    exit 1
fi

# Convert all .mov files to .mp4
find . -type f -name "*.mov" -exec sh -c '
    for file; do
        # Define the output filename with .mp4 extension
        output="${file%.mov}.mp4"

        # Skip conversion if the output file already exists
        if [ -f "$output" ]; then
            echo "Skipping $file as $output already exists."
            continue
        fi

        echo "Converting $file to $output..."
        ffmpeg -i "$file" -c:v libx264 -preset medium -b:v 800k -c:a aac -b:a 128k "$output" < /dev/null
    done
' sh {} +

# Convert all .mp4 files to .mp3
find . -type f -name "*.mp4" -exec sh -c '
    for file; do
        # Define the output filename with .mp3 extension
        output="${file%.mp4}.mp3"
        
        # Skip conversion if the output file already exists
        if [ -f "$output" ]; then
            echo "Skipping $file as $output already exists."
            continue
        fi

        echo "Converting $file to $output..."
        ffmpeg -i "$file" -q:a 0 -map a "$output" < /dev/null
    done
' sh {} +

echo "Conversion completed."
