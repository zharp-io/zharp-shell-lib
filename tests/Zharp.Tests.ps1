# Pester 5 tests for the Zharp module. Run with tests/run.ps1 (Pester 5, or the small runner in
# tests/MiniPester.ps1 where Pester 5 isn't installed, such as a stock Windows PowerShell 5.1).

BeforeAll {
    . (Join-Path $PSScriptRoot 'Helpers.ps1')
    . (Join-Path $PSScriptRoot 'fixtures/Deep.ps1')
    $script:Fixture = (Resolve-Path (Join-Path $PSScriptRoot 'fixtures/Deep.ps1')).Path
}

Describe 'An error that ends the block' {
    BeforeEach { Import-ZharpForTest }

    It 'is reported once, with the stack, the code that ran, and rethrown' {
        $caught = $null
        try { Invoke-Zharp -Name 'nightly' { Start-Nightly } } catch { $caught = $_ }
        $caught | Should -Not -BeNullOrEmpty
        $caught.Exception.GetType().Name | Should -Be 'ItemNotFoundException'

        $errors = Get-ErrorLogs
        $errors.Count | Should -Be 1
        $a = Get-Attrs $errors[0].attributes
        $errors[0].severityText | Should -Be 'ERROR'
        $a['exception.type'] | Should -Be 'System.Management.Automation.ItemNotFoundException'
        $a['zharp.handled'] | Should -Be 'false'
        $a['powershell.error.id'] | Should -Match '^PathNotFound'
        $lines = $a['exception.stacktrace'] -split "`n"
        $lines[0] | Should -Match '^at Copy-Database, .*Deep\.ps1: line 4$'
        $lines[1] | Should -Match '^at Invoke-Backup, .*Deep\.ps1: line 9$'
        $lines[2] | Should -Match '^at Start-Nightly, .*Deep\.ps1: line 13$'
        $a['exception.stacktrace'] | Should -Not -Match 'Zharp\.psm1'
        $a['code.line.number'] | Should -Be 4
        $a['code.column.number'] | Should -BeGreaterThan 0

        $context = $a['zharp.source_context'] | ConvertFrom-Json
        $context[0].line | Should -Be 4
        $context[0].code | Should -Match 'Get-Item -Path'
        $context[0].pre.Count | Should -Be 3
        $context[0].post.Count | Should -Be 5
        $context[1].code | Should -Match "Copy-Database -Name 'shop'"
    }

    It 'ends the span as failed, with the exception on it for the trace view' {
        try { Invoke-Zharp -Name 'nightly' { Start-Nightly } } catch { }
        $spans = Get-SentSpans
        $spans.Count | Should -Be 1
        $spans[0].name | Should -Be 'nightly'
        $spans[0].status.code | Should -Be 2
        $spans[0].events[0].name | Should -Be 'exception'
        (Get-Attrs $spans[0].events[0].attributes)['zharp.deferred'] | Should -Be 'true'
        $log = (Get-ErrorLogs)[0]
        $log.traceId | Should -Be $spans[0].traceId
        $log.spanId | Should -Be $spans[0].spanId
    }

    It 'reports throw "text" as a RuntimeException' {
        try { Invoke-Zharp { Stop-WithText } } catch { }
        $a = Get-Attrs (Get-ErrorLogs)[0].attributes
        $a['exception.type'] | Should -Be 'System.Management.Automation.RuntimeException'
        $a['exception.message'] | Should -Be 'disk is full'
        $a['exception.stacktrace'] | Should -Match '^at Stop-WithText, .*Deep\.ps1: line 17'
    }

    It 'names the .NET exception a method call threw' {
        try { Invoke-Zharp { Read-MissingFile } } catch { }
        $a = Get-Attrs (Get-ErrorLogs)[0].attributes
        $a['exception.type'] | Should -Be 'System.IO.FileNotFoundException'
    }

    It 'is reported once through nested blocks' {
        try { Invoke-Zharp -Name outer { Invoke-Zharp -Name inner { Stop-WithText } } } catch { }
        (Get-ErrorLogs).Count | Should -Be 1
        $spans = Get-SentSpans
        $spans.Count | Should -Be 2
        $inner = $spans | Where-Object { $_.name -eq 'inner' }
        $outer = $spans | Where-Object { $_.name -eq 'outer' }
        $inner.parentSpanId | Should -Be $outer.spanId
        $inner.traceId | Should -Be $outer.traceId
    }

    It 'is not reported again after Out-Zharp reported it as handled' {
        try { Invoke-Zharp { try { Stop-WithText } catch { $_ | Out-Zharp; throw } } } catch { }
        $errors = Get-ErrorLogs
        $errors.Count | Should -Be 1
        (Get-Attrs $errors[0].attributes)['zharp.handled'] | Should -Be 'true'
    }
}

