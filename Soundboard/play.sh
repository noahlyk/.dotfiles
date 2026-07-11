#!/bin/bash

SCRIPT_PATH="$(realpath "${BASH_SOURCE[0]}")"
SCRIPT_DIR="$(dirname "$SCRIPT_PATH")"
PID_FILE="$SCRIPT_DIR/.soundboard.pids"
VOL_FILE="$SCRIPT_DIR/.soundboard.volume"

if [ "$(id -u)" -eq 0 ] && [ "$SUDO_USER" != "$TARGET_USER" ]; then
    TARGET_USER=$(awk -F: '$3 >= 1000 && $3 < 65534 {print $1}' /etc/passwd | head -n1)
    exec runuser -u "$TARGET_USER" -- "$SCRIPT_PATH" "$@"
fi

if [ "$1" = "VOL" ]; then
    if [ -z "$2" ]; then
        if [ -f "$VOL_FILE" ]; then
            CURRENT_VOL=$(cat "$VOL_FILE")
            echo "Current volume: $CURRENT_VOL"
        else
            echo "Current volume: 1.0 (default)"
        fi
        exit 0
    fi

    VOL_VALUE="$2"
    
    if ! [[ "$VOL_VALUE" =~ ^[0-9]*\.?[0-9]+$ ]]; then
        echo "Error: Volume must be a number between 0.0 and 1.0"
        echo "Usage: $0 VOL <0.0-1.0>"
        exit 1
    fi
    
    if ! awk -v vol="$VOL_VALUE" 'BEGIN { exit (vol >= 0 && vol <= 1) ? 0 : 1 }'; then
        echo "Error: Volume must be between 0.0 and 1.0"
        echo "Usage: $0 VOL <0.0-1.0>"
        exit 1
    fi

    echo "$VOL_VALUE" > "$VOL_FILE"
    echo "Volume set to $VOL_VALUE"
    exit 0
fi

if [ "$1" = "STOP" ]; then
    echo "Stopping all pw-play processes..."

    if [ ! -f "$PID_FILE" ]; then
        echo "No PID file found. Attempting to kill all pw-play processes..."
        pkill -TERM pw-play
        exit 0
    fi

    while read -r pid; do
        if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
            echo "Killing PID $pid"
            kill -TERM "$pid" 2>/dev/null
        fi
    done < "$PID_FILE"

    rm -f "$PID_FILE"
    echo "Done."
    exit 0
fi

if [ $# -eq 0 ]; then
    echo "Usage: $0 <pattern | STOP | VOL [value]>"
    echo "Example: $0 KC_A"
    echo "         $0 STOP        # kills all pw-play processes launched by this script"
    echo "         $0 VOL         # show current volume"
    echo "         $0 VOL 0.5     # set volume to 50%"
    exit 1
fi

PATTERN="$1"

MATCHING_FILES=("$SCRIPT_DIR/$PATTERN"*)

echo "${MATCHING_FILES[@]}"
if [ ${#MATCHING_FILES[@]} -eq 0 ] || [ ! -f "${MATCHING_FILES[0]}" ]; then
    echo "No file found matching pattern: $PATTERN"
    exit 1
fi

MATCHING_FILE=${MATCHING_FILES[$RANDOM % ${#MATCHING_FILES[@]}]}

cleanup() {
    if [ -n "$PID1" ] && kill -0 "$PID1" 2>/dev/null; then
        kill -TERM "$PID1" 2>/dev/null
    fi
    if [ -f "$PID_FILE" ]; then
        grep -v -e "^$PID1$" "$PID_FILE" > "$PID_FILE.tmp" 2>/dev/null
        if [ -s "$PID_FILE.tmp" ]; then
            mv "$PID_FILE.tmp" "$PID_FILE"
        else
            rm -f "$PID_FILE" "$PID_FILE.tmp"
        fi
    fi
}

trap cleanup EXIT INT TERM

VOLUME="1.0"
if [ -f "$VOL_FILE" ]; then
    VOLUME=$(cat "$VOL_FILE")
fi

echo "Playing: $MATCHING_FILE at volume $VOLUME"

VOLUME_INT=$(awk "BEGIN {printf \"%.0f\", $VOLUME * 65536}")
paplay -d "input.loopmix" --volume="${VOLUME_INT:-65536}" "$MATCHING_FILE" &
PID1=$!
echo "$PID1" >> "$PID_FILE"
wait $PID1

if [ -f "$PID_FILE" ]; then
    grep -v -e "^$PID1$" "$PID_FILE" > "$PID_FILE.tmp" 2>/dev/null
    if [ -s "$PID_FILE.tmp" ]; then
        mv "$PID_FILE.tmp" "$PID_FILE"
    else
        rm -f "$PID_FILE" "$PID_FILE.tmp"
    fi
fi
