#!/bin/sh
# The core cases in whatever shell, awk and date an image has (bash 3.2 as macOS ships it, Debian's
# dash and mawk, busybox): run by tests/run-shell.sh. Checks with grep, as there is no jq there.
cd "$(dirname "$0")/.." || exit 1
fail=0
CAP=$(mktemp -d); export _ZHARP_CAPTURE_DIR="$CAP" ZHARP_KEY=zpk_test
check() { # description, pattern [grep option]
    if cat "$CAP"/*.json 2>/dev/null | grep -q ${3:-} -- "$2"; then echo "ok - $1"; else echo "not ok - $1"; fail=1; fi
    rm -f "$CAP"/*
}
expect_code() { if [ "$1" -eq "$2" ]; then :; else echo "not ok - exit code $1, wanted $2"; fail=1; fi; }

if command -v bash >/dev/null 2>&1; then
    bash tests/shell/deep.sh >/dev/null 2>&1; expect_code $? 1
    check "bash $(bash -c 'echo $BASH_VERSION'): failing command and stack" '"cat exited with 1: cat /nonexistent-zharp-file".*at backup, [^"]*deep.sh: line 12'
    bash tests/shell/pipeline.sh >/dev/null 2>&1; expect_code $? 1
    check "bash: pipeline" 'grep exited with 1: grep needle /dev/null | sort'
fi
sh tests/shell/hook.sh >/dev/null 2>&1; expect_code $? 1
check "sh ($(readlink -f /bin/sh 2>/dev/null)): the hook's exit code" 'hook.sh exited with 1'
out=$(sh zharp.sh run -- sh -c 'echo "out \"quoted\" \ back"; echo err >&2; exit 4' 2>&1); expect_code $? 4
case "$out" in *'out "quoted" \ back'*) ;; *) echo "not ok - output passed through: $out"; fail=1 ;; esac
check "sh: zharp run, exit code and output tail" '"sh exited with 4".*"zharp.output","value":{"stringValue":"err"}'
ZHARP_LOGS=true sh zharp.sh run -- sh -c 'echo "a \"b\" \ c"' >/dev/null 2>&1
check "sh: zharp run logs, escaped" '"stringValue":"a \"b\" \\ c"' -F
rm -rf "$CAP"
exit $fail