Describe 'Stopping on the first error' {
    BeforeEach { Import-ZharpForTest }

    It 'turns a non-terminating error into one that ends the block' {
        $after = $false
        try { Invoke-Zharp { Get-Item (Join-Path ([IO.Path]::GetTempPath()) 'zharp-nope'); $after = $true } } catch { }
        $after | Should -BeFalse
        (Get-ErrorLogs).Count | Should -Be 1
    }

    It 'leaves the error behaviour alone with -KeepErrorAction' {
        $script:afterKeep = $false
        Invoke-Zharp -KeepErrorAction { Get-Item (Join-Path ([IO.Path]::GetTempPath()) 'zharp-nope') -ErrorAction SilentlyContinue; $script:afterKeep = $true }
        $script:afterKeep | Should -BeTrue
        (Get-ErrorLogs).Count | Should -Be 0
        (Get-SentSpans)[0].status.code | Should -Be 0
    }

    It 'restores the caller''s ErrorActionPreference after the block' {
        $ErrorActionPreference = 'Continue'
        Invoke-Zharp { $null = 1 }
        $ErrorActionPreference | Should -Be 'Continue'
    }

    It 'runs the block as written without a key, sending nothing' {
        Import-ZharpForTest -Env @{ ZHARP_KEY = $null }
        $result = Invoke-Zharp { 'still runs' }
        $result | Should -Be 'still runs'
        $global:ZharpSent.Count | Should -Be 0
    }
}

Describe 'The trace' {
    BeforeEach { Import-ZharpForTest }

    It 'is passed to programs the block starts as TRACEPARENT, and put back after' {
        $env:TRACEPARENT = $null
        $inside = Invoke-Zharp -Name job { $env:TRACEPARENT }
        $span = (Get-SentSpans)[0]
        $inside | Should -Be "00-$($span.traceId)-$($span.spanId)-01"
        $env:TRACEPARENT | Should -BeNullOrEmpty
    }

    It 'continues a trace the script was started in' {
        Import-ZharpForTest -Env @{ TRACEPARENT = '00-0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331-01' }
        Invoke-Zharp -Name child { $null = 1 }
        $span = (Get-SentSpans)[0]
        $span.traceId | Should -Be '0af7651916cd43dd8448eb211c80319c'
        $span.parentSpanId | Should -Be 'b7ad6b7169203331'
        $span.kind | Should -Be 2
    }

    It 'describes the runtime and service on the resource' {
        Start-Zharp -Service 'nightly-backup' -Environment 'production' -Release '1.2.3'
        try { Invoke-Zharp { Stop-WithText } } catch { }
        $r = Get-SentResource
        $r['service.name'] | Should -Be 'nightly-backup'
        $r['telemetry.sdk.language'] | Should -Be 'powershell'
        $r['deployment.environment.name'] | Should -Be 'production'
        $r['service.version'] | Should -Be '1.2.3'
    }

    It 'puts the user and tags on errors' {
        Set-ZharpUser -Id 42 -Email 'ops@example.com'
        Set-ZharpTag 'tenant' 'acme'
        try { Invoke-Zharp { Stop-WithText } } catch { }
        $a = Get-Attrs (Get-ErrorLogs)[0].attributes
        $a['enduser.id'] | Should -Be '42'
        $a['enduser.email'] | Should -Be 'ops@example.com'
        $a['tenant'] | Should -Be 'acme'
    }

    It 'has spans for steps' {
        Invoke-Zharp -Name job {
            $s = Start-ZharpSpan 'copy files' -Attributes @{ files = 3 }
            Stop-ZharpSpan $s
        }
        $spans = Get-SentSpans
        $step = $spans | Where-Object { $_.name -eq 'copy files' }
        $job = $spans | Where-Object { $_.name -eq 'job' }
        $step.parentSpanId | Should -Be $job.spanId
        (Get-Attrs $step.attributes)['files'] | Should -Be 3
    }
}

