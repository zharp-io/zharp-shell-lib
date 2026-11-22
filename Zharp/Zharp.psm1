# Zharp for PowerShell: errors, traces and logs from scripts, sent to Zharp as OTLP JSON.
#
# Pure PowerShell (Windows PowerShell 5.1 and PowerShell 7), no assemblies of its own. Kept to
# ASCII so Windows PowerShell 5.1 reads the file the same whatever its code page.

$script:Version = '0.1.0'
$script:ModuleDir = $PSScriptRoot
$script:Config = $null
$script:Spans = New-Object System.Collections.ArrayList      # finished, waiting to be sent
$script:Logs = New-Object System.Collections.ArrayList       # waiting to be sent
$script:Active = New-Object System.Collections.ArrayList     # open spans, innermost last
$script:Reported = New-Object System.Collections.ArrayList   # exceptions already reported
$script:User = [ordered]@{}
$script:Tags = [ordered]@{}
$script:Rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
$script:SourceCache = @{}
$script:ExitRegistered = $false
$script:Warned = $false
# Tests replace this with a scriptblock (param($Path, $Json)) to see what would be sent.
$script:Transport = $null

$script:DefaultEndpoint = 'https://api.zharp.io/api/v1/otlp'
$script:MaxSourceFrames = 5
$script:Around = 5
$script:MaxLine = 300
$script:MaxContextBytes = 12000

# Windows PowerShell 5.1 on older .NET offers TLS 1.0 only unless asked.
try {
    if ($PSVersionTable.PSEdition -ne 'Core') {
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    }
} catch { }

# --- Small helpers ----------------------------------------------------------------------------

function Test-ZharpTruthy([string]$Value) {
    return @('1', 'true', 'yes', 'on') -contains ([string]$Value).Trim().ToLowerInvariant()
}

function Get-ZharpNow {
    # Unix time in nanoseconds, as OTLP JSON wants it: a string.
    return [string](([DateTime]::UtcNow.Ticks - 621355968000000000) * 100)
}

function New-ZharpId([int]$Bytes) {
    $buffer = New-Object byte[] $Bytes
    $script:Rng.GetBytes($buffer)
    return -join ($buffer | ForEach-Object { $_.ToString('x2') })
}

function Write-ZharpDebug([string]$Message) {
    if ($script:Config -and $script:Config.Debug) { [Console]::Error.WriteLine("[Zharp] $Message") }
}

function Test-ZharpOwnFile([string]$Path) {
    if (-not $Path) { return $false }
    try { return ([IO.Path]::GetFullPath($Path)).StartsWith($script:ModuleDir, [StringComparison]::OrdinalIgnoreCase) } catch { return $false }
}

# The script that is running (the outermost file that isn't Zharp's), or $null at a prompt.
function Get-ZharpScriptPath {
    $frames = @(Get-PSCallStack | Where-Object { $_.ScriptName -and -not (Test-ZharpOwnFile $_.ScriptName) })
    if ($frames.Count -gt 0) { return $frames[$frames.Count - 1].ScriptName }
    return $null
}

# A URL as it is safe to keep: no user or password, secret-looking query values masked.
function Get-ZharpSafeUrl($Url) {
    if (-not $Url) { return '' }
    $text = [string]$Url
    $text = $text -replace '^([a-zA-Z][\w+.-]*://)[^/@\s]+@', '$1'
    return [regex]::Replace($text, '([?&])([^=&#]*(?:token|key|secret|password|passwd|pwd|sig|signature|auth|code|session|credential)[^=&#]*)=([^&#]*)', '$1$2=[REDACTED]', 'IgnoreCase')
}

# A query with its literal values taken out, as the other Zharp SDKs send failed queries.
function Get-ZharpObfuscatedQuery([string]$Query) {
    if (-not $Query) { return '' }
    $text = [regex]::Replace($Query, "N?'(?:[^']|'')*'", '?')
    $text = [regex]::Replace($text, '(?<![\w@$#.])-?\d+(?:\.\d+)?(?![\w.])', '?')
    if ($text.Length -gt 4000) { $text = $text.Substring(0, 4000) }
    return $text
}

# --- Configuration ----------------------------------------------------------------------------

function Start-Zharp {
    <#
    .SYNOPSIS
    Starts Zharp for this script: where to send, as which service.
    .DESCRIPTION
    Every parameter can come from the environment instead (ZHARP_KEY, ZHARP_SERVICE,
    ZHARP_ENVIRONMENT, ZHARP_RELEASE, ZHARP_ENDPOINT, ZHARP_LOGS, ZHARP_MONITOR). Without a key
    nothing is sent and the script runs as it would without Zharp.
    .EXAMPLE
    Start-Zharp -Service 'nightly-backup'
    #>
    [CmdletBinding()]
    param(
        [string]$Key,
        [string]$Service,
        [string]$Environment,
        [string]$Release,
        [string]$Endpoint,
        [string]$Monitor,
        [switch]$Logs,
        [switch]$NoSourceContext
    )
    $config = [ordered]@{
        Key = if ($Key) { $Key } else { $env:ZHARP_KEY }
        Service = $Service
        Environment = if ($Environment) { $Environment } else { $env:ZHARP_ENVIRONMENT }
        Release = if ($Release) { $Release } else { $env:ZHARP_RELEASE }
        Endpoint = if ($Endpoint) { $Endpoint } elseif ($env:ZHARP_ENDPOINT) { $env:ZHARP_ENDPOINT } else { $script:DefaultEndpoint }
        Monitor = if ($Monitor) { $Monitor } else { $env:ZHARP_MONITOR }
        Logs = [bool]$Logs -or (Test-ZharpTruthy $env:ZHARP_LOGS)
        SourceContext = -not $NoSourceContext -and -not ($env:ZHARP_CAPTURE_SOURCE_CONTEXT -and -not (Test-ZharpTruthy $env:ZHARP_CAPTURE_SOURCE_CONTEXT))
        Tracing = -not ($env:ZHARP_TRACING -and -not (Test-ZharpTruthy $env:ZHARP_TRACING))
        Debug = Test-ZharpTruthy $env:ZHARP_DEBUG
        Disabled = Test-ZharpTruthy $env:ZHARP_DISABLED
        ScriptPath = Get-ZharpScriptPath
        ParentTrace = $null
        ParentSpan = $null
        Resource = $null
    }
    $config.Endpoint = $config.Endpoint.TrimEnd('/')
    if (-not $config.Service) {
        if ($env:ZHARP_SERVICE) { $config.Service = $env:ZHARP_SERVICE }
        elseif ($env:OTEL_SERVICE_NAME) { $config.Service = $env:OTEL_SERVICE_NAME }
        elseif ($config.ScriptPath) { $config.Service = [IO.Path]::GetFileNameWithoutExtension($config.ScriptPath) }
        else { $config.Service = 'powershell' }
    }
    # A program that started this script with a trace (TRACEPARENT): the script continues it.
    if ($env:TRACEPARENT -match '^[0-9a-f]{2}-([0-9a-f]{32})-([0-9a-f]{16})-[0-9a-f]{2}$') {
        $config.ParentTrace = $Matches[1]
        $config.ParentSpan = $Matches[2]
    }
    if (-not $config.Key -and -not $config.Disabled) {
        if (-not $script:Warned) {
            Write-Warning 'Zharp: no key, so nothing is sent. Set ZHARP_KEY (Settings > Applications in Zharp) or pass -Key.'
            $script:Warned = $true
        }
        $config.Disabled = $true
    }
    $config.Resource = New-ZharpResource $config
    $script:Config = $config

    if (-not $script:ExitRegistered -and -not $config.Disabled) {
        # A script that ends without Invoke-Zharp's block still sends what it queued.
        $null = Register-EngineEvent -SourceIdentifier PowerShell.Exiting -MessageData $ExecutionContext.SessionState.Module -Action {
            try { & $Event.MessageData { Send-Zharp } } catch { }
        }
        $script:ExitRegistered = $true
    }
    Write-ZharpDebug "started: service '$($config.Service)', endpoint $($config.Endpoint)"
}

