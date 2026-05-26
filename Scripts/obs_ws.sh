#!/bin/bash
export NODE_PATH="/home/fib/.dotfiles/obsws/node_modules"
exec node "/home/fib/.dotfiles/obsws/obs_ws.js" "$@"
