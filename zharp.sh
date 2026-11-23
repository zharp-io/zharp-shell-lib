#!/bin/sh
# Zharp for shell scripts: errors, a trace per run, logs and Cron job monitor pings, sent to Zharp
# as OTLP JSON with curl (or wget). One file, two ways in:
#
#   source /usr/local/lib/zharp.sh        at the top of a bash or zsh script (the hook)
#   zharp run -- ./backup.sh              around any command (the wrapper; POSIX sh is enough)
#
# Settings come from the environment: ZHARP_KEY (nothing is sent without it), ZHARP_SERVICE,
# ZHARP_ENVIRONMENT, ZHARP_RELEASE, ZHARP_ENDPOINT, ZHARP_LOGS, ZHARP_MONITOR, ZHARP_ERREXIT,
# ZHARP_DISABLED, ZHARP_DEBUG. https://zharp.io/docs/sdks/shell
#
# The first part is POSIX sh, so dash and busybox can run `zharp run` and source the file; the
# bash/zsh hook comes after the point where plain sh returns.

ZHARP_SH_VERSION=0.1.0

# --- Common helpers (POSIX) -------------------------------------------------------------------

_zharp_debug() {
    case "${ZHARP_DEBUG:-}" in 1|true|TRUE|True|yes) printf '[Zharp] %s\n' "$*" >&2 ;; esac
}

_zharp_truthy() {
    case "$1" in 1|true|TRUE|True|yes|YES|on|ON) return 0 ;; *) return 1 ;; esac
}

# Unix time in nanoseconds.
_zharp_now() {
    if [ -n "${EPOCHREALTIME:-}" ]; then
        _zt=$EPOCHREALTIME
        _zs=${_zt%[.,]*}
        _zu=${_zt#*[.,]}000000
        _zu=${_zu%"${_zu#??????}"}
        printf '%s%s000\n' "$_zs" "$_zu"
        return
    fi
    _zt=$(date +%s%N 2>/dev/null)
    case "$_zt" in
        *[!0-9]*|'') printf '%s000000000\n' "$(date +%s)" ;;
        *) printf '%s\n' "$_zt" ;;
    esac
}

# N random bytes as hex.
_zharp_id() {
    od -An -N"$1" -tx1 /dev/urandom 2>/dev/null | tr -d ' \n'
}

# Escaping for JSON strings, in awk. Backslashes are doubled by hand: gawk, mawk and busybox awk
# disagree on what "\\\\" means in a gsub replacement.
_zharp_awk_esc='
function esc(s,   o, i) {
    o = ""
    while ((i = index(s, "\\")) > 0) { o = o substr(s, 1, i - 1) "\\\\"; s = substr(s, i + 1) }
    s = o s
    gsub(/"/, "\\\"", s); gsub(/\t/, "\\t", s); gsub(/\r/, "", s); gsub(/[\001-\037]/, " ", s)
    return s
}'

# A string as a JSON string literal, quotes included.
_zharp_q() {
    printf '%s' "$1" | awk "$_zharp_awk_esc"'
        BEGIN { ORS = ""; printf "\"" }
        { if (NR > 1) printf "\\n"; printf "%s", esc($0) }
        END { printf "\"" }'
}

# OTLP key/value pairs.
_zharp_kv() { printf '{"key":"%s","value":{"stringValue":%s}}' "$1" "$(_zharp_q "$2")"; }
_zharp_kv_int() { printf '{"key":"%s","value":{"intValue":"%s"}}' "$1" "$2"; }

# Basename without forking.
_zharp_base() {
    _zb=${1%/}
    printf '%s\n' "${_zb##*/}"
}