Describe 'Logs' {
    It 'are not sent by default; output is left alone' {
        Import-ZharpForTest
        $out = Invoke-Zharp { 'data'; Write-Warning 'careful' 3>$null }
        $out | Should -Be 'data'
        (Get-SentLogs).Count | Should -Be 0
    }

    It 'are sent with ZHARP_LOGS=true: warnings, information and Write-Host, not Output' {
        Import-ZharpForTest -Env @{ ZHARP_LOGS = 'true' }
        $out = Invoke-Zharp {
            'data'
            Write-Warning 'careful'
            Write-Information 'step two'
            Write-Host 'hello host'
        } 3>$null 6>$null
        $out | Should -Be 'data'
        $bodies = @((Get-SentLogs) | ForEach-Object { $_.body.stringValue })
        $bodies | Should -Contain 'careful'
        $bodies | Should -Contain 'step two'
        $bodies | Should -Contain 'hello host'
        $bodies | Should -Not -Contain 'data'
        $warn = (Get-SentLogs) | Where-Object { $_.body.stringValue -eq 'careful' }
        $warn.severityText | Should -Be 'WARN'
        $warn.traceId | Should -Be (Get-SentSpans)[0].traceId
    }

    It 'Write-ZharpLog sends a line whatever ZHARP_LOGS says' {
        Import-ZharpForTest
        Invoke-Zharp { Write-ZharpLog 'copied 3 files' -Attributes @{ files = 3 } }
        $log = (Get-SentLogs)[0]
        $log.body.stringValue | Should -Be 'copied 3 files'
        $log.severityText | Should -Be 'INFO'
        (Get-Attrs $log.attributes)['files'] | Should -Be 3
    }

    It 'Write-ZharpLog -Stamp returns the line with the ids, sending nothing' {
        Import-ZharpForTest
        $line = Invoke-Zharp -Name job { Write-ZharpLog 'copied' -Stamp }
        $span = (Get-SentSpans)[0]
        $line | Should -Be "copied trace_id=$($span.traceId) span_id=$($span.spanId)"
        (Get-SentLogs).Count | Should -Be 0
    }
}

Describe 'Cron job monitor pings' {
    BeforeEach { Import-ZharpForTest }

    It 'pings start, then 0 with the trace when the block succeeds' {
        Invoke-Zharp -Monitor 'tok123' { $null = 1 }
        $pings = Get-SentPings
        $pings.Count | Should -Be 2
        $pings[0].Path | Should -Be 'ping:https://api.zharp.io/api/v1/ping/tok123/start'
        $trace = (Get-SentSpans)[0].traceId
        $pings[1].Path | Should -Be "ping:https://api.zharp.io/api/v1/ping/tok123/0?trace_id=$trace"
    }

    It 'pings 1 with the error as output when the block fails' {
        try { Invoke-Zharp -Monitor 'tok123' { Stop-WithText } } catch { }
        $pings = Get-SentPings
        $pings[1].Path | Should -Match '/ping/tok123/1\?trace_id=[0-9a-f]{32}$'
        $pings[1].Json | Should -Match 'disk is full'
        $pings[1].Json | Should -Match 'at Stop-WithText'
    }

    It 'follows the endpoint (a self-hosted or local backend) and takes a full URL' {
        Import-ZharpForTest -Env @{ ZHARP_ENDPOINT = 'http://localhost:3000/api/v1/otlp'; ZHARP_MONITOR = 'abc' }
        Invoke-Zharp { $null = 1 }
        (Get-SentPings)[0].Path | Should -Be 'ping:http://localhost:3000/api/v1/ping/abc/start'
        Invoke-Zharp -Monitor 'https://ping.example.com/p/xyz' { $null = 1 }
        (Get-SentPings)[2].Path | Should -Be 'ping:https://ping.example.com/p/xyz/start'
    }
}

