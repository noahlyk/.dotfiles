#!/usr/bin/env bash

languages=(
    "python"   
    "cpp"
)
languages=$(printf "%s\n" "${languages[@]}")
selected=$(echo "$languages" | fzf)
if [[ -z $selected ]]; then
    exit 0
fi

read -p "Enter Query: " query

if echo "$languages" | grep -q "^$selected$"; then
    query=$(echo "$query" | tr ' ' '+')
    tmux neww bash -c "echo \"curl cht.sh/$selected/$query/\" & curl cht.sh/$selected/$query & while [ : ]; do sleep 1; done"
else
    tmux neww bash -c "curl -s cht.sh/$selected~$query | less"
fi