_zharp_config() {
    ZHARP_ENDPOINT=${ZHARP_ENDPOINT:-https://api.zharp.io/api/v1/otlp}
    ZHARP_ENDPOINT=${ZHARP_ENDPOINT%/}
    _zharp_enabled=1
    if _zharp_truthy "${ZHARP_DISABLED:-}"; then _zharp_enabled=0; fi
    if [ -z "${ZHARP_KEY:-}" ] && [ -z "${_ZHARP_CAPTURE_DIR:-}" ]; then
        if [ "$_zharp_enabled" = 1 ]; then
            printf '%s\n' 'Zharp: no key, so nothing is sent. Set ZHARP_KEY (Settings > Applications in Zharp).' >&2
        fi
        _zharp_enabled=0
    fi
    if ! command -v curl >/dev/null 2>&1 && ! command -v wget >/dev/null 2>&1 && [ -z "${_ZHARP_CAPTURE_DIR:-}" ]; then
        printf '%s\n' 'Zharp: neither curl nor wget is installed, so nothing is sent.' >&2
        _zharp_enabled=0
    fi
    _zharp_logs=0
    if _zharp_truthy "${ZHARP_LOGS:-}"; then _zharp_logs=1; fi
}

# The resource: who is sending.
_zharp_resource() {
    _zr="$(_zharp_kv service.name "$_zharp_service"),$(_zharp_kv telemetry.sdk.name zharp),$(_zharp_kv telemetry.sdk.language shell),$(_zharp_kv telemetry.sdk.version "$ZHARP_SH_VERSION")"
    _zr="$_zr,$(_zharp_kv process.runtime.name "$_zharp_shell_name"),$(_zharp_kv_int process.pid "$$"),$(_zharp_kv host.name "$(hostname 2>/dev/null || uname -n)"),$(_zharp_kv os.type "$(uname -s | tr 'A-Z' 'a-z')")"
    [ -n "${_zharp_shell_version:-}" ] && _zr="$_zr,$(_zharp_kv process.runtime.version "$_zharp_shell_version")"
    [ -n "${ZHARP_RELEASE:-}" ] && _zr="$_zr,$(_zharp_kv service.version "$ZHARP_RELEASE")"
    [ -n "${ZHARP_ENVIRONMENT:-}" ] && _zr="$_zr,$(_zharp_kv deployment.environment.name "$ZHARP_ENVIRONMENT")"
    printf '{"attributes":[%s]}' "$_zr"
}

_zharp_scope='{"name":"zharp-sh","version":"'$ZHARP_SH_VERSION'"}'

# POST a file of JSON to the endpoint, three seconds at most. A failure is never the script's.
_zharp_post() {
    if [ -n "${_ZHARP_CAPTURE_DIR:-}" ]; then
        _zharp_seq=$(( ${_zharp_seq:-0} + 1 ))
        cp "$2" "$_ZHARP_CAPTURE_DIR/$$-$_zharp_seq-$(printf '%s' "$1" | tr '/:?=' '____').json" 2>/dev/null
        return 0
    fi
    _zu="$ZHARP_ENDPOINT$1"
    if command -v curl >/dev/null 2>&1; then
        # The key goes in on stdin, not the command line, where ps would show it.
        printf 'header = "Authorization: Bearer %s"\n' "$ZHARP_KEY" |
            curl -sS -o /dev/null --max-time 3 -K - -H 'Content-Type: application/json' \
                -H "User-Agent: zharp-sh/$ZHARP_SH_VERSION" --data-binary "@$2" "$_zu" 2>/dev/null ||
            _zharp_debug "could not send to $1"
    else
        wget -q -O /dev/null -T 3 --header="Authorization: Bearer $ZHARP_KEY" --header='Content-Type: application/json' \
            --post-file="$2" "$_zu" 2>/dev/null || _zharp_debug "could not send to $1"
    fi
}

# The Cron job monitor's URL: a token, or a full URL.
_zharp_ping_url() {
    case "$1" in
        '') return 1 ;;
        http://*|https://*) printf '%s\n' "${1%/}" ;;
        *) printf '%s/%s\n' "${ZHARP_PING_URL:-${ZHARP_ENDPOINT%/otlp}/ping}" "$1" ;;
    esac
}

# _zharp_ping <url> <signal> [trace id] [file with output]
_zharp_ping() {
    _zp="$1/$2"
    [ -n "${3:-}" ] && _zp="$_zp?trace_id=$3"
    if [ -n "${_ZHARP_CAPTURE_DIR:-}" ]; then
        _zharp_seq=$(( ${_zharp_seq:-0} + 1 ))
        _zf="$_ZHARP_CAPTURE_DIR/$$-$_zharp_seq-ping.txt"
        printf '%s\n' "$_zp" > "$_zf"
        [ -n "${4:-}" ] && [ -s "$4" ] && cat "$4" >> "$_zf"
        return 0
    fi
    if command -v curl >/dev/null 2>&1; then
        if [ -n "${4:-}" ] && [ -s "$4" ]; then
            curl -sS -o /dev/null --max-time 3 -H "X-Host: $(hostname 2>/dev/null)" -H 'Content-Type: text/plain' --data-binary "@$4" "$_zp" 2>/dev/null
        else
            curl -sS -o /dev/null --max-time 3 -H "X-Host: $(hostname 2>/dev/null)" "$_zp" 2>/dev/null
        fi
    else
        wget -q -O /dev/null -T 3 "$_zp" 2>/dev/null
    fi
    [ $? -eq 0 ] || _zharp_debug "could not ping the monitor"
}

# One span, as JSON: id parent name kind start end status exit-code [extra attributes JSON]
_zharp_span_json() {
    _zj='{"traceId":"'$_zharp_trace'","spanId":"'$1'"'
    [ -n "$2" ] && _zj=$_zj',"parentSpanId":"'$2'"'
    _za="$(_zharp_kv_int process.exit.code "$8")"
    [ -n "${9:-}" ] && _za="$_za,$9"
    _zj=$_zj',"name":'$(_zharp_q "$3")',"kind":'$4',"startTimeUnixNano":"'$5'","endTimeUnixNano":"'$6'","attributes":['$_za'],"status":{"code":'$7'}}'
    printf '%s\n' "$_zj"
}