function Initialize-Zharp {
    if (-not $script:Config) { Start-Zharp }
}

function New-ZharpResource($Config) {
    $edition = if ($PSVersionTable.PSEdition -eq 'Core') { 'PowerShell' } else { 'Windows PowerShell' }
    $os = 'windows'
    if (Get-Variable -Name IsLinux -ValueOnly -ErrorAction SilentlyContinue) { $os = 'linux' }
    elseif (Get-Variable -Name IsMacOS -ValueOnly -ErrorAction SilentlyContinue) { $os = 'darwin' }
    $attributes = [ordered]@{
        'service.name' = $Config.Service
        'telemetry.sdk.name' = 'zharp'
        'telemetry.sdk.language' = 'powershell'
        'telemetry.sdk.version' = $script:Version
        'process.runtime.name' = $edition
        'process.runtime.version' = $PSVersionTable.PSVersion.ToString()
        'process.pid' = $PID
        'host.name' = [Environment]::MachineName
        'os.type' = $os
    }
    if ($Config.Release) { $attributes['service.version'] = $Config.Release }
    if ($Config.Environment) { $attributes['deployment.environment.name'] = $Config.Environment }
    return $attributes
}

# --- Context: user and tags -------------------------------------------------------------------

function Set-ZharpUser {
    <#
    .SYNOPSIS
    The user this run is for, on its spans, logs and errors from here on.
    #>
    [CmdletBinding()]
    param([string]$Id, [string]$Email, [string]$Name)
    $script:User = [ordered]@{}
    if ($Id) { $script:User['enduser.id'] = $Id }
    if ($Email) { $script:User['enduser.email'] = $Email }
    if ($Name) { $script:User['enduser.name'] = $Name }
}

function Set-ZharpTag {
    <#
    .SYNOPSIS
    A tag on every span, log and error from here on. An empty value removes it.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true, Position = 0)][string]$Name, [Parameter(Position = 1)]$Value)
    if ($null -eq $Value -or [string]$Value -eq '') { $script:Tags.Remove($Name) } else { $script:Tags[$Name] = [string]$Value }
}

function Get-ZharpContextAttributes {
    $out = [ordered]@{}
    foreach ($k in $script:Tags.Keys) { $out[$k] = $script:Tags[$k] }
    foreach ($k in $script:User.Keys) { $out[$k] = $script:User[$k] }
    return $out
}

# --- Spans ------------------------------------------------------------------------------------

function Get-ZharpCurrentSpan {
    if ($script:Active.Count -gt 0) { return $script:Active[$script:Active.Count - 1] }
    return $null
}

function Get-ZharpTraceIds {
    $span = Get-ZharpCurrentSpan
    if ($span) { return @($span.TraceId, $span.SpanId) }
    if ($script:Config -and $script:Config.ParentTrace) { return @($script:Config.ParentTrace, $script:Config.ParentSpan) }
    return @('', '')
}

function Start-ZharpSpan {
    <#
    .SYNOPSIS
    Starts a span for a step of the script; end it with Stop-ZharpSpan.
    .EXAMPLE
    $span = Start-ZharpSpan 'copy files'
    Copy-Item ...
    Stop-ZharpSpan $span
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true, Position = 0)][string]$Name,
        [hashtable]$Attributes,
        [ValidateSet('Internal', 'Server', 'Client', 'Producer', 'Consumer')][string]$Kind = 'Internal'
    )
    Initialize-Zharp
    $parent = Get-ZharpCurrentSpan
    $kinds = @{ Internal = 1; Server = 2; Client = 3; Producer = 4; Consumer = 5 }
    $span = [pscustomobject]@{
        PSTypeName = 'Zharp.Span'
        Name = $Name
        TraceId = ''
        SpanId = New-ZharpId 8
        ParentSpanId = ''
        Kind = $kinds[$Kind]
        Start = Get-ZharpNow
        End = $null
        Attributes = [ordered]@{}
        Events = New-Object System.Collections.ArrayList
        Status = 0
        StatusMessage = ''
        PreviousTraceparent = $env:TRACEPARENT
    }
    if ($parent) {
        $span.TraceId = $parent.TraceId
        $span.ParentSpanId = $parent.SpanId
    } elseif ($script:Config.ParentTrace) {
        $span.TraceId = $script:Config.ParentTrace
        $span.ParentSpanId = $script:Config.ParentSpan
        # Started by a traced program: this run is where the script's own work comes in.
        if ($Kind -eq 'Internal') { $span.Kind = 2 }
    } else {
        $span.TraceId = New-ZharpId 16
    }
    if ($Attributes) { foreach ($k in $Attributes.Keys) { $span.Attributes[[string]$k] = $Attributes[$k] } }
    $null = $script:Active.Add($span)
    # Programs the script starts (dotnet, node, python with a Zharp SDK) continue this trace.
    $env:TRACEPARENT = "00-$($span.TraceId)-$($span.SpanId)-01"
    return $span
}

