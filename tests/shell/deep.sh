#!/usr/bin/env bash
# A script that fails three functions deep, through the hook.
source "$(dirname "$0")/../../zharp.sh"

copy_files() {
    echo "copying" >&2
    cat /nonexistent-zharp-file
    echo "never"
}

backup() {
    copy_files
}

main() {
    backup
}

main