# Wraps a file of span JSON lines and posts it.
_zharp_send_spans() {
    [ -s "$1" ] || return 0
    {
        printf '{"resourceSpans":[{"resource":%s,"scopeSpans":[{"scope":%s,"spans":[' "$(_zharp_resource)" "$_zharp_scope"
        awk 'NR > 1 { printf "," } { printf "%s", $0 }' "$1"
        printf ']}]}]}'
    } > "$1.body"
    _zharp_post /v1/traces "$1.body"
}

# Wraps a file of log record JSON lines and posts it, 500 records a request.
_zharp_send_logs() {
    [ -s "$1" ] || return 0
    _zr=$(_zharp_resource)
    _zn=$(wc -l < "$1" | tr -d ' ')
    _zi=1
    while [ "$_zi" -le "$_zn" ]; do
        {
            printf '{"resourceLogs":[{"resource":%s,"scopeLogs":[{"scope":%s,"logRecords":[' "$_zr" "$_zharp_scope"
            awk -v a="$_zi" -v b=$((_zi + 499)) 'NR >= a && NR <= b { if (NR > a) printf ","; printf "%s", $0 }' "$1"
            printf ']}]}]}'
        } > "$1.$_zi.body"
        _zharp_post /v1/logs "$1.$_zi.body"
        _zi=$((_zi + 500))
    done
}

# A log record as JSON: severity-number severity-text body [extra attributes JSON]
_zharp_log_json() {
    _zl='{"timeUnixNano":"'$(_zharp_now)'","severityNumber":'$1',"severityText":"'$2'","body":{"stringValue":'$(_zharp_q "$3")'}'
    _zl=$_zl',"attributes":['${4:-}'],"traceId":"'$_zharp_trace'","spanId":"'$_zharp_span'"}'
    printf '%s\n' "$_zl"
}

# Reads lines, writes them on unchanged; keeps the last ones in <dir>/<name>.tail, and with logs on
# each line as a log record in <dir>/<name>.logs. Writes <dir>/<name>.done when its input ends.
_zharp_reader() {
    # Always in a subshell of its own (&, >(...)): exec, so no trap of the script runs in it.
    exec awk -v tail="$1/$2.tail" -v spool="$1/$2.logs" -v done="$1/$2.done" -v logs="$3" -v stream="$2" \
        -v trace="$_zharp_trace" -v span="$_zharp_span" "$_zharp_awk_esc"'
        {
            print; fflush()
            # The end of the output, kept on disk as it comes (bounded: rewritten every 1000 lines).
            n++; ring[n % 50] = $0; m++
            print $0 >> tail; fflush(tail)
            if (m >= 1000) { close(tail); for (i = n - 49; i <= n; i++) print ring[i % 50] > tail; close(tail); m = 50 }
            if (logs == 1 && $0 != "") {
                # POSIX awk has no clock but srand(): seconds, and a counter keeps the order.
                srand(); s = srand(); if (s == last) c++; else { c = 0; last = s }
                printf "{\"timeUnixNano\":\"%d%09d\",\"severityNumber\":9,\"severityText\":\"INFO\",\"body\":{\"stringValue\":\"%s\"},\"attributes\":[{\"key\":\"log.iostream\",\"value\":{\"stringValue\":\"%s\"}}],\"traceId\":\"%s\",\"spanId\":\"%s\"}\n", s, c * 1000, esc($0), stream, trace, span >> spool
                fflush(spool)
            }
        }
        END {
            print "1" > done
            close(done)
        }'
}

# Waits (a second at most) for the readers to finish.
_zharp_wait_readers() {
    _zw=0
    while [ "$_zw" -lt 40 ]; do
        _zall=1
        for _zn in "$@"; do [ -f "$_zharp_dir/$_zn.done" ] || _zall=0; done
        [ "$_zall" = 1 ] && return 0
        sleep 0.025 2>/dev/null || sleep 1
        _zw=$((_zw + 1))
    done
}

# The last lines a run wrote: its stderr, or its stdout when stderr was empty.
_zharp_output_tail() {
    if [ -s "$_zharp_dir/stderr.tail" ]; then tail -n 50 "$_zharp_dir/stderr.tail"
    elif [ -s "$_zharp_dir/stdout.tail" ]; then tail -n 50 "$_zharp_dir/stdout.tail"
    fi
}