function Stop-ZharpSpan {
    <#
    .SYNOPSIS
    Ends a span started with Start-ZharpSpan (the innermost open one without -Span).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Position = 0)]$Span,
        [switch]$Failed,
        [string]$Message
    )
    if (-not $Span) { $Span = Get-ZharpCurrentSpan }
    if (-not $Span -or $Span.End) { return }
    $Span.End = Get-ZharpNow
    if ($Failed) {
        $Span.Status = 2
        if ($Message) { $Span.StatusMessage = $Message }
    }
    $index = $script:Active.IndexOf($Span)
    if ($index -ge 0) { $script:Active.RemoveAt($index) }
    $env:TRACEPARENT = $Span.PreviousTraceparent
    if ($script:Config -and $script:Config.Tracing -and -not $script:Config.Disabled) {
        $null = $script:Spans.Add($Span)
        if ($script:Spans.Count -ge 200) { Send-Zharp }
    }
}

# --- Errors -----------------------------------------------------------------------------------

function Test-ZharpReported($Exception) {
    foreach ($e in $script:Reported) { if ([object]::ReferenceEquals($e, $Exception)) { return $true } }
    return $false
}

function Add-ZharpReported($Exception) {
    $null = $script:Reported.Add($Exception)
    if ($script:Reported.Count -gt 100) { $script:Reported.RemoveAt(0) }
}

# The error record behind what was passed: an ErrorRecord, an exception, or text.
function Resolve-ZharpError($InputObject) {
    $record = $null
    $exception = $null
    if ($InputObject -is [System.Management.Automation.ErrorRecord]) {
        $record = $InputObject
        $exception = $record.Exception
    } elseif ($InputObject -is [Exception]) {
        $exception = $InputObject
        if ($exception -is [System.Management.Automation.IContainsErrorRecord] -and $exception.ErrorRecord) { $record = $exception.ErrorRecord }
    } else {
        $exception = New-Object System.Management.Automation.RuntimeException ([string]$InputObject)
    }
    # -ErrorAction Stop wraps the cmdlet's own error.
    if ($exception -is [System.Management.Automation.ActionPreferenceStopException] -and $exception.ErrorRecord -and $exception.ErrorRecord.Exception) {
        $record = $exception.ErrorRecord
        $exception = $record.Exception
    }
    return @{ Record = $record; Exception = $exception }
}

# A stack as PowerShell writes ScriptStackTrace, without Zharp's own frames:
#   at Copy-Database, C:\jobs\backup.ps1: line 13
#   at <ScriptBlock>, C:\jobs\backup.ps1: line 40
function Get-ZharpStack($Record, [int]$Skip = 0) {
    $text = ''
    if ($Record -and $Record.ScriptStackTrace) { $text = [string]$Record.ScriptStackTrace }
    if (-not $text) {
        $lines = foreach ($f in @(Get-PSCallStack | Select-Object -Skip ($Skip + 1))) {
            $file = if ($f.ScriptName) { $f.ScriptName } else { '<No file>' }
            "at $($f.FunctionName), ${file}: line $($f.ScriptLineNumber)"
        }
        $text = $lines -join "`n"
    }
    $kept = foreach ($line in ($text -split "\r?\n")) {
        if (-not $line.Trim()) { continue }
        $frame = ConvertFrom-ZharpFrame $line
        if ($frame -and (Test-ZharpOwnFile $frame.File)) { continue }
        $line.Trim()
    }
    return (@($kept) -join "`n")
}

function ConvertFrom-ZharpFrame([string]$Line) {
    if ($Line.Trim() -match '^at (.+?), (.+): line (\d+)$') {
        return @{ Function = $Matches[1]; File = $Matches[2]; Line = [int]$Matches[3] }
    }
    return $null
}

