#!/bin/bash

# Script to process MP3 files: remove leading silence and normalize volume
# Processes all files to .new versions, then if successful, backs up originals and replaces them

SCRIPT_DIR="$(dirname "$(realpath "${BASH_SOURCE[0]}")")"
cd "$SCRIPT_DIR" || exit 1

# Create backup directory if it doesn't exist
mkdir -p .bak

# Track success
failed_files=()
processed_files=()

echo "Step 1: Processing all MP3 files to .new versions..."

# Process each MP3 file
for file in *.mp3; do
    if [ -f "$file" ] && [[ "$file" != *.new.mp3 ]]; then
        echo "Processing: $file"
        
        # Extract filename without extension
        filename="${file%.mp3}"
        new_file="${filename}.new.mp3"
        
        # Get audio duration to determine processing parameters
        duration=$(ffprobe -v quiet -show_entries format=duration -of csv=p=0 "$file")
        duration_int=$(echo "$duration" | cut -d. -f1)
        
        # Special handling for problematic files
        filename=$(basename "$file" .mp3)
        if [[ "$filename" == *"KC_X"* ]]; then
            # KC_X: VERY aggressive silence removal + noise reduction
            filter_chain="silenceremove=start_periods=1:start_duration=0.02:start_threshold=-35dB:window=0.005,highpass=f=120,lowpass=f=5000,compand=attacks=0.001:decays=0.1:points=-50/-50|-25/-18|0/-14,loudnorm=I=-11:TP=-1:LRA=6"
        elif [[ "$filename" == *"KC_O"* ]]; then
            # KC_O: minimal processing, maximum dynamics preservation
            filter_chain="silenceremove=start_periods=1:start_silence=0.1:start_threshold=-65dB:window=0.02,loudnorm=I=-20:TP=-4:LRA=25:linear=true"
        elif [ "$duration_int" -gt 60 ]; then
            # Longer audio (>60s): minimal processing
            filter_chain="silenceremove=start_periods=1:start_silence=0.1:start_threshold=-50dB:window=0.02,loudnorm=I=-16:TP=-2:LRA=16"
        elif [ "$duration_int" -gt 10 ]; then
            # Medium audio (10-60s): moderate processing
            filter_chain="silenceremove=start_periods=1:start_silence=0.1:start_threshold=-55dB:window=0.02,compand=attacks=0.003:decays=0.3:points=-70/-70|-25/-15|0/-10,loudnorm=I=-14:TP=-1.5:LRA=12"
        else
            # Short audio (<10s): standard processing
            filter_chain="silenceremove=start_periods=1:start_silence=0.1:start_threshold=-55dB:window=0.02,loudnorm=I=-13:TP=-1.5:LRA=10"
        fi
        
        ffmpeg -i "$file" -af "$filter_chain,pan=mono|c0<c0+c1" "$new_file" -y
        
        if [ $? -eq 0 ]; then
            echo "✓ Successfully processed: $file"
            processed_files+=("$file")
        else
            echo "✗ Failed to process: $file"
            failed_files+=("$file")
            # Clean up any partial file
            rm -f "$new_file"
        fi
    fi
done

# Check if any files failed
if [ ${#failed_files[@]} -gt 0 ]; then
    echo ""
    echo "ERROR: Some files failed to process:"
    printf '%s\n' "${failed_files[@]}"
    echo ""
    echo "Cleaning up .new files and aborting..."
    # Remove all .new files
    rm -f *.new.mp3
    exit 1
fi

echo ""
echo "Step 2: All files processed successfully. Backing up originals..."

# Move originals to .bak
for file in "${processed_files[@]}"; do
    mv "$file" ".bak/$file"
    echo "✓ Backed up: $file"
done

echo ""
echo "Step 3: Moving processed files to replace originals..."

# Move .new files to final names
for file in "${processed_files[@]}"; do
    filename="${file%.mp3}"
    mv "${filename}.new.mp3" "$file"
    echo "✓ Replaced: $file"
done

echo ""
echo "✓ Processing complete! All files have been processed and originals backed up to .bak/"