_zharp_new_trace() {
    _zharp_parent=''
    _zharp_kind=1
    case "${TRACEPARENT:-}" in
        00-????????????????????????????????-????????????????-??)
            _zharp_trace=$(printf '%s' "$TRACEPARENT" | cut -d- -f2)
            _zharp_parent=$(printf '%s' "$TRACEPARENT" | cut -d- -f3)
            _zharp_kind=2 ;;
        *) _zharp_trace=$(_zharp_id 16) ;;
    esac
    _zharp_span=$(_zharp_id 8)
    _zharp_previous_traceparent=${TRACEPARENT:-}
    TRACEPARENT="00-$_zharp_trace-$_zharp_span-01"
    export TRACEPARENT
}

# An error as a log record: type message stacktrace [extra attributes JSON]
_zharp_error_json() {
    _ze="$(_zharp_kv exception.type "$1"),$(_zharp_kv exception.message "$2"),$(_zharp_kv zharp.handled false)"
    [ -n "$3" ] && _ze="$_ze,$(_zharp_kv exception.stacktrace "$3")"
    [ -n "${4:-}" ] && _ze="$_ze,$4"
    _zharp_log_json 17 ERROR "$1: $2" "$_ze"
}

# --- zharp_curl and zharp_log: for scripts using the hook --------------------------------------

# curl with the trace: a traceparent header, so a service with a Zharp SDK continues it.
zharp_curl() {
    if [ -z "${_zharp_trace:-}" ] || [ -z "${_zharp_dir:-}" ]; then curl "$@"; return $?; fi
    _zc_span=$(_zharp_id 8)
    _zc_start=$(_zharp_now)
    _zc_url=''
    for _zc_a in "$@"; do case "$_zc_a" in http://*|https://*) _zc_url=$_zc_a ;; esac; done
    curl -H "traceparent: 00-$_zharp_trace-$_zc_span-01" "$@"
    _zc_rc=$?
    _zc_status=0
    [ "$_zc_rc" -ne 0 ] && _zc_status=2
    _zc_host=${_zc_url#*://}; _zc_host=${_zc_host%%/*}; _zc_host=${_zc_host%%\?*}
    _zharp_span_json "$_zc_span" "$_zharp_span" "curl $_zc_host" 3 "$_zc_start" "$(_zharp_now)" "$_zc_status" "$_zc_rc" \
        "$(_zharp_kv url.full "$(printf '%s' "$_zc_url" | sed -E 's/([?&][^=&]*(token|key|secret|password|sig|auth)[^=&]*=)[^&]*/\1[REDACTED]/g')"),$(_zharp_kv server.address "$_zc_host")" \
        >> "$_zharp_dir/spans" 2>/dev/null
    return $_zc_rc
}

# A log line: printed with the trace's ids at its end (for the agent reading the script's log),
# and sent to Zharp. zharp_log [-l error|warn|info|debug] message
zharp_log() {
    _zl_level=info
    if [ "${1:-}" = "-l" ]; then _zl_level=$2; shift 2; fi
    if [ -n "${_zharp_trace:-}" ]; then
        printf '%s trace_id=%s span_id=%s\n' "$*" "$_zharp_trace" "$_zharp_span"
    else
        printf '%s\n' "$*"
    fi
    # With logs on, the printed line is sent with the rest of the output.
    if [ -n "${_zharp_dir:-}" ] && [ "${_zharp_logs:-0}" != 1 ] && [ "${_zharp_enabled:-0}" = 1 ]; then
        case "$_zl_level" in
            error) _zl_n=17; _zl_t=ERROR ;;
            warn) _zl_n=13; _zl_t=WARN ;;
            debug) _zl_n=5; _zl_t=DEBUG ;;
            *) _zl_n=9; _zl_t=INFO ;;
        esac
        _zharp_log_json "$_zl_n" "$_zl_t" "$*" >> "$_zharp_dir/logs" 2>/dev/null
    fi
}

# --- zharp run -- <command>: the wrapper --------------------------------------------------------

_zharp_run_usage() {
    cat >&2 <<'EOF'
usage: zharp run [--service NAME] [--name NAME] [--monitor TOKEN] -- command [args...]

Runs the command as one span (duration, exit code; on failure the end of its output), passing
its output through and exiting with its exit code. --monitor pings a Zharp Cron job monitor when
it starts and when it ends.
EOF
}

