#!/bin/bash

TEMP_PREFIX="/tmp/download."
TEMP_MARKER=".download-session"

highlight=false
temp=false
notify=false
temp_filename=""
format_mode="video"
urls=()
filepaths=()
other_args=()
expect_filepath=false
expect_temp_filename=false

clip_cmd=""
paste_cmd=""
if command -v wl-copy &>/dev/null; then
    clip_cmd="wl-copy"
    paste_cmd="wl-paste --no-newline"
elif command -v xclip &>/dev/null; then
    clip_cmd="xclip -selection clipboard"
    paste_cmd="xclip -selection clipboard -o"
fi

show_help() {
    cat <<'EOF'
Usage: download.sh [options] [url] [filepath]

Download a URL (YouTube via yt-dlp, otherwise via gallery-dl) and copy the
result to the clipboard. If no URL is given, reads one from the clipboard.

Positional:
  url                    URL to download (or taken from clipboard)
  filepath               Save to this path (file or directory)

Options:
  --temp [filename]      Save to the shared temp dir instead of pwd/filepath.
                          Reuses one persistent /tmp/download.XXXXXX dir
                          (marked with a hidden .download-session file)
                          across invocations instead of making a new one
                          each time. Optional filename to use for the file.
  --clean-temp           Remove all /tmp/download.* temp dirs and exit.
  --highlight            Trim YouTube video to its SponsorBlock highlight.
  --notify                Send a desktop notification on completion/failure.

Output type (YouTube/yt-dlp only; ignored for gallery-dl URLs):
  --video, --mp4         Best video, merged to mp4 (default behavior).
  --audio                Best audio only, native container (e.g. m4a/webm).
  --mp3                  Best audio only, converted to mp3.

Any other flags are passed through to yt-dlp/gallery-dl unchanged.

Examples:
  download.sh "https://youtu.be/xyz"
  download.sh "https://youtu.be/xyz" ~/Videos/out.mp4
  download.sh --temp "https://youtu.be/xyz"
  download.sh --temp --mp3 "https://youtu.be/xyz"
  download.sh --clean-temp
EOF
}

clipboard_file() {
    local file="$1"
    if [[ ! -f "$file" ]]; then
        echo "  (file not found: $file)"
        return
    fi

    local uri ext mime
    uri=$(file_uri "$file")
    ext="${file##*.}"
    ext="${ext,,}"

    if [[ -z "$clip_cmd" ]]; then
        echo "  (no clipboard tool found) $uri"
        return
    fi

    case "$ext" in
        png|jpg|jpeg|gif|webp)
            mime="image/${ext/jpg/jpeg}"
            if [[ "$clip_cmd" == "wl-copy" ]]; then
                wl-copy --type "$mime" < "$file"
            else
                xclip -selection clipboard -t "$mime" -i "$file"
            fi
            echo "  -> (image) $uri"
            ;;
        *)
            if [[ "$clip_cmd" == "wl-copy" ]]; then
                echo -n "$uri" | wl-copy --type text/uri-list
            else
                echo -n "$uri" | xclip -selection clipboard -t text/uri-list
                printf "copy\n%s" "$uri" | xclip -selection clipboard -t x-special/gnome-copied-files
            fi
            echo "  -> $uri"
            ;;
    esac

    # Force a cliphist entry so it appears in clipboard history
    if command -v cliphist &>/dev/null; then
        echo -n "$file" | cliphist store
    fi
}

clipboard_dir() {
    while IFS= read -r -d '' f; do
        clipboard_file "$f"
    done < <(find "$1" -type f -print0)
}

file_uri() {
    local path
    path="$(realpath "$1" 2>/dev/null || echo "$1")"
    python3 -c "import sys, urllib.parse; print('file://' + urllib.parse.quote(sys.argv[1], safe=':/'))" "$path"
}