# Folders whose code isn't the app's: modules from $env:PSModulePath and PowerShell itself.
function Get-ZharpLibraryRoots {
    $roots = New-Object System.Collections.ArrayList
    foreach ($p in (([string]$env:PSModulePath) -split [IO.Path]::PathSeparator)) { if ($p) { $null = $roots.Add($p.TrimEnd('\', '/')) } }
    if ($PSHOME) { $null = $roots.Add($PSHOME.TrimEnd('\', '/')) }
    $null = $roots.Add($script:ModuleDir)
    return $roots
}

function Test-ZharpAppFile([string]$Path) {
    if (-not $Path -or $Path.StartsWith('<')) { return $false }
    foreach ($root in (Get-ZharpLibraryRoots)) {
        if ($Path.StartsWith($root + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase) -or
            $Path.StartsWith($root + '/', [StringComparison]::OrdinalIgnoreCase)) { return $false }
    }
    return $true
}

function Get-ZharpFileLines([string]$Path) {
    if ($script:SourceCache.ContainsKey($Path)) { return $script:SourceCache[$Path] }
    $lines = $null
    try {
        $item = Get-Item -LiteralPath $Path -ErrorAction Stop
        if ($item.Length -lt 2000000) { $lines = [IO.File]::ReadAllLines($Path) }
    } catch { }
    if ($script:SourceCache.Count -gt 100) { $script:SourceCache.Clear() }
    $script:SourceCache[$Path] = $lines
    return $lines
}

function Get-ZharpCut([string]$Text) {
    if ($null -eq $Text) { return '' }
    if ($Text.Length -le $script:MaxLine) { return $Text }
    return $Text.Substring(0, $script:MaxLine - 3) + '...'
}

# The code around the innermost five frames of the app's own files: [{file, line, pre, code, post}].
function Get-ZharpSourceContext([string]$Stack) {
    if (-not $script:Config -or -not $script:Config.SourceContext -or -not $Stack) { return $null }
    $out = New-Object System.Collections.ArrayList
    $seen = @{}
    foreach ($line in ($Stack -split "`n")) {
        if ($out.Count -ge $script:MaxSourceFrames) { break }
        $frame = ConvertFrom-ZharpFrame $line
        if (-not $frame -or -not (Test-ZharpAppFile $frame.File)) { continue }
        $key = "$($frame.File):$($frame.Line)"
        if ($seen.ContainsKey($key)) { continue }
        $seen[$key] = $true
        $lines = Get-ZharpFileLines $frame.File
        if (-not $lines -or $frame.Line -lt 1 -or $frame.Line -gt $lines.Count) { continue }
        $index = $frame.Line - 1
        $first = [Math]::Max(0, $index - $script:Around)
        $pre = @(); for ($i = $first; $i -lt $index; $i++) { $pre += Get-ZharpCut $lines[$i] }
        $post = @(); for ($i = $index + 1; $i -le [Math]::Min($lines.Count - 1, $index + $script:Around); $i++) { $post += Get-ZharpCut $lines[$i] }
        $null = $out.Add([ordered]@{ file = $frame.File; line = $frame.Line; pre = $pre; code = (Get-ZharpCut $lines[$index]); post = $post })
    }
    while ($out.Count -gt 0) {
        $json = ConvertTo-Json -InputObject @($out) -Depth 5 -Compress
        if ([Text.Encoding]::UTF8.GetByteCount($json) -le $script:MaxContextBytes) { return $json }
        $out.RemoveAt($out.Count - 1)
    }
    return $null
}

# A failed web call (Invoke-RestMethod, Invoke-WebRequest): its URL, method and status.
function Get-ZharpWebAttributes($Exception, $Record) {
    $out = [ordered]@{}
    try {
        $response = $null
        if ($Exception.PSObject.Properties['Response']) { $response = $Exception.Response }
        $uri = $null
        $method = $null
        if ($Record -and $Record.TargetObject) {
            $target = $Record.TargetObject
            if ($target.PSObject.Properties['RequestUri']) { $uri = $target.RequestUri }
            if ($target.PSObject.Properties['Method']) { $method = [string]$target.Method }
        }
        if ($response) {
            if (-not $uri -and $response.PSObject.Properties['ResponseUri']) { $uri = $response.ResponseUri }
            if (-not $uri -and $response.PSObject.Properties['RequestMessage'] -and $response.RequestMessage) { $uri = $response.RequestMessage.RequestUri; $method = [string]$response.RequestMessage.Method }
            if ($response.PSObject.Properties['StatusCode']) { $out['http.response.status_code'] = [int]$response.StatusCode }
        }
        if (-not $uri -and $Record -and $Record.InvocationInfo -and $Record.InvocationInfo.BoundParameters -and $Record.InvocationInfo.BoundParameters.ContainsKey('Uri')) {
            $uri = $Record.InvocationInfo.BoundParameters['Uri']
        }
        $command = ''
        if ($Record -and $Record.InvocationInfo -and $Record.InvocationInfo.MyCommand) { $command = [string]$Record.InvocationInfo.MyCommand.Name }
        $isWeb = $response -or ($Exception -is [System.Net.WebException]) -or ($command -match '^(Invoke-RestMethod|Invoke-WebRequest|Invoke-ZharpRestMethod|Invoke-ZharpWebRequest)$') -or
            ($Exception.GetType().FullName -match 'HttpResponseException|HttpRequestException')
        if (-not $isWeb) { return [ordered]@{} }
        if ($uri) { $out['url.full'] = Get-ZharpSafeUrl $uri }
        if ($method) { $out['http.request.method'] = $method.ToUpperInvariant() }
        elseif ($Record -and $Record.InvocationInfo -and $Record.InvocationInfo.BoundParameters.ContainsKey('Method')) { $out['http.request.method'] = ([string]$Record.InvocationInfo.BoundParameters['Method']).ToUpperInvariant() }
        $out['zharp.mechanism'] = 'http'
    } catch { }
    return $out
}

# A failed query (Invoke-Sqlcmd, dbatools' Invoke-DbaQuery, a SqlException): the query, where it ran, the error number.
function Get-ZharpSqlAttributes($Exception, $Record) {
    $out = [ordered]@{}
    try {
        $sql = $null
        $e = $Exception
        for ($i = 0; $e -and $i -lt 5; $i++) {
            $names = @($e.PSObject.TypeNames) + @($e.GetType().FullName)
            if ($names | Where-Object { $_ -match 'SqlException$' }) { $sql = $e; break }
            $e = $e.InnerException
        }
        $bound = $null
        $command = ''
        if ($Record -and $Record.InvocationInfo) {
            $bound = $Record.InvocationInfo.BoundParameters
            if ($Record.InvocationInfo.MyCommand) { $command = [string]$Record.InvocationInfo.MyCommand.Name }
        }
        $isQueryCommand = $command -match '^(Invoke-Sqlcmd|Invoke-DbaQuery|Invoke-SqlQuery)$'
        if (-not $sql -and -not $isQueryCommand) { return $out }
        $out['db.system.name'] = 'microsoft.sql_server'
        $out['zharp.mechanism'] = 'db'
        $query = $null
        if ($bound) {
            if ($bound.ContainsKey('Query')) { $query = [string]$bound['Query'] }
            elseif ($bound.ContainsKey('InputFile')) { $out['db.query.file'] = [string]$bound['InputFile'] }
            foreach ($name in @('Database', 'DatabaseName')) { if ($bound.ContainsKey($name)) { $out['db.namespace'] = [string]$bound[$name] } }
            foreach ($name in @('ServerInstance', 'SqlInstance', 'Server')) { if ($bound.ContainsKey($name)) { $out['server.address'] = [string]$bound[$name] } }
        }
        if ($query) { $out['db.query.text'] = Get-ZharpObfuscatedQuery $query }
        if ($sql) {
            if ($sql.PSObject.Properties['Number']) { $out['db.response.status_code'] = [string]$sql.Number }
            if (-not $out.Contains('server.address') -and $sql.PSObject.Properties['Server'] -and $sql.Server) { $out['server.address'] = [string]$sql.Server }
            if ($sql.PSObject.Properties['Procedure'] -and $sql.Procedure) { $out['db.stored_procedure.name'] = [string]$sql.Procedure }
            if ($sql.PSObject.Properties['LineNumber'] -and $sql.LineNumber) { $out['db.query.line'] = [string]$sql.LineNumber }
        }
    } catch { }
    return $out
}

function Get-ZharpErrorAttributes($InputObject, [bool]$Handled, [int]$Skip = 0) {
    $resolved = Resolve-ZharpError $InputObject
    $record = $resolved.Record
    $exception = $resolved.Exception
    # .NET method calls ([IO.File]::ReadAllText) wrap what they threw: its type says what happened.
    $typed = $exception
    if (($exception -is [System.Management.Automation.MethodInvocationException] -or $exception -is [System.Management.Automation.GetValueInvocationException] -or $exception -is [System.Management.Automation.SetValueInvocationException]) -and $exception.InnerException) {
        $typed = $exception.InnerException
    }
    $stack = Get-ZharpStack $record ($Skip + 1)
    $attrs = Get-ZharpContextAttributes
    $attrs['exception.type'] = $typed.GetType().FullName
    $attrs['exception.message'] = [string]$exception.Message
    $attrs['exception.stacktrace'] = $stack
    $attrs['zharp.handled'] = if ($Handled) { 'true' } else { 'false' }
    if ($record) {
        if ($record.FullyQualifiedErrorId) { $attrs['powershell.error.id'] = [string]$record.FullyQualifiedErrorId }
        if ($record.CategoryInfo) { $attrs['powershell.error.category'] = [string]$record.CategoryInfo.Category }
        $info = $record.InvocationInfo
        if ($info -and $info.ScriptName -and -not (Test-ZharpOwnFile $info.ScriptName)) {
            $attrs['code.file.path'] = $info.ScriptName
            $attrs['code.line.number'] = $info.ScriptLineNumber
            $attrs['code.column.number'] = $info.OffsetInLine
            if ($info.MyCommand -and $info.MyCommand.Name) { $attrs['powershell.command'] = [string]$info.MyCommand.Name }
        }
    }
    $code = Get-ZharpSourceContext $stack
    if ($code) { $attrs['zharp.source_context'] = $code }
    foreach ($extra in @((Get-ZharpWebAttributes $exception $record), (Get-ZharpSqlAttributes $exception $record))) {
        foreach ($k in $extra.Keys) { $attrs[$k] = $extra[$k] }
    }
    return @{ Attributes = $attrs; Exception = $exception }
}

# Reports an error once: a log record with the exception, on the current span.
function Submit-ZharpError($InputObject, [bool]$Handled, $Attributes, [int]$Skip = 0) {
    Initialize-Zharp
    if ($script:Config.Disabled) { return $false }
    $resolved = Resolve-ZharpError $InputObject
    if (Test-ZharpReported $resolved.Exception) { return $false }
    Add-ZharpReported $resolved.Exception
    $built = Get-ZharpErrorAttributes $InputObject $Handled ($Skip + 1)
    $attrs = $built.Attributes
    if ($Attributes) { foreach ($k in $Attributes.Keys) { $attrs[[string]$k] = $Attributes[$k] } }
    $message = "$($attrs['exception.type']): $($attrs['exception.message'])"
    $span = Get-ZharpCurrentSpan
    if ($span) {
        # On the span for the trace view; the log record below is the one Zharp counts.
        $exceptionEvent = [ordered]@{
            'exception.type' = $attrs['exception.type']
            'exception.message' = $attrs['exception.message']
            'exception.stacktrace' = $attrs['exception.stacktrace']
            'zharp.deferred' = 'true'
        }
        $null = $span.Events.Add(@{ Name = 'exception'; Time = (Get-ZharpNow); Attributes = $exceptionEvent })
    }
    Add-ZharpLog -Severity 'ERROR' -Number 17 -Body $message -Attributes $attrs
    return $true
}

function Out-Zharp {
    <#
    .SYNOPSIS
    Reports an error to Zharp: in a catch block, $_ | Out-Zharp.
    .DESCRIPTION
    Handled by default (the script caught it). -Unhandled for a trap that lets the error end the
    script: trap { $_ | Out-Zharp -Unhandled; break }. Each error is reported once.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true, ValueFromPipeline = $true, Position = 0)]$InputObject,
        [hashtable]$Attributes,
        [switch]$Unhandled
    )
    process {
        $sent = Submit-ZharpError $InputObject (-not $Unhandled) $Attributes 1
        if ($Unhandled) {
            # The script is about to end: close what is open and send now.
            $span = Get-ZharpCurrentSpan
            while ($span) { Stop-ZharpSpan $span -Failed -Message ([string](Resolve-ZharpError $InputObject).Exception.Message); $span = Get-ZharpCurrentSpan }
            Send-Zharp
        } elseif ($sent -and ($script:Logs.Count -ge 100)) {
            Send-Zharp
        }
    }
}

# --- Logs -------------------------------------------------------------------------------------

function Add-ZharpLog([string]$Severity, [int]$Number, [string]$Body, $Attributes) {
    if (-not $script:Config -or $script:Config.Disabled) { return }
    $ids = Get-ZharpTraceIds
    $attrs = Get-ZharpContextAttributes
    if ($Attributes) { foreach ($k in $Attributes.Keys) { $attrs[[string]$k] = $Attributes[$k] } }
    $now = Get-ZharpNow
    $null = $script:Logs.Add([ordered]@{ Time = $now; Severity = $Severity; Number = $Number; Body = $Body; Attributes = $attrs; TraceId = $ids[0]; SpanId = $ids[1] })
    if ($script:Logs.Count -ge 500) { Send-Zharp }
}

function Write-ZharpLog {
    <#
    .SYNOPSIS
    Sends a log line to Zharp (whatever ZHARP_LOGS says), on the current trace.
    .DESCRIPTION
    -Stamp sends nothing: it returns the line with ' trace_id=... span_id=...' at its end, for a
    script that writes its own log file the Zharp agent reads.
    .EXAMPLE
    Write-ZharpLog 'copied 120 files' -Attributes @{ files = 120 }
    .EXAMPLE
    Write-ZharpLog 'copied 120 files' -Stamp | Add-Content C:\logs\backup.log
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true, Position = 0, ValueFromPipeline = $true)][string]$Message,
        [ValidateSet('Debug', 'Info', 'Warn', 'Error', 'Fatal')][string]$Level = 'Info',
        [hashtable]$Attributes,
        [switch]$Stamp
    )
    process {
        Initialize-Zharp
        if ($Stamp) {
            $ids = Get-ZharpTraceIds
            if (-not $ids[0] -or $Message -match 'trace_id') { return $Message }
            return "$($Message.TrimEnd()) trace_id=$($ids[0]) span_id=$($ids[1])"
        }
        $numbers = @{ Debug = 5; Info = 9; Warn = 13; Error = 17; Fatal = 21 }
        Add-ZharpLog -Severity $Level.ToUpperInvariant() -Number $numbers[$Level] -Body $Message -Attributes $Attributes
    }
}

# --- Sending ----------------------------------------------------------------------------------

function ConvertTo-ZharpAnyValue($Value) {
    if ($Value -is [bool]) { return @{ boolValue = $Value } }
    if ($Value -is [int] -or $Value -is [long] -or $Value -is [int16] -or $Value -is [byte]) { return @{ intValue = [string]$Value } }
    if ($Value -is [double] -or $Value -is [single] -or $Value -is [decimal]) { return @{ doubleValue = [double]$Value } }
    return @{ stringValue = [string]$Value }
}

function ConvertTo-ZharpKeyValues($Map) {
    $list = New-Object System.Collections.ArrayList
    if ($Map) {
        foreach ($k in $Map.Keys) {
            $v = $Map[$k]
            if ($null -eq $v) { continue }
            $null = $list.Add([ordered]@{ key = [string]$k; value = (ConvertTo-ZharpAnyValue $v) })
        }
    }
    return , $list.ToArray()
}

function Get-ZharpScope { return [ordered]@{ name = 'zharp-powershell'; version = $script:Version } }

function ConvertTo-ZharpTracesJson($Spans) {
    $out = foreach ($s in $Spans) {
        $span = [ordered]@{
            traceId = $s.TraceId
            spanId = $s.SpanId
            name = $s.Name
            kind = $s.Kind
            startTimeUnixNano = $s.Start
            endTimeUnixNano = $s.End
            attributes = ConvertTo-ZharpKeyValues (Merge-ZharpMaps (Get-ZharpContextAttributes) $s.Attributes)
            events = @(foreach ($e in $s.Events) { [ordered]@{ name = $e.Name; timeUnixNano = $e.Time; attributes = (ConvertTo-ZharpKeyValues $e.Attributes) } })
            status = [ordered]@{ code = $s.Status; message = $s.StatusMessage }
        }
        if ($s.ParentSpanId) { $span['parentSpanId'] = $s.ParentSpanId }
        $span
    }
    $body = [ordered]@{
        resourceSpans = @([ordered]@{
            resource = [ordered]@{ attributes = (ConvertTo-ZharpKeyValues $script:Config.Resource) }
            scopeSpans = @([ordered]@{ scope = (Get-ZharpScope); spans = @($out) })
        })
    }
    return ConvertTo-Json -InputObject $body -Depth 20 -Compress
}

function ConvertTo-ZharpLogsJson($Logs) {
    $out = foreach ($l in $Logs) {
        $record = [ordered]@{
            timeUnixNano = $l.Time
            observedTimeUnixNano = $l.Time
            severityNumber = $l.Number
            severityText = $l.Severity
            body = @{ stringValue = $l.Body }
            attributes = ConvertTo-ZharpKeyValues $l.Attributes
        }
        if ($l.TraceId) { $record['traceId'] = $l.TraceId; $record['spanId'] = $l.SpanId }
        $record
    }
    $body = [ordered]@{
        resourceLogs = @([ordered]@{
            resource = [ordered]@{ attributes = (ConvertTo-ZharpKeyValues $script:Config.Resource) }
            scopeLogs = @([ordered]@{ scope = (Get-ZharpScope); logRecords = @($out) })
        })
    }
    return ConvertTo-Json -InputObject $body -Depth 20 -Compress
}

function Merge-ZharpMaps($First, $Second) {
    $out = [ordered]@{}
    foreach ($m in @($First, $Second)) { if ($m) { foreach ($k in $m.Keys) { $out[[string]$k] = $m[$k] } } }
    return $out
}

function ConvertTo-ZharpGzip([string]$Text) {
    $bytes = [Text.Encoding]::UTF8.GetBytes($Text)
    $memory = New-Object IO.MemoryStream
    $gzip = New-Object IO.Compression.GZipStream($memory, [IO.Compression.CompressionMode]::Compress)
    $gzip.Write($bytes, 0, $bytes.Length)
    $gzip.Close()
    return , $memory.ToArray()
}

# One POST, at most two seconds. A failure is never the script's: it is dropped (with ZHARP_DEBUG, said).
function Send-ZharpPayload([string]$Path, [string]$Json) {
    if ($script:Transport) { & $script:Transport $Path $Json; return $true }
    $ProgressPreference = 'SilentlyContinue'
    try {
        $headers = @{ Authorization = "Bearer $($script:Config.Key)"; 'Content-Encoding' = 'gzip'; 'User-Agent' = "zharp-powershell/$($script:Version)" }
        $null = Microsoft.PowerShell.Utility\Invoke-RestMethod -Method Post -Uri "$($script:Config.Endpoint)$Path" -Body (ConvertTo-ZharpGzip $Json) `
            -ContentType 'application/json' -Headers $headers -TimeoutSec 2 -UseBasicParsing -ErrorAction Stop
        return $true
    } catch {
        Write-ZharpDebug "could not send to $Path`: $($_.Exception.Message)"
        return $false
    }
}

function Send-Zharp {
    <#
    .SYNOPSIS
    Sends what is queued now. Invoke-Zharp and the end of the script do this already.
    #>
    [CmdletBinding()]
    param()
    if (-not $script:Config -or $script:Config.Disabled) { return }
    # The error first: if the network is down, the rest isn't tried.
    if ($script:Logs.Count -gt 0) {
        $batch = $script:Logs.ToArray(); $script:Logs.Clear()
        if (-not (Send-ZharpPayload '/v1/logs' (ConvertTo-ZharpLogsJson $batch))) { $script:Spans.Clear(); return }
    }
    if ($script:Spans.Count -gt 0) {
        $batch = $script:Spans.ToArray(); $script:Spans.Clear()
        $null = Send-ZharpPayload '/v1/traces' (ConvertTo-ZharpTracesJson $batch)
    }
}

# --- Cron job monitor pings -------------------------------------------------------------------

function Get-ZharpPingUrl([string]$Monitor) {
    if (-not $Monitor) { return $null }
    if ($Monitor -match '^https?://') { return $Monitor.TrimEnd('/') }
    $base = if ($env:ZHARP_PING_URL) { $env:ZHARP_PING_URL.TrimEnd('/') } else { ($script:Config.Endpoint -replace '/otlp$', '') + '/ping' }
    return "$base/$Monitor"
}

function Send-ZharpPing([string]$Url, [string]$Signal, [string]$TraceId, [string]$Output) {
    if (-not $Url) { return }
    $target = "$Url/$Signal"
    if ($TraceId) { $target += "?trace_id=$TraceId" }
    if ($script:Transport) { & $script:Transport "ping:$target" ([string]$Output); return }
    $ProgressPreference = 'SilentlyContinue'
    try {
        $params = @{ Uri = $target; TimeoutSec = 2; UseBasicParsing = $true; ErrorAction = 'Stop'; Headers = @{ 'User-Agent' = "zharp-powershell/$($script:Version)"; 'X-Host' = [Environment]::MachineName } }
        if ($Output) { $params.Method = 'Post'; $params.Body = $Output; $params.ContentType = 'text/plain; charset=utf-8' } else { $params.Method = 'Get' }
        $null = Microsoft.PowerShell.Utility\Invoke-RestMethod @params
    } catch {
        Write-ZharpDebug "could not ping the monitor: $($_.Exception.Message)"
    }
}

# --- Web calls with the trace -----------------------------------------------------------------

function ConvertTo-ZharpSplat([string]$Command, [object[]]$Arguments) {
    $meta = (Get-Command $Command -CommandType Cmdlet).Parameters
    $named = @{}
    $positional = New-Object System.Collections.ArrayList
    for ($i = 0; $i -lt $Arguments.Count; $i++) {
        $a = $Arguments[$i]
        if ($a -is [string] -and $a -match '^-([A-Za-z][\w]*)(:)?$') {
            $name = $Matches[1]
            $match = @($meta.Keys | Where-Object { $_ -eq $name -or $meta[$_].Aliases -contains $name })
            if ($match.Count -eq 0) { $match = @($meta.Keys | Where-Object { $_ -like "$name*" }) }
            if ($match.Count -eq 1) {
                $param = $meta[$match[0]]
                if ($param.SwitchParameter -and -not $Matches[2]) { $named[$match[0]] = $true; continue }
                $named[$match[0]] = $Arguments[$i + 1]; $i++; continue
            }
        }
        $null = $positional.Add($a)
    }
    if ($positional.Count -gt 0 -and -not $named.ContainsKey('Uri')) { $named['Uri'] = $positional[0]; $positional.RemoveAt(0) }
    if ($positional.Count -gt 0 -and -not $named.ContainsKey('Body')) { $named['Body'] = $positional[0] }
    return $named
}

function Invoke-ZharpWebCall([string]$Command, [object[]]$Arguments) {
    Initialize-Zharp
    $splat = ConvertTo-ZharpSplat $Command $Arguments
    $method = if ($splat.ContainsKey('Method')) { ([string]$splat['Method']).ToUpperInvariant() } else { 'GET' }
    $uri = [string]$splat['Uri']
    $hostName = ''
    try { $hostName = ([uri]$uri).Host } catch { }
    $span = Start-ZharpSpan "$method $hostName" -Kind Client -Attributes @{ 'http.request.method' = $method; 'url.full' = (Get-ZharpSafeUrl $uri); 'server.address' = $hostName }
    $headers = @{}
    if ($splat.ContainsKey('Headers') -and $splat['Headers']) { foreach ($k in $splat['Headers'].Keys) { $headers[$k] = $splat['Headers'][$k] } }
    $headers['traceparent'] = "00-$($span.TraceId)-$($span.SpanId)-01"
    $splat['Headers'] = $headers
    try {
        $result = & "Microsoft.PowerShell.Utility\$Command" @splat
        if ($result -and $result.PSObject.Properties['StatusCode']) { $span.Attributes['http.response.status_code'] = [int]$result.StatusCode }
        Stop-ZharpSpan $span
        return $result
    } catch {
        $web = Get-ZharpWebAttributes $_.Exception $_
        if ($web.Contains('http.response.status_code')) { $span.Attributes['http.response.status_code'] = $web['http.response.status_code'] }
        Stop-ZharpSpan $span -Failed -Message ([string]$_.Exception.Message)
        throw
    }
}

function Invoke-ZharpRestMethod {
    <#
    .SYNOPSIS
    Invoke-RestMethod with the trace: a span for the call and a traceparent header, so a service
    running a Zharp SDK continues the script's trace. Takes Invoke-RestMethod's parameters.
    #>
    Invoke-ZharpWebCall 'Invoke-RestMethod' $args
}

function Invoke-ZharpWebRequest {
    <#
    .SYNOPSIS
    Invoke-WebRequest with the trace (see Invoke-ZharpRestMethod). Takes Invoke-WebRequest's parameters.
    #>
    Invoke-ZharpWebCall 'Invoke-WebRequest' $args
}

# --- The block --------------------------------------------------------------------------------

function Invoke-Zharp {
    <#
    .SYNOPSIS
    Runs a script block as one span: its name, duration and how it ended.
    .DESCRIPTION
    An error that ends the block is reported once, with its stack and the code that ran, then
    rethrown, so the script fails exactly as it would have. Inside the block errors stop the block
    ($ErrorActionPreference = 'Stop') unless -KeepErrorAction. With -Monitor, the Cron job monitor
    is pinged when the block starts and when it ends, with how it ended.
    .EXAMPLE
    Invoke-Zharp {
        Copy-Database -Name shop
        Send-Report
    }
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true, Position = 0)][scriptblock]$ScriptBlock,
        [string]$Name,
        [string]$Monitor,
        [hashtable]$Attributes,
        [switch]$KeepErrorAction,
        [switch]$TraceHttp
    )
    Initialize-Zharp
    $caller = $PSCmdlet.SessionState
    $previousPreference = $caller.PSVariable.GetValue('ErrorActionPreference')
    if (-not $KeepErrorAction) { $caller.PSVariable.Set('ErrorActionPreference', 'Stop') }
    if ($script:Config.Disabled) {
        try { & $ScriptBlock } finally { $caller.PSVariable.Set('ErrorActionPreference', $previousPreference) }
        return
    }

    if (-not $Name) {
        $scriptPath = $MyInvocation.ScriptName
        $Name = if ($scriptPath) { Split-Path -Leaf $scriptPath } else { 'Invoke-Zharp' }
    }
    $spanAttributes = @{}
    if ($MyInvocation.ScriptName) { $spanAttributes['code.file.path'] = $MyInvocation.ScriptName }
    if ($Attributes) { foreach ($k in $Attributes.Keys) { $spanAttributes[$k] = $Attributes[$k] } }
    $span = Start-ZharpSpan $Name -Attributes $spanAttributes
    $outermost = $script:Active.Count -eq 1
    if (-not $Monitor -and $outermost) { $Monitor = $script:Config.Monitor }
    $pingUrl = Get-ZharpPingUrl $Monitor
    if ($pingUrl) { Send-ZharpPing $pingUrl 'start' '' '' }

    # -TraceHttp: the two web cmdlets get a traceparent header for the block, through a copy of the
    # caller's $PSDefaultParameterValues (a call passing its own -Headers keeps them as they are).
    $previousDefaults = $null
    if ($TraceHttp) {
        $previousDefaults = $caller.PSVariable.GetValue('PSDefaultParameterValues')
        $defaults = New-Object System.Management.Automation.DefaultParameterDictionary
        if ($previousDefaults) { foreach ($k in @($previousDefaults.Keys)) { $defaults[$k] = $previousDefaults[$k] } }
        foreach ($command in @('Invoke-RestMethod', 'Invoke-WebRequest')) {
            if (-not $defaults.Contains("${command}:Headers")) { $defaults["${command}:Headers"] = @{ traceparent = "00-$($span.TraceId)-$($span.SpanId)-01" } }
        }
        $caller.PSVariable.Set('PSDefaultParameterValues', $defaults)
    }

    $failure = $null
    $completed = $false
    try {
        if ($script:Config.Logs) {
            # Windows PowerShell turns a native program's stderr into errors when it is redirected
            # under Stop: there the error stream is left alone.
            $mergeErrors = $KeepErrorAction -or ($PSVersionTable.PSVersion -ge [version]'7.2')
            if ($mergeErrors) {
                & $ScriptBlock 2>&1 3>&1 4>&1 5>&1 6>&1 | ForEach-Object { Write-ZharpStreamRecord $_ $PSCmdlet }
            } else {
                & $ScriptBlock 3>&1 4>&1 5>&1 6>&1 | ForEach-Object { Write-ZharpStreamRecord $_ $PSCmdlet }
            }
        } else {
            & $ScriptBlock
        }
        $completed = $true
    } catch {
        $failure = $_
        $null = Submit-ZharpError $_ $false $null
        throw
    } finally {
        $caller.PSVariable.Set('ErrorActionPreference', $previousPreference)
        if ($TraceHttp) { $caller.PSVariable.Set('PSDefaultParameterValues', $previousDefaults) }
        if ($failure) {
            $message = [string](Resolve-ZharpError $failure).Exception.Message
            $span.Attributes['process.exit.code'] = 1
            Stop-ZharpSpan $span -Failed -Message $message
            if ($pingUrl) {
                $stack = Get-ZharpStack (Resolve-ZharpError $failure).Record
                Send-ZharpPing $pingUrl '1' $span.TraceId ("$message`n$stack").Trim()
            }
        } elseif ($completed) {
            Stop-ZharpSpan $span
            if ($pingUrl) { Send-ZharpPing $pingUrl '0' $span.TraceId '' }
        } else {
            # `exit` inside the block: PowerShell doesn't say with which code. No finish ping, so
            # the monitor goes by its schedule; use return or throw inside the block instead.
            $span.Attributes['zharp.ended'] = 'exit'
            Stop-ZharpSpan $span
        }
        if ($outermost -or $failure) { Send-Zharp }
    }
}

