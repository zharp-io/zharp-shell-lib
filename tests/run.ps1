# Runs the module's tests: with Pester 5 when it is installed, else with tests/MiniPester.ps1.
#   pwsh -File tests/run.ps1            powershell.exe -File tests\run.ps1
param([switch]$Mini)
$ErrorActionPreference = 'Continue'
$pester = Get-Module -ListAvailable Pester | Where-Object { $_.Version -ge [version]'5.0' } | Select-Object -First 1
$file = Join-Path $PSScriptRoot 'Zharp.Tests.ps1'
"PowerShell $($PSVersionTable.PSVersion) ($($PSVersionTable.PSEdition))"
if ($pester -and -not $Mini) {
    Import-Module $pester -Force
    $result = Invoke-Pester -Path $file -Output Detailed -PassThru
    exit $result.FailedCount
}

"Pester 5 not found: running with MiniPester"
. (Join-Path $PSScriptRoot 'MiniPester.ps1')
. $file
$failed = 0; $passed = 0
foreach ($block in $global:MiniPester.FileBeforeAll) { . $block }
foreach ($d in $global:MiniPester.Describes) {
    $global:MiniPester.Current = $d
    . $d.Body
    "Describing $($d.Name)"
    foreach ($block in $d.BeforeAll) { . $block }
    foreach ($it in $d.Its) {
        try {
            foreach ($block in $d.BeforeEach) { . $block }
            . $it.Block
            "  [+] $($it.Name)"; $passed++
        } catch {
            "  [-] $($it.Name)"; "      $($_.Exception.Message) ($($_.InvocationInfo.ScriptName):$($_.InvocationInfo.ScriptLineNumber))"; $failed++
        }
    }
    foreach ($block in $d.AfterAll) { . $block }
}
"Tests passed: $passed, failed: $failed"
exit $failed
