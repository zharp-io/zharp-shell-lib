# Changelog

## 0.1.0 — unreleased

First release: the `Zharp` PowerShell module and `zharp.sh`, at the same version.

### PowerShell (`Zharp`)
- `Start-Zharp`, `Invoke-Zharp { }` (a block as one span; an error that ends it reported once with
  its stack, column and the code that ran, then rethrown; `$ErrorActionPreference = 'Stop'` inside,
  `-KeepErrorAction` to keep yours), `Out-Zharp` (handled, or `-Unhandled` from a `trap`).
- Failed `Invoke-RestMethod` / `Invoke-WebRequest`: URL (secrets masked), method, status. Failed
  `Invoke-Sqlcmd`, `Invoke-DbaQuery`, `SqlException`: query (values out), database, server, number.
- `TRACEPARENT` inside the block; a trace the script was started in is continued.
  `Invoke-ZharpRestMethod`, `Invoke-ZharpWebRequest`, `-TraceHttp`.
- Logs off by default; `ZHARP_LOGS=true` sends the block's streams and `Write-Host`.
  `Write-ZharpLog` (`-Stamp` for the agent).
- Cron job monitor pings (`-Monitor`, `ZHARP_MONITOR`) with the run's trace.
- Windows PowerShell 5.1 and PowerShell 7.6; Windows, Linux, macOS.

### Shell (`zharp.sh`)
- The hook for bash and zsh: stops on the first failing command and reports it with its exit code,
  line, function stack, the code around it and the end of stderr; plain sh reports the exit code.
- `zharp run -- <command>` in POSIX sh: one span, exit code passed through, the output's tail on
  failure.
- `TRACEPARENT` exported, `zharp_curl`, `zharp_log`; logs off by default (`ZHARP_LOGS=true`).
- Cron job monitor pings (`--monitor`, `ZHARP_MONITOR`) with the run's trace.