# With ZHARP_LOGS=true: each record from the block's streams is sent, then written where it was going.
function Write-ZharpStreamRecord($Record, $Cmdlet) {
    if ($Record -is [System.Management.Automation.ErrorRecord]) {
        Add-ZharpLog -Severity 'ERROR' -Number 17 -Body ([string]$Record) -Attributes @{ 'log.iostream' = 'stderr' }
        $Cmdlet.WriteError($Record)
    } elseif ($Record -is [System.Management.Automation.WarningRecord]) {
        Add-ZharpLog -Severity 'WARN' -Number 13 -Body $Record.Message -Attributes $null
        $Cmdlet.WriteWarning($Record.Message)
    } elseif ($Record -is [System.Management.Automation.VerboseRecord]) {
        Add-ZharpLog -Severity 'DEBUG' -Number 5 -Body $Record.Message -Attributes @{ 'powershell.stream' = 'verbose' }
        $Host.UI.WriteVerboseLine($Record.Message)
    } elseif ($Record -is [System.Management.Automation.DebugRecord]) {
        Add-ZharpLog -Severity 'DEBUG' -Number 5 -Body $Record.Message -Attributes @{ 'powershell.stream' = 'debug' }
        $Host.UI.WriteDebugLine($Record.Message)
    } elseif ($Record -is [System.Management.Automation.InformationRecord]) {
        $isHost = @($Record.Tags) -contains 'PSHOST'
        Add-ZharpLog -Severity 'INFO' -Number 9 -Body ([string]$Record.MessageData) -Attributes @{ 'powershell.stream' = $(if ($isHost) { 'host' } else { 'information' }) }
        # Write-Host's records (tagged PSHOST) are shown by the host again; 6> redirects still apply.
        $Cmdlet.WriteInformation($Record)
    } else {
        $Record
    }
}

Export-ModuleMember -Function Start-Zharp, Invoke-Zharp, Out-Zharp, Start-ZharpSpan, Stop-ZharpSpan, Set-ZharpUser, Set-ZharpTag, Write-ZharpLog, Send-Zharp, Invoke-ZharpRestMethod, Invoke-ZharpWebRequest