_zharp_run() {
    _zharp_name=''
    _zharp_monitor=${ZHARP_MONITOR:-}
    while [ $# -gt 0 ]; do
        case "$1" in
            --service) ZHARP_SERVICE=$2; shift 2 ;;
            --service=*) ZHARP_SERVICE=${1#*=}; shift ;;
            --name) _zharp_name=$2; shift 2 ;;
            --name=*) _zharp_name=${1#*=}; shift ;;
            --monitor) _zharp_monitor=$2; shift 2 ;;
            --monitor=*) _zharp_monitor=${1#*=}; shift ;;
            --) shift; break ;;
            -h|--help) _zharp_run_usage; return 0 ;;
            -*) printf 'zharp run: unknown option %s\n' "$1" >&2; _zharp_run_usage; return 2 ;;
            *) break ;;
        esac
    done
    if [ $# -eq 0 ]; then _zharp_run_usage; return 2; fi
    _zharp_config
    [ -z "$_zharp_name" ] && _zharp_name=$(_zharp_base "$1")
    _zharp_service=${ZHARP_SERVICE:-${OTEL_SERVICE_NAME:-$(_zharp_base "$1" | sed 's/\.[A-Za-z0-9]*$//')}}
    _zharp_shell_name=sh
    _zharp_shell_version=''
    if [ "$_zharp_enabled" != 1 ]; then exec "$@"; fi

    _zharp_dir=$(mktemp -d 2>/dev/null || mktemp -d -t zharp)
    _zharp_new_trace
    _zharp_ping_target=$(_zharp_ping_url "$_zharp_monitor") || _zharp_ping_target=''
    [ -n "$_zharp_ping_target" ] && _zharp_ping "$_zharp_ping_target" start
    # A script under `zharp run` that sources the hook reports its own error; this one then doesn't.
    _ZHARP_RUN_DIR=$_zharp_dir
    export _ZHARP_RUN_DIR

    mkfifo "$_zharp_dir/o" "$_zharp_dir/e"
    _zharp_reader "$_zharp_dir" stdout "$_zharp_logs" < "$_zharp_dir/o" &
    _zharp_reader "$_zharp_dir" stderr "$_zharp_logs" < "$_zharp_dir/e" >&2 &
    _zharp_start=$(_zharp_now)
    "$@" > "$_zharp_dir/o" 2> "$_zharp_dir/e"
    _zharp_code=$?
    _zharp_end=$(_zharp_now)
    wait
    _zharp_wait_readers stdout stderr

    _zharp_status=0
    _zharp_attrs="$(_zharp_kv process.command "$_zharp_name")"
    if [ "$_zharp_code" -ne 0 ]; then
        _zharp_status=2
        if [ ! -f "$_zharp_dir/reported" ]; then
            _zharp_output_tail > "$_zharp_dir/tail"
            _zharp_extra="$(_zharp_kv process.command "$_zharp_name"),$(_zharp_kv_int process.exit.code "$_zharp_code")"
            [ -s "$_zharp_dir/tail" ] && _zharp_extra="$_zharp_extra,$(_zharp_kv zharp.output "$(cat "$_zharp_dir/tail")")"
            _zharp_error_json CommandFailed "$_zharp_name exited with $_zharp_code" '' "$_zharp_extra" >> "$_zharp_dir/errors"
        fi
    fi
    _zharp_span_json "$_zharp_span" "$_zharp_parent" "$_zharp_name" "$_zharp_kind" "$_zharp_start" "$_zharp_end" "$_zharp_status" "$_zharp_code" "$_zharp_attrs" >> "$_zharp_dir/spans"

    cat "$_zharp_dir/errors" "$_zharp_dir/stdout.logs" "$_zharp_dir/stderr.logs" > "$_zharp_dir/logs" 2>/dev/null
    _zharp_send_logs "$_zharp_dir/logs" &
    _zharp_send_spans "$_zharp_dir/spans" &
    if [ -n "$_zharp_ping_target" ]; then
        if [ "$_zharp_code" -ne 0 ]; then _zharp_output_tail > "$_zharp_dir/ping"; fi
        _zharp_ping "$_zharp_ping_target" "$_zharp_code" "$_zharp_trace" "$_zharp_dir/ping" &
    fi
    wait
    rm -rf "$_zharp_dir"
    return "$_zharp_code"
}

_zharp_main() {
    case "${1:-}" in
        run) shift; _zharp_run "$@"; exit $? ;;
        version|--version|-v) printf 'zharp.sh %s\n' "$ZHARP_SH_VERSION"; exit 0 ;;
        *) cat >&2 <<'EOF'
zharp.sh: Zharp for shell scripts

  zharp run [--service NAME] [--monitor TOKEN] -- command [args...]
  source zharp.sh                      (at the top of a bash or zsh script)
  zharp version

https://zharp.io/docs/sdks/shell
EOF
            [ -z "${1:-}" ] && exit 0
            exit 2 ;;
    esac
}

# Run as a program (zharp run …), not sourced.
_zharp_sourced=1
if [ -n "${ZSH_VERSION:-}" ]; then
    case "${ZSH_EVAL_CONTEXT:-}" in *:file*) _zharp_sourced=1 ;; *) _zharp_sourced=0 ;; esac
elif [ -n "${BASH_VERSION:-}" ]; then
    eval '[ "${BASH_SOURCE[0]}" = "$0" ] && _zharp_sourced=0'
else
    case "$(_zharp_base "$0")" in zharp|zharp.sh) _zharp_sourced=0 ;; esac
