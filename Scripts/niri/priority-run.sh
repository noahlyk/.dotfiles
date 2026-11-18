#!/usr/bin/env bash
exec nice -n -20 ionice -c2 -n0 "$@"
