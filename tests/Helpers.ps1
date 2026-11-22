# Shared by the tests: load the module fresh, catch what it would send, read it back.

$script:RepoRoot = Split-Path -Parent $PSScriptRoot

function Import-ZharpForTest {
    param([hashtable]$Env = @{})
    foreach ($name in @('ZHARP_KEY', 'ZHARP_LOGS', 'ZHARP_MONITOR', 'ZHARP_SERVICE', 'ZHARP_ENDPOINT', 'ZHARP_DISABLED', 'ZHARP_TRACING', 'ZHARP_PING_URL', 'TRACEPARENT', 'ZHARP_CAPTURE_SOURCE_CONTEXT')) {
        Remove-Item "env:$name" -ErrorAction SilentlyContinue
    }
    $env:ZHARP_KEY = 'zpk_test'
    foreach ($k in $Env.Keys) {
        if ($null -eq $Env[$k]) { Remove-Item "env:$k" -ErrorAction SilentlyContinue } else { Set-Item "env:$k" $Env[$k] }
    }
    Import-Module (Join-Path $script:RepoRoot 'Zharp/Zharp.psd1') -Force -WarningAction SilentlyContinue
    $global:ZharpSent = New-Object System.Collections.ArrayList
    & (Get-Module Zharp) { $script:Transport = { param($Path, $Json) $null = $global:ZharpSent.Add([pscustomobject]@{ Path = $Path; Json = $Json }) } }
}

function Get-SentLogs {
    $out = @()
    foreach ($s in $global:ZharpSent) {
        if ($s.Path -ne '/v1/logs') { continue }
        $body = $s.Json | ConvertFrom-Json
        foreach ($r in $body.resourceLogs[0].scopeLogs[0].logRecords) { $out += $r }
    }
    return , $out
}

function Get-SentSpans {
    $out = @()
    foreach ($s in $global:ZharpSent) {
        if ($s.Path -ne '/v1/traces') { continue }
        $body = $s.Json | ConvertFrom-Json
        foreach ($r in $body.resourceSpans[0].scopeSpans[0].spans) { $out += $r }
    }
    return , $out
}

function Get-SentPings {
    return , @($global:ZharpSent | Where-Object { $_.Path -like 'ping:*' })
}

function Get-SentResource {
    foreach ($s in $global:ZharpSent) {
        if ($s.Path -eq '/v1/logs') { return Get-Attrs ($s.Json | ConvertFrom-Json).resourceLogs[0].resource.attributes }
        if ($s.Path -eq '/v1/traces') { return Get-Attrs ($s.Json | ConvertFrom-Json).resourceSpans[0].resource.attributes }
    }
}

# OTLP key/values as a hashtable of plain values.
function Get-Attrs($List) {
    $h = @{}
    foreach ($kv in $List) {
        $v = $kv.value
        if ($v.PSObject.Properties['stringValue']) { $h[$kv.key] = $v.stringValue }
        elseif ($v.PSObject.Properties['intValue']) { $h[$kv.key] = [long]$v.intValue }
        elseif ($v.PSObject.Properties['boolValue']) { $h[$kv.key] = $v.boolValue }
        elseif ($v.PSObject.Properties['doubleValue']) { $h[$kv.key] = $v.doubleValue }
    }
    return $h
}

function Get-ErrorLogs {
    return , @((Get-SentLogs) | Where-Object { (Get-Attrs $_.attributes).ContainsKey('exception.type') })
}

# A tiny HTTP server in the background for web-call tests: answers every request with $Status and
# remembers the traceparent header it got.
function Start-TestHttpServer([int]$Status = 404) {
    $port = Get-Random -Minimum 20000 -Maximum 40000
    $listener = New-Object System.Net.HttpListener
    $listener.Prefixes.Add("http://127.0.0.1:$port/")
    $listener.Start()
    $state = [hashtable]::Synchronized(@{ Traceparent = $null; Count = 0 })
    $ps = [powershell]::Create()
    $null = $ps.AddScript({
        param($listener, $status, $state)
        while ($listener.IsListening) {
            try { $ctx = $listener.GetContext() } catch { break }
            $state.Traceparent = $ctx.Request.Headers['traceparent']
            $state.Count++
            $ctx.Response.StatusCode = $status
            $bytes = [Text.Encoding]::UTF8.GetBytes('{"ok":false}')
            $ctx.Response.ContentType = 'application/json'
            $ctx.Response.OutputStream.Write($bytes, 0, $bytes.Length)
            $ctx.Response.Close()
        }
    }).AddArgument($listener).AddArgument($Status).AddArgument($state)
    $null = $ps.BeginInvoke()
    return [pscustomobject]@{ Url = "http://127.0.0.1:$port"; Listener = $listener; PowerShell = $ps; State = $state }
}

function Stop-TestHttpServer($Server) {
    try { $Server.Listener.Stop(); $Server.Listener.Close() } catch { }
    try { $null = $Server.PowerShell.BeginStop($null, $null) } catch { }
}