fi
if [ "$_zharp_sourced" = 0 ]; then _zharp_main "$@"; fi

# --- The hook: sourced at the top of a script ----------------------------------------------------

# An interactive shell gets the functions only.
case "$-" in *i*) return 0 2>/dev/null ;; esac

_zharp_config
# Stop on the first error (unless ZHARP_ERREXIT=false): otherwise most failures go unnoticed.
if ! { [ -n "${ZHARP_ERREXIT:-}" ] && ! _zharp_truthy "$ZHARP_ERREXIT"; }; then
    set -e
    # dash has no pipefail, and a bad `set` option ends the script there: tried in a subshell first.
    if (set -o pipefail) 2>/dev/null; then set -o pipefail; fi
fi

_zharp_script=$0
[ -n "${ZSH_VERSION:-}" ] && eval '_zharp_script=${ZSH_ARGZERO:-$0}'
case "$_zharp_script" in /*) ;; *) _zharp_script="$(pwd)/$_zharp_script" ;; esac
_zharp_service=${ZHARP_SERVICE:-${OTEL_SERVICE_NAME:-$(_zharp_base "$_zharp_script" | sed 's/\.[A-Za-z0-9]*$//')}}
_zharp_name=$(_zharp_base "$_zharp_script")
[ "$_zharp_enabled" = 1 ] || return 0 2>/dev/null

_zharp_dir=$(mktemp -d 2>/dev/null || mktemp -d -t zharp)
_zharp_new_trace
_zharp_start=$(_zharp_now)
_zharp_err_code=''
_zharp_ping_target=$(_zharp_ping_url "${ZHARP_MONITOR:-}") || _zharp_ping_target=''
[ -n "$_zharp_ping_target" ] && _zharp_ping "$_zharp_ping_target" start

# The code around a line of a file, as {file, line, pre, code, post}.
_zharp_context_json() {
    [ -r "$1" ] || return 0
    ZHARP_CONTEXT_FILE=$1 awk -v L="$2" "$_zharp_awk_esc"'
        function cut(s) { return length(s) > 300 ? substr(s, 1, 297) "..." : s }
        NR >= L - 5 && NR < L { pre = pre (pre == "" ? "" : ",") "\"" esc(cut($0)) "\"" }
        NR == L { code = "\"" esc(cut($0)) "\""; found = 1 }
        NR > L && NR <= L + 5 { post = post (post == "" ? "" : ",") "\"" esc(cut($0)) "\"" }
        NR > L + 5 { exit }
        END { if (found) printf "{\"file\":\"%s\",\"line\":%d,\"pre\":[%s],\"code\":%s,\"post\":[%s]}", esc(ENVIRON["ZHARP_CONTEXT_FILE"]), L, pre, code, post }' "$1"
}

# Builds zharp.source_context from a stack ("at fn, file: line n" lines), the innermost five frames.
_zharp_source_context() {
    _zsc=''
    _zsc_n=0
    _zsc_tmp="$_zharp_dir/frames"
    printf '%s\n' "$1" > "$_zsc_tmp"
    while IFS= read -r _zsc_line; do
        [ "$_zsc_n" -ge 5 ] && break
        _zsc_rest=${_zsc_line#at *, }
        _zsc_file=${_zsc_rest%: line *}
        _zsc_ln=${_zsc_rest##*: line }
        case "$_zsc_file" in */zharp.sh|'<'*) continue ;; esac
        _zsc_one=$(_zharp_context_json "$_zsc_file" "$_zsc_ln")
        [ -z "$_zsc_one" ] && continue
        _zsc="$_zsc${_zsc:+,}$_zsc_one"
        _zsc_n=$((_zsc_n + 1))
    done < "$_zsc_tmp"
    [ -n "$_zsc" ] && printf '[%s]' "$_zsc"
}

