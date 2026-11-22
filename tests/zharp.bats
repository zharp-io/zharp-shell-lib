#!/usr/bin/env bats
# zharp.sh: the hook (bash, zsh, plain sh) and `zharp run`. Payloads are written to a folder
# (_ZHARP_CAPTURE_DIR) instead of being sent, and read back with jq.
#   tests/run-shell.sh      runs this in Docker (bats, jq, zsh, python3, node)

setup() {
    ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
    ZHARP="$ROOT/zharp.sh"
    FIX="$ROOT/tests/shell"
    CAP="$(mktemp -d)"
    export _ZHARP_CAPTURE_DIR="$CAP" ZHARP_KEY=zpk_test
    unset ZHARP_LOGS ZHARP_MONITOR ZHARP_ERREXIT TRACEPARENT ZHARP_SERVICE ZHARP_ENDPOINT ZHARP_PING_URL
}

teardown() { rm -rf "$CAP"; }

# Every log record sent, as one JSON array.
logs() { cat "$CAP"/*_v1_logs.json 2>/dev/null | jq -s '[.[].resourceLogs[0].scopeLogs[0].logRecords[]]'; }
spans() { cat "$CAP"/*_v1_traces.json 2>/dev/null | jq -s '[.[].resourceSpans[0].scopeSpans[0].spans[]]'; }
errors() { logs | jq '[.[] | select(any(.attributes[]; .key == "exception.type"))]'; }
# attr <json object> <key>
attr() { jq -r --arg k "$2" '.attributes[] | select(.key == $k) | .value | (.stringValue // .intValue)' <<< "$1"; }
resource() { cat "$CAP"/*.json | jq -rs --arg k "$1" '[.[] | (.resourceLogs // .resourceSpans)[0].resource.attributes[] | select(.key == $k) | .value.stringValue][0]'; }
pings() { cat "$CAP"/*-ping.txt 2>/dev/null; }

@test "bash: a failure three functions deep is reported once, with the stack and the code that ran" {
    run "$FIX/deep.sh"
    [ "$status" -eq 1 ]
    [[ "$output" != *never* ]]
    [ "$(errors | jq length)" -eq 1 ]
    e="$(errors | jq '.[0]')"
    [ "$(attr "$e" exception.type)" = CommandFailed ]
    [ "$(attr "$e" exception.message)" = "cat exited with 1: cat /nonexistent-zharp-file" ]
    stack="$(attr "$e" exception.stacktrace)"
    [ "$(sed -n 1p <<< "$stack")" = "at copy_files, $FIX/deep.sh: line 7" ]
    [ "$(sed -n 2p <<< "$stack")" = "at backup, $FIX/deep.sh: line 12" ]
    [ "$(sed -n 3p <<< "$stack")" = "at main, $FIX/deep.sh: line 16" ]
    [[ "$stack" != *zharp.sh* ]]
    ctx="$(attr "$e" zharp.source_context)"
    [ "$(jq -r '.[0].code' <<< "$ctx")" = "    cat /nonexistent-zharp-file" ]
    [ "$(jq -r '.[0].pre | length' <<< "$ctx")" -eq 5 ]
    [ "$(jq -r '.[0].pre[1]' <<< "$ctx")" = 'source "$(dirname "$0")/../../zharp.sh"' ]
    [[ "$(attr "$e" zharp.output)" == *"No such file or directory"* ]]
    [ "$(attr "$e" zharp.handled)" = false ]
    [ "$(attr "$e" process.exit.code)" = 1 ]
}

@test "bash: the run is a span, failed, and the error is on its trace" {
    run "$FIX/deep.sh"
    s="$(spans | jq '.[0]')"
    [ "$(jq -r .name <<< "$s")" = deep.sh ]
    [ "$(jq -r .status.code <<< "$s")" -eq 2 ]
    [ "$(errors | jq -r '.[0].traceId')" = "$(jq -r .traceId <<< "$s")" ]
    [ "$(resource service.name)" = deep ]
    [ "$(resource telemetry.sdk.language)" = shell ]
    [ "$(resource process.runtime.name)" = bash ]
}

@test "bash: a failing command in a pipeline fails the script (pipefail)" {
    run "$FIX/pipeline.sh"
    [ "$status" -eq 1 ]
    [[ "$output" != *never* ]]
    e="$(errors | jq '.[0]')"
    [ "$(attr "$e" exception.message)" = "grep exited with 1: grep needle /dev/null | sort" ]
    [ "$(attr "$e" exception.stacktrace)" = "at main, $FIX/pipeline.sh: line 5" ]
}

@test "bash: exit 3 is reported with its code and the end of stderr" {
    run "$FIX/exit3.sh"
    [ "$status" -eq 3 ]
    e="$(errors | jq '.[0]')"
    [ "$(attr "$e" exception.message)" = "exit3.sh exited with 3" ]
    [ "$(attr "$e" zharp.output)" = "giving up" ]
}

@test "bash: a script that succeeds sends its span and nothing else by default; output is unchanged" {
    run "$FIX/ok.sh"
    [ "$status" -eq 0 ]
    [[ "$output" == *"line one"*"line two"* ]]
    [ "$(errors | jq length)" -eq 0 ]
    [ "$(spans | jq -r '.[0].status.code')" -eq 0 ]
    # zharp_log's line is printed stamped, and sent (it is the one log by default).
    trace="$(spans | jq -r '.[0].traceId')"; span="$(spans | jq -r '.[0].spanId')"
    [[ "$output" == *"copied 3 files trace_id=$trace span_id=$span"* ]]
    [ "$(logs | jq length)" -eq 1 ]
    [ "$(logs | jq -r '.[0].body.stringValue')" = "copied 3 files" ]
}

@test "bash: TRACEPARENT is passed to programs the script starts" {
    run "$FIX/ok.sh"
    trace="$(spans | jq -r '.[0].traceId')"; span="$(spans | jq -r '.[0].spanId')"
    [[ "$output" == *"child:00-$trace-$span-01"* ]]
}

@test "bash: a script started inside a trace continues it" {
    TRACEPARENT=00-0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331-01 run "$FIX/ok.sh"
    [ "$(spans | jq -r '.[0].traceId')" = 0af7651916cd43dd8448eb211c80319c ]
    [ "$(spans | jq -r '.[0].parentSpanId')" = b7ad6b7169203331 ]
    [ "$(spans | jq -r '.[0].kind')" -eq 2 ]
}

@test "bash: ZHARP_LOGS=true sends stdout and stderr line by line, on the trace" {
    ZHARP_LOGS=true run "$FIX/ok.sh"
    [ "$status" -eq 0 ]
    [[ "$output" == *"line one"* ]]
    bodies="$(logs | jq -r '.[].body.stringValue')"
    [[ "$bodies" == *"line one"* ]]
    [[ "$bodies" == *"a warning"* ]]
    [ "$(logs | jq -r '[.[] | select(.body.stringValue == "a warning")][0].attributes[0].value.stringValue')" = stderr ]
    [ "$(logs | jq -r '[.[] | select(.body.stringValue == "line two")][0].traceId')" = "$(spans | jq -r '.[0].traceId')" ]
    # zharp_log's line goes with the output, not twice.
    [ "$(logs | jq '[.[] | select(.body.stringValue | startswith("copied 3 files"))] | length')" -eq 1 ]
}

@test "bash: ZHARP_ERREXIT=false keeps the script's own error behaviour" {
    ZHARP_ERREXIT=false run "$FIX/keep.sh"
    [ "$status" -eq 0 ]
    [[ "$output" == *"went on"* ]]
    [ "$(errors | jq length)" -eq 0 ]
}

@test "bash: without a key the script runs as written and nothing is sent" {
    ZHARP_KEY= _ZHARP_CAPTURE_DIR= run "$FIX/deep.sh"
    [ "$status" -eq 1 ]
    [[ "$output" == *"no key"* ]]
    [ -z "$(ls "$CAP")" ]
}

@test "bash: the Cron job monitor is pinged at start and with the exit code" {
    ZHARP_MONITOR=tok123 run "$FIX/deep.sh"
    trace="$(spans | jq -r '.[0].traceId')"
    [[ "$(pings)" == *"https://api.zharp.io/api/v1/ping/tok123/start"* ]]
    [[ "$(pings)" == *"https://api.zharp.io/api/v1/ping/tok123/1?trace_id=$trace"* ]]
    [[ "$(pings)" == *"cat exited with 1"* ]]
}

@test "zsh: the failing line, its stack and the code that ran" {
    run zsh "$FIX/deep.zsh"
    [ "$status" -eq 1 ]
    [[ "$output" != *never* ]]
    [ "$(errors | jq length)" -eq 1 ]
    e="$(errors | jq '.[0]')"
    [ "$(attr "$e" exception.message)" = "cat exited with 1: cat /nonexistent-zharp-file" ]
    stack="$(attr "$e" exception.stacktrace)"
    [ "$(sed -n 1p <<< "$stack")" = "at copy_files, $FIX/deep.zsh: line 6" ]
    [ "$(sed -n 2p <<< "$stack")" = "at backup, $FIX/deep.zsh: line 11" ]
    [ "$(resource process.runtime.name)" = zsh ]
}

@test "sh: the hook reports the exit code (no ERR trap there)" {
    run sh "$FIX/hook.sh"
    [ "$status" -eq 1 ]
    [[ "$output" != *never* ]]
    e="$(errors | jq '.[0]')"
    [ "$(attr "$e" exception.message)" = "hook.sh exited with 1" ]
    [ "$(resource process.runtime.name)" = sh ]
}

@test "run: a Python script that exits 2 is one span, its output tail on the error, the code passed through" {
    run sh "$ZHARP" run --service importer -- python3 "$FIX/fails.py"
    [ "$status" -eq 2 ]
    [[ "$output" == *"processing rows"* ]]
    [[ "$output" == *"row 7 is broken"* ]]
    e="$(errors | jq '.[0]')"
    [ "$(attr "$e" exception.type)" = CommandFailed ]
    [ "$(attr "$e" exception.message)" = "python3 exited with 2" ]
    [ "$(attr "$e" zharp.output)" = "Traceback: row 7 is broken" ]
    [ "$(spans | jq -r '.[0].name')" = python3 ]
    [ "$(spans | jq -r '.[0].status.code')" -eq 2 ]
    [ "$(resource service.name)" = importer ]
}

@test "run: success passes output and exit code through, and a child program gets the trace" {
    run sh "$ZHARP" run -- node "$FIX/trace.js"
    [ "$status" -eq 0 ]
    trace="$(spans | jq -r '.[0].traceId')"; span="$(spans | jq -r '.[0].spanId')"
    [ "$output" = "node traceparent=00-$trace-$span-01" ]
    [ "$(errors | jq length)" -eq 0 ]
}

@test "run: ZHARP_LOGS=true sends the command's output" {
    ZHARP_LOGS=true run sh "$ZHARP" run -- python3 "$FIX/fails.py"
    [ "$(logs | jq '[.[] | select(.body.stringValue == "processing rows")] | length')" -eq 1 ]
}

@test "run: --monitor pings start and the exit code with the output" {
    run sh "$ZHARP" run --monitor tok9 -- python3 "$FIX/fails.py"
    [[ "$(pings)" == *"/ping/tok9/start"* ]]
    [[ "$(pings)" == *"/ping/tok9/2?trace_id="* ]]
    [[ "$(pings)" == *"row 7 is broken"* ]]
}

@test "run: a script that sources the hook reports its own error, once, in the same trace" {
    run sh "$ZHARP" run -- "$FIX/child.sh"
    [ "$status" -eq 1 ]
    [ "$(errors | jq length)" -eq 1 ]
    [[ "$(attr "$(errors | jq '.[0]')" exception.message)" == "cp exited with 1: cp "* ]]
    [ "$(spans | jq -r '[.[].traceId] | unique | length')" -eq 1 ]
    [ "$(spans | jq length)" -eq 2 ]
}

@test "run: without a key the command runs as it would" {
    ZHARP_KEY= _ZHARP_CAPTURE_DIR= run sh "$ZHARP" run -- python3 "$FIX/fails.py"
    [ "$status" -eq 2 ]
    [[ "$output" == *"processing rows"* ]]
}

@test "zharp version" {
    run sh "$ZHARP" version
    [ "$output" = "zharp.sh 0.1.0" ]
}
