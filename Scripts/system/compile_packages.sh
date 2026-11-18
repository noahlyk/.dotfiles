#!/bin/bash
set -o pipefail

# Configuration
input_dir="$HOME/.dotfiles"
input_file="packages.txt"
output_file="$input_dir/compiled_packages.txt"

# Check if input directory is a Git repository
if ! git -C "$input_dir" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  echo "Error: $input_dir is not a Git repository" >&2
  exit 1
fi

# Change to input directory
pushd "$input_dir" >/dev/null || { echo "Failed to change directory to $input_dir" >&2; exit 1; }

# Check if input file exists in repository history
if ! git log --name-only --pretty=format: -- "$input_file" | grep -q "^$input_file$"; then
  echo "Error: $input_file not found in repository history" >&2
  popd >/dev/null
  exit 1
fi

# Create a temporary file safely
temp_file=$(mktemp) || { echo "Failed to create temporary file" >&2; popd >/dev/null; exit 1; }
trap 'rm -f "$temp_file"; popd >/dev/null' EXIT

# Clear output file
> "$output_file" || { echo "Failed to create/clear $output_file" >&2; exit 1; }

# Get all commits that modified the input file
commits=$(git log --pretty=format:"%H" --follow -- "$input_file")
if [ -z "$commits" ]; then
  echo "No commits found for $input_file" >&2
  exit 1
fi

# Process each commit
for commit in $commits; do
  echo "Processing commit: $commit"
  # Get file content and decrypt with git-crypt smudge
  content=$(git show "$commit:$input_file" 2>/dev/null | git-crypt smudge 2>/dev/null)
  if [ $? -ne 0 ]; then
    echo "Skipping commit $commit: Failed to access or decrypt $input_file" >&2
    continue
  fi

  # Append non-empty, trimmed lines to output file
  echo "$content" | while IFS= read -r line; do
    # Trim whitespace and skip empty lines
    line=$(echo "$line" | tr -d '[:space:]')
    if [ -n "$line" ]; then
      echo "$line" >> "$output_file"
    fi
  done
done

# Deduplicate lines
if [ -s "$output_file" ]; then
  sort "$output_file" | uniq > "$temp_file" || { echo "Failed to deduplicate lines" >&2; exit 1; }
  mv "$temp_file" "$output_file" || { echo "Failed to update $output_file" >&2; exit 1; }
else
  echo "No valid content found in $input_file across commits" >&2
fi

echo "Compilation complete. Unique lines are stored in $output_file"

# Cleanup handled by trap