# At exit: the error (if the script failed), the span, the logs, the monitor's finish ping.
zharp_finish() {
    _zf_code=${1:-$?}
    # Nothing here may stop the script early or count as its error.
    set +e
    trap - ERR 2>/dev/null
    [ -n "${ZSH_VERSION:-}" ] && eval "unfunction TRAPZERR 2>/dev/null; setopt NO_ERR_EXIT"
    [ -n "${_zharp_finished:-}" ] && return 0
    _zharp_finished=1
    _zharp_end=$(_zharp_now)
    # Hand the terminal back, so the output readers see the end of their input.
    if [ -n "${_zharp_redirected:-}" ]; then
        exec 1>&8 2>&9 8>&- 9>&-
        # The readers may outlive the script (zsh keeps their pipes): what they wrote is on disk.
        sleep 0.05 2>/dev/null || :
    fi
    TRACEPARENT=$_zharp_previous_traceparent
    _zf_status=0
    if [ "$_zf_code" -ne 0 ]; then
        _zf_status=2
        if [ -n "${_ZHARP_RUN_DIR:-}" ]; then : > "$_ZHARP_RUN_DIR/reported" 2>/dev/null; fi
        if [ -n "$_zharp_err_code" ]; then
            _zf_cmd=${_zharp_err_cmd:-command}
            _zf_stack=$_zharp_err_stack
        else
            # exit N, or a shell without an ERR trap: the exit code is what there is.
            _zf_cmd="$_zharp_name"
            _zf_stack=''
        fi
        _zf_program=${_zf_cmd%% *}
        _zf_extra="$(_zharp_kv_int process.exit.code "$_zf_code")"
        [ -n "$_zharp_err_code" ] && _zf_extra="$_zf_extra,$(_zharp_kv process.command_line "${_zharp_err_pipeline:-$_zf_cmd}")"
        _zf_tail=$(tail -n 50 "$_zharp_dir/stderr.tail" 2>/dev/null)
        [ -n "$_zf_tail" ] && _zf_extra="$_zf_extra,$(_zharp_kv zharp.output "$_zf_tail")"
        _zf_ctx=''
        [ -n "$_zf_stack" ] && _zf_ctx=$(_zharp_source_context "$_zf_stack")
        [ -n "$_zf_ctx" ] && _zf_extra="$_zf_extra,$(_zharp_kv zharp.source_context "$_zf_ctx")"
        if [ -n "$_zharp_err_code" ]; then
            _zf_message="$_zf_program exited with $_zharp_err_code: ${_zharp_err_pipeline:-$_zf_cmd}"
        else
            _zf_message="$_zharp_name exited with $_zf_code"
        fi
        _zharp_error_json CommandFailed "$_zf_message" "$_zf_stack" "$_zf_extra" >> "$_zharp_dir/errors"
    fi
    _zharp_span_json "$_zharp_span" "$_zharp_parent" "$_zharp_name" "$_zharp_kind" "$_zharp_start" "$_zharp_end" "$_zf_status" "$_zf_code" \
        "$(_zharp_kv code.file.path "$_zharp_script")" >> "$_zharp_dir/spans"
    cat "$_zharp_dir/errors" "$_zharp_dir/logs" "$_zharp_dir/stdout.logs" "$_zharp_dir/stderr.logs" > "$_zharp_dir/all.logs" 2>/dev/null
    _zharp_send_logs "$_zharp_dir/all.logs"
    _zharp_send_spans "$_zharp_dir/spans"
    if [ -n "$_zharp_ping_target" ]; then
        if [ "$_zf_code" -ne 0 ]; then
            { [ -n "${_zf_message:-}" ] && printf '%s\n' "$_zf_message"; [ -n "${_zf_stack:-}" ] && printf '%s\n' "$_zf_stack"; tail -n 50 "$_zharp_dir/stderr.tail" 2>/dev/null; } > "$_zharp_dir/ping"
        fi
        _zharp_ping "$_zharp_ping_target" "$_zf_code" "$_zharp_trace" "$_zharp_dir/ping"
    fi
    rm -rf "$_zharp_dir"
    return 0
}

# bash run as sh (macOS's /bin/sh) is in POSIX mode, where bash 3.2 has no >(...): a sh script there
# gets what it gets from dash.
_zharp_plain_sh=0
if [ -z "${BASH_VERSION:-}" ] && [ -z "${ZSH_VERSION:-}" ]; then _zharp_plain_sh=1; fi
case ":${SHELLOPTS:-}:" in *:posix:*) [ -n "${BASH_VERSION:-}" ] && _zharp_plain_sh=1 ;; esac
if [ "$_zharp_plain_sh" = 1 ]; then
    # Plain sh (dash, busybox): no ERR trap, so the exit code is what Zharp sees. `zharp run`
    # tells more there.
    _zharp_shell_name=sh
    trap 'zharp_finish $?' EXIT
    return 0 2>/dev/null
fi

