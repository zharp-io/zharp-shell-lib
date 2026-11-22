# Zharp for PowerShell and shell scripts

Errors, a trace per run, logs and Cron job monitor pings from scripts, sent to
[Zharp](https://zharp.io): scheduled tasks and cron jobs, deploy and backup scripts, Azure
Automation runbooks, CI steps. What you want from a script is *did it fail, where, and with what
output*. This repository has both:

- **`Zharp`**, a PowerShell module (Windows PowerShell 5.1 and PowerShell 7, pure PowerShell, no
  assemblies), on the PowerShell Gallery.
- **`zharp.sh`**, one file that is a hook for bash and zsh scripts and the `zharp run` command for
  anything else.

Both send OTLP JSON over HTTPS, write their stacks the same way (`at <function>, <file>: line <n>`)
and never change how a script ends: an error is reported and the script fails as it would have; a
network failure is dropped.

## PowerShell

```powershell
Install-Module Zharp -Scope CurrentUser      # or Install-PSResource Zharp
```

```powershell
Import-Module Zharp
Start-Zharp -Service 'nightly-backup'         # the key from $env:ZHARP_KEY

Invoke-Zharp {                                 # the whole script as one span
    Copy-Database -Name shop
    Send-Report
}
```

- **`Invoke-Zharp { … }`** runs the block as one span (name, duration, how it ended). An error that
  ends it is reported once, with PowerShell's `ScriptStackTrace`, the column and the lines around
  the innermost five frames of your own files, then rethrown. Inside the block
  `$ErrorActionPreference` is `Stop`; `-KeepErrorAction` leaves yours.
- **Without the block**: `trap { $_ | Out-Zharp -Unhandled; break }` after `Start-Zharp`.
  (PowerShell has no hook for an error that ends a script, so the line is yours to add.)
- **`$_ | Out-Zharp`** in a `catch` reports a handled error. `Start-ZharpSpan` / `Stop-ZharpSpan`
  for steps; `Set-ZharpUser`, `Set-ZharpTag`, `Write-ZharpLog`, `Send-Zharp`.
- **Failed web calls** carry `url.full` (secret query values masked), the method and the status;
  **failed `Invoke-Sqlcmd` / `Invoke-DbaQuery` / `SqlException`** the query (values taken out), the
  database, the server and the error number.
- **Trace**: `$env:TRACEPARENT` is set inside the block, so `dotnet`, `node` or `python` programs
  with a Zharp SDK continue the trace. `Invoke-ZharpRestMethod` / `Invoke-ZharpWebRequest` add a
  client span and a `traceparent` header; `Invoke-Zharp -TraceHttp` adds the header to the plain
  cmdlets for the block.
- **Logs** are off by default. `ZHARP_LOGS=true` sends the block's Warning, Error, Information and
  Verbose streams and `Write-Host` (Output is the script's data, left alone). `Write-ZharpLog` is
  always sent; `Write-ZharpLog -Stamp` returns the line ending in `trace_id=… span_id=…` for a log
  file the Zharp agent reads.
- **Cron job monitors**: `Invoke-Zharp -Monitor <token>` (or `Start-Zharp -Monitor`,
  `ZHARP_MONITOR`) pings the monitor at start and at the end with `0` or `1`, the run's trace and,
  on failure, the error. End the block with `return` or `throw`, not `exit`: PowerShell doesn't
  tell a module the code a block exited with, so no finish ping is sent after `exit`.

| `Start-Zharp` | Environment | Default |
|---|---|---|
| `-Key` | `ZHARP_KEY` | nothing is sent without one; the script runs as written |
| `-Service` | `ZHARP_SERVICE`, `OTEL_SERVICE_NAME` | the script's file name |
| `-Environment` | `ZHARP_ENVIRONMENT` | — |
| `-Release` | `ZHARP_RELEASE` | — |
| `-Endpoint` | `ZHARP_ENDPOINT` | `https://api.zharp.io/api/v1/otlp` |
| `-Monitor` | `ZHARP_MONITOR` | — |
| `-Logs` | `ZHARP_LOGS` | off |
| `-NoSourceContext` | `ZHARP_CAPTURE_SOURCE_CONTEXT=false` | the code that ran is sent |
| — | `ZHARP_TRACING=false` | errors and logs only |
| — | `ZHARP_DISABLED=true`, `ZHARP_DEBUG=true` | — |

What's queued is sent when the outermost block ends, when an error ends it, and when PowerShell
exits — gzipped, two seconds at most per request.

## Shell scripts

```sh
sudo curl -fsSL https://zharp.io/zharp.sh -o /usr/local/lib/zharp.sh
sudo chmod +x /usr/local/lib/zharp.sh
sudo ln -sf /usr/local/lib/zharp.sh /usr/local/bin/zharp
```

**The hook** (bash, zsh):

```bash
#!/usr/bin/env bash
source /usr/local/lib/zharp.sh       # ZHARP_KEY from the environment
rsync -a /data backup:/data
```

The script stops on its first failing command (`set -Eeo pipefail`; zsh `ERR_EXIT PIPE_FAIL`;
`ZHARP_ERREXIT=false` keeps yours). That command is reported as `CommandFailed` —
`rsync exited with 23: rsync -a /data backup:/data` — with the line, the function stack, the code
around each frame and the last 50 lines of stderr:

```
at copy_files, /opt/jobs/backup.sh: line 42
at main, /opt/jobs/backup.sh: line 60
```

In a pipeline the failing command is named, not the last one. Plain `sh` (dash, busybox) has no
`ERR` trap: there the hook reports the exit code only; use `zharp run`. A script that sets its own
`EXIT` trap calls `zharp_finish $?` in it.

**`zharp run`** (any POSIX sh):

```cron
ZHARP_KEY=zpk_…
0 3 * * *  zharp run --service nightly-backup --monitor <token> -- /opt/jobs/backup.sh
```

Runs anything as one span: duration, exit code, and on failure the tail of its output. Output goes
where it went; the exit code is passed through. A script under `zharp run` that also sources the
hook is reported once.

- `TRACEPARENT` is exported; `zharp_curl` adds it to a curl call as a span.
- `ZHARP_LOGS=true` sends stdout and stderr line by line. `zharp_log "message"` prints a stamped
  line (and sends it).
- `--monitor` / `ZHARP_MONITOR` pings a Cron job monitor at start and with the exit code and trace.
- Settings: `ZHARP_KEY`, `ZHARP_SERVICE`, `ZHARP_ENVIRONMENT`, `ZHARP_RELEASE`, `ZHARP_ENDPOINT`,
  `ZHARP_LOGS`, `ZHARP_MONITOR`, `ZHARP_ERREXIT`, `ZHARP_CAPTURE_OUTPUT`, `ZHARP_DISABLED`,
  `ZHARP_DEBUG`.

bash 4/5 and zsh 5 for the hook (bash 3.2, as on macOS, names the line a function starts on rather
than the failing line in it); any POSIX sh with curl or wget for `zharp run`.

## Development

```sh
powershell -File tests/run.ps1         # Windows PowerShell 5.1 (Pester 5, or tests/MiniPester.ps1)
docker build -t zharp-pwsh:7.6 -f tests/docker/pwsh.Dockerfile tests/docker
docker run --rm -v "$PWD:/src" zharp-pwsh:7.6 pwsh -File /src/tests/run.ps1
sh tests/run-shell.sh                  # bats (bash, zsh, sh) + bash 3.2, dash/mawk, busybox
ZHARP_E2E_TOKEN_FILE=… node e2e/run.mjs   # against a local backend on :3000
```

Publishing (maintainers): `Publish-Module -Path ./Zharp -NuGetApiKey $env:PSGALLERY_KEY`, and
`zharp.sh` with its SHA-256 on the GitHub release and at zharp.io.

MIT License.
