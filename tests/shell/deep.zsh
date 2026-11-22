#!/usr/bin/env zsh
source "${0:A:h}/../../zharp.sh"

copy_files() {
    echo "copying" >&2
    cat /nonexistent-zharp-file
    echo "never"
}

backup() {
    copy_files
}

backup