Describe 'Web calls' {
    BeforeAll { $script:Server = Start-TestHttpServer 404 }
    AfterAll { Stop-TestHttpServer $script:Server }
    BeforeEach { Import-ZharpForTest }

    It 'a failed Invoke-RestMethod carries its URL, method and status' {
        $url = "$($script:Server.Url)/orders?id=7&token=secret"
        try { Invoke-Zharp { Invoke-RestMethod -Uri $url -Method Get } } catch { }
        $a = Get-Attrs (Get-ErrorLogs)[0].attributes
        $a['http.response.status_code'] | Should -Be 404
        $a['url.full'] | Should -Be "$($script:Server.Url)/orders?id=7&token=[REDACTED]"
        $a['http.request.method'] | Should -Be 'GET'
    }

    It 'Invoke-ZharpRestMethod sends traceparent and makes a client span' {
        try { Invoke-Zharp -Name job { Invoke-ZharpRestMethod "$($script:Server.Url)/x" -Method Post -Body '{}' -ContentType 'application/json' } } catch { }
        $spans = Get-SentSpans
        $client = $spans | Where-Object { $_.kind -eq 3 }
        $client.name | Should -Match '^POST 127\.0\.0\.1$'
        $client.status.code | Should -Be 2
        (Get-Attrs $client.attributes)['http.response.status_code'] | Should -Be 404
        $script:Server.State.Traceparent | Should -Be "00-$($client.traceId)-$($client.spanId)-01"
    }

    It '-TraceHttp sends traceparent from plain Invoke-RestMethod in the block, and only there' {
        $PSDefaultParameterValues = @{ 'Get-ChildItem:Force' = $true }
        try { Invoke-Zharp -Name job -TraceHttp { Invoke-RestMethod "$($script:Server.Url)/y" } } catch { }
        $span = (Get-SentSpans)[0]
        $script:Server.State.Traceparent | Should -Be "00-$($span.traceId)-$($span.spanId)-01"
        $PSDefaultParameterValues.Count | Should -Be 1
        $PSDefaultParameterValues['Get-ChildItem:Force'] | Should -BeTrue
    }
}

Describe 'Failed queries' {
    BeforeEach { Import-ZharpForTest }

    It 'take the query (values out), the database and the error number' {
        $attrs = & (Get-Module Zharp) {
            $sql = [pscustomobject]@{ PSTypeName = 'System.Data.SqlClient.SqlException'; Number = 208; Server = 'db1'; Procedure = ''; LineNumber = 1; InnerException = $null }
            Get-ZharpSqlAttributes $sql $null
        }
        $attrs['db.system.name'] | Should -Be 'microsoft.sql_server'
        $attrs['db.response.status_code'] | Should -Be '208'
        $attrs['server.address'] | Should -Be 'db1'
        & (Get-Module Zharp) { Get-ZharpObfuscatedQuery "SELECT * FROM Users WHERE Name = 'bob' AND Age > 42 AND t2.x = @p1" } |
            Should -Be 'SELECT * FROM Users WHERE Name = ? AND Age > ? AND t2.x = @p1'
    }
}

Describe 'Helpers' {
    BeforeAll { Import-ZharpForTest }

    It 'masks secrets in URLs' {
        & (Get-Module Zharp) { Get-ZharpSafeUrl 'https://user:pw@api.example.com/a?api_key=1&page=2&Signature=x' } |
            Should -Be 'https://api.example.com/a?api_key=[REDACTED]&page=2&Signature=[REDACTED]'
    }

    It 'reads web cmdlet arguments as the cmdlet would' {
        $splat = & (Get-Module Zharp) { ConvertTo-ZharpSplat 'Invoke-RestMethod' @('https://x.test/a', '-Method', 'Post', '-UseBasicParsing', '-Body', 'b') }
        $splat['Uri'] | Should -Be 'https://x.test/a'
        $splat['Method'] | Should -Be 'Post'
        $splat['UseBasicParsing'] | Should -BeTrue
        $splat['Body'] | Should -Be 'b'
    }

    It 'sends gzip that decompresses to the JSON' {
        $back = & (Get-Module Zharp) {
            $bytes = ConvertTo-ZharpGzip '{"a":"b"}'
            $in = New-Object IO.Compression.GZipStream((New-Object IO.MemoryStream(, $bytes)), [IO.Compression.CompressionMode]::Decompress)
            (New-Object IO.StreamReader($in)).ReadToEnd()
        }
        $back | Should -Be '{"a":"b"}'
    }
}
