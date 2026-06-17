#!/bin/bash

TEMP_PREFIX="/tmp/download."

highlight=false
temp=false
notify=false
temp_filename=""
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

# Argument parsing:
#   download "url"                      -> save to pwd
#   download "url" filepath             -> save to filepath
#   download "url" --temp               -> save to /tmp (auto name)
#   download "url" --temp filename      -> save to /tmp/filename
#   download --temp                     -> url from clipboard, save to /tmp
#   download --temp --notify            -> url from clipboard, save to /tmp, notify
#   download --clean-temp               -> remove all /tmp/download.* dirs
for arg in "$@"; do
    if $expect_temp_filename; then
        expect_temp_filename=false
        if [[ "$arg" != --* ]] && ! [[ "$arg" =~ ^https?:// ]]; then
            temp_filename="$arg"
            continue
        fi
        # Not a filename — fall through to re-process this arg
    fi

    if [[ "$arg" == "--clean-temp" ]]; then
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

for ((i=0; i<${#urls[@]}; i++)); do
    url="${urls[$i]}"
    filepath="${filepaths[$i]:-}"

    # Determine output directory
    if $temp; then
        out_dir=$(mktemp -d "${TEMP_PREFIX}XXXXXX")
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

        if ! yt-dlp "$url" "${other_args[@]}" \
            --merge-output-format mp4 \
            --sponsorblock-mark poi_highlight \
            --no-write-info-json \
            --clean-info-json \
            "${ytdlp_out[@]}"; then
            failed=true
            continue
        fi

        # Trim to highlight point if found
        if [[ -n "$start" ]]; then
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
