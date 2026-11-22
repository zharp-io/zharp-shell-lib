#!/usr/bin/env bash
source "$(dirname "$0")/../../zharp.sh"
echo "line one"
echo "line two"
echo "a warning" >&2
zharp_log "copied 3 files"
sh -c 'echo "child:$TRACEPARENT"'