# bash and zsh from here on.
if [ -n "${BASH_VERSION:-}" ]; then
    _zharp_shell_name=bash
    _zharp_shell_version=$BASH_VERSION
    set -o errtrace
    # The failing command, its exit code and line, and the function stack, written like PowerShell's:
    #   at copy_files, /opt/jobs/backup.sh: line 42
    _zharp_on_err() {
        _zharp_err_code=$1
        _zharp_err_cmd=$BASH_COMMAND
        # A subshell's error is reported by the shell that waits for it.
        [ "${BASH_SUBSHELL:-0}" -gt 0 ] && return 0
        local i n=${#FUNCNAME[@]} fn file line at=$2 stack='' text k
        # bash 3.2 (macOS) gives the function's first line as $LINENO in a trap inside a function:
        # the failing command is the first line from there that has its text.
        if (( BASH_VERSINFO[0] < 4 && n > 2 )); then
            k=$(ZHARP_CMD=$_zharp_err_cmd awk -v from="$2" 'NR >= from && index($0, ENVIRON["ZHARP_CMD"]) { print NR; exit }' "${BASH_SOURCE[1]}" 2>/dev/null)
            [[ -n "$k" ]] && at=$k
        fi
        # A pipeline: $BASH_COMMAND is only its last command. The line says which one failed.
        local -a statuses=($3)
        if (( ${#statuses[@]} > 1 )); then
            text=$(sed -n "${at}p" "${BASH_SOURCE[1]}" 2>/dev/null | sed -e "s/^[[:space:]]*//" -e "s/[[:space:]]*$//")
            for (( k = ${#statuses[@]} - 1; k >= 0; k-- )); do (( statuses[k] != 0 )) && break; done
            local -a parts
            IFS="|" read -r -a parts <<< "$text"
            if (( ${#parts[@]} == ${#statuses[@]} && k >= 0 )); then
                _zharp_err_code=${statuses[$k]}
                _zharp_err_cmd=$(printf "%s" "${parts[$k]}" | sed -e "s/^[[:space:]]*//" -e "s/[[:space:]]*$//")
                _zharp_err_pipeline=$text
            fi
        fi
        for (( i = 1; i < n; i++ )); do
            fn=${FUNCNAME[$i]}
            file=${BASH_SOURCE[$i]}
            if (( i == 1 )); then line=$at; else line=${BASH_LINENO[$((i - 1))]}; fi
            [[ "$fn" == source && "$file" == */zharp.sh ]] && continue
            [[ -n "$file" && "$file" != /* ]] && file="$_zharp_cwd/$file"
            stack+="${stack:+$'\n'}at $fn, ${file:-<No file>}: line $line"
        done
        _zharp_err_stack=$stack
    }
    _zharp_cwd=$PWD
    trap '_zharp_on_err $? $LINENO "${PIPESTATUS[*]}"' ERR
else
    _zharp_shell_name=zsh
    _zharp_shell_version=$ZSH_VERSION
    zmodload zsh/datetime 2>/dev/null
    if ! { [ -n "${ZHARP_ERREXIT:-}" ] && ! _zharp_truthy "$ZHARP_ERREXIT"; }; then setopt ERR_EXIT PIPE_FAIL; fi
    _zharp_cwd=$PWD
    # zsh has no $BASH_COMMAND: the failing line's own text stands in for the command.
    eval '
    TRAPZERR() {
        _zharp_err_code=$?
        local stop=0
        [[ -o errexit ]] && stop=1
        # Nothing in here may end the shell early: errexit and pipefail are off inside the trap.
        setopt localoptions noerrexit nopipefail
        (( ZSH_SUBSHELL > 0 )) && return 0
        local -a ft fs
        ft=("${funcfiletrace[@]}")
        fs=("${funcstack[@]}")
        local stack="" i file line fn nl="
"
        # funcfiletrace[1] is where TRAPZERR was called: the failing line.
        for (( i = 1; i <= ${#ft}; i++ )); do
            file=${ft[$i]%:*}
            line=${ft[$i]##*:}
            fn=${fs[$((i + 1))]:-main}
            [[ $file == */zharp.sh ]] && continue
            [[ -n $file && $file != /* && -r "$_zharp_cwd/$file" ]] && file="$_zharp_cwd/$file"
            stack+="${stack:+$nl}at $fn, $file: line $line"
            if (( i == 1 )); then
                [[ -r $file ]] && _zharp_err_cmd=$(sed -n "${line}p" "$file" 2>/dev/null | sed -e "s/^[[:space:]]*//" -e "s/[[:space:]]*$//")
            fi
        done
        _zharp_err_stack=$stack
        # zsh runs no EXIT trap when ERR_EXIT ends the script: finish here.
        (( stop )) && { zharp_finish $_zharp_err_code; exit $_zharp_err_code; }
        return 0
    }
    TRAPEXIT() { zharp_finish $?; }'
fi
[ -n "${BASH_VERSION:-}" ] && trap 'zharp_finish $?' EXIT

# Keep the end of stderr for the error (and, with ZHARP_LOGS=true, send stdout and stderr). The
# shell's own descriptors 8 and 9 hold the terminal so zharp_finish can give it back.
if [ "${ZHARP_CAPTURE_OUTPUT:-true}" != false ]; then
    exec 8>&1 9>&2
    if [ "$_zharp_logs" = 1 ]; then
        exec 1> >(_zharp_reader "$_zharp_dir" stdout 1 >&8)
        _zharp_redirected="stdout stderr"
    else
        _zharp_redirected="stderr"
    fi
    exec 2> >(_zharp_reader "$_zharp_dir" stderr "$_zharp_logs" >&9)
fi