is_youtube() {
    [[ "$1" =~ ^https?://(www\.)?(youtube\.com|youtu\.be)/ ]]
}

# Find the existing marked temp dir, or create a new one and mark it, so
# repeated --temp downloads share one directory instead of piling up.
get_temp_dir() {
    local d
    for d in "${TEMP_PREFIX}"*; do
        [[ -d "$d" && -f "$d/$TEMP_MARKER" ]] && { echo "$d"; return; }
    done
    d=$(mktemp -d "${TEMP_PREFIX}XXXXXX")
    touch "$d/$TEMP_MARKER"
    echo "$d"
}

# Argument parsing:
#   download "url"                      -> save to pwd
#   download "url" filepath             -> save to filepath
#   download "url" --temp               -> save to shared /tmp dir (auto name)
#   download "url" --temp filename      -> save to shared /tmp dir/filename
#   download --temp                     -> url from clipboard, save to shared /tmp dir
#   download --temp --notify            -> url from clipboard, save to shared /tmp dir, notify
#   download --clean-temp               -> remove all /tmp/download.* dirs
#   download --audio / --mp3            -> audio-only output (YouTube)
#   download --video / --mp4            -> video output (YouTube, default)
for arg in "$@"; do
    if $expect_temp_filename; then
        expect_temp_filename=false
        if [[ "$arg" != --* ]] && ! [[ "$arg" =~ ^https?:// ]]; then
            temp_filename="$arg"
            continue
        fi
        # Not a filename — fall through to re-process this arg
    fi

    if [[ "$arg" == "--help" || "$arg" == "-h" ]]; then
        show_help
        exit 0
    elif [[ "$arg" == "--clean-temp" ]]; then
        rm -rf "${TEMP_PREFIX}"*
        echo "Cleaned all download temp dirs."
        exit 0
    elif [[ "$arg" == "--highlight" ]]; then
        highlight=true
    elif [[ "$arg" == "--temp" ]]; then
        temp=true
        expect_temp_filename=true
    elif [[ "$arg" == "--notify" ]]; then
        notify=true
    elif [[ "$arg" == "--video" || "$arg" == "--mp4" ]]; then
        format_mode="video"
    elif [[ "$arg" == "--audio" ]]; then
        format_mode="audio"
    elif [[ "$arg" == "--mp3" ]]; then
        format_mode="mp3"
    elif [[ "$arg" =~ ^https?:// ]]; then
        urls+=("$arg")
        expect_filepath=true
    elif $expect_filepath && [[ "$arg" != --* ]]; then
        filepaths+=("$arg")
        expect_filepath=false
    else
        other_args+=("$arg")
    fi
done

die() {
    echo "$1"
    $notify && notify-send -u critical -a "download" "Download failed" "$1"
    exit 1
}

# If no URLs provided, try reading from clipboard
if [[ ${#urls[@]} -eq 0 ]] && [[ -n "$paste_cmd" ]]; then
    clip_content=$($paste_cmd 2>/dev/null)
    if [[ "$clip_content" =~ ^https?:// ]]; then
        urls+=("$clip_content")
    else
        die "No URL provided and clipboard doesn't contain a URL."
    fi
elif [[ ${#urls[@]} -eq 0 ]]; then
    die "No URL provided and no clipboard tool found."
fi

failed=false

# One shared temp dir for the whole invocation (and reused across invocations).
shared_temp_dir=""
if $temp; then
    shared_temp_dir=$(get_temp_dir)
fi

for ((i=0; i<${#urls[@]}; i++)); do
    url="${urls[$i]}"
    filepath="${filepaths[$i]:-}"

    # Determine output directory
    if $temp; then
        out_dir="$shared_temp_dir"
    elif [[ -n "$filepath" ]]; then
        out_dir=""  # explicit path handled separately
    else
        out_dir="$(pwd)"
    fi

    if is_youtube "$url"; then
        # Determine yt-dlp output arg
        if [[ -n "$out_dir" ]]; then
            if $temp && [[ -n "$temp_filename" ]]; then
                ytdlp_out=(-o "$out_dir/$temp_filename")
            elif $temp; then
                ytdlp_out=(-o "$out_dir/%(title)s.%(ext)s")
            else
                ytdlp_out=(-P "$out_dir")
            fi
        else
            ytdlp_out=(-o "$filepath")
        fi

        start=""
        if $highlight; then
            start=$(yt-dlp "$url" --skip-download --print "sponsorblock_poi_highlight[0].start" 2>/dev/null)
            [[ "$start" =~ ^[0-9]+(\.[0-9]+)?$ ]] || start=""
        fi

        # Build format-specific yt-dlp args
        ytdlp_format_args=()
        case "$format_mode" in
            audio)
                ytdlp_format_args=(-f bestaudio)
                ;;
            mp3)
                ytdlp_format_args=(-f bestaudio --extract-audio --audio-format mp3)
                ;;
            *)
                ytdlp_format_args=(--merge-output-format mp4)
                ;;
        esac

        notify-send -a "download" "YT Download started" "${urls[*]}"
        if ! downloaded_file=$(yt-dlp "$url" "${other_args[@]}" \
            "${ytdlp_format_args[@]}" \
            --sponsorblock-mark poi_highlight \
            --no-write-info-json \
            --clean-info-json \
            --print "after_move:filepath" \
            "${ytdlp_out[@]}"); then
            failed=true
            continue
        fi

        # Trim to highlight point if found (video mode only; nothing to trim for audio-only output)
        if [[ -n "$start" && "$format_mode" == "video" ]]; then
            if [[ -n "$out_dir" ]]; then
                for f in "$out_dir"/*; do
                    [[ -f "$f" ]] && vidfile="$f" && break
                done
            else
                vidfile="$filepath"
            fi
            if [[ -f "$vidfile" ]]; then
                tmpfile="${vidfile}.trim.tmp"
                ffmpeg -ss "$start" -i "$vidfile" -c copy "$tmpfile" && mv "$tmpfile" "$vidfile"
            fi
        fi
    else
        if ! gallery-dl "$url" -D "${out_dir:-$filepath}" --cookies-from-browser firefox "${other_args[@]}"; then
            failed=true
            continue
        fi
    fi

    # Always copy downloaded files to clipboard
    if [[ -n "$out_dir" ]]; then
        clipboard_dir "$out_dir"
    elif [[ -d "$filepath" ]]; then
        clipboard_dir "$filepath"
    elif [[ -f "$filepath" ]]; then
        clipboard_file "$filepath"
    fi
done

if $notify; then
    if $failed; then
        notify-send -u critical -a "download" "Download failed" "${urls[*]}"
    else
        notify-send -a "download" "Download complete" "${urls[*]}"
    fi
fi
