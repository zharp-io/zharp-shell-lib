# A small stand-in for the part of Pester 5 the tests use, for machines with only the Pester 3.4
# that ships with Windows PowerShell 5.1. run.ps1 drives it; it records blocks, then runs them
# at the runner's own scope, as Pester does.

$global:MiniPester = @{ FileBeforeAll = @(); Describes = New-Object System.Collections.ArrayList; Current = $null }

function BeforeAll([scriptblock]$Block) { if ($global:MiniPester.Current) { $global:MiniPester.Current.BeforeAll += $Block } else { $global:MiniPester.FileBeforeAll += $Block } }
function BeforeEach([scriptblock]$Block) { $global:MiniPester.Current.BeforeEach += $Block }
function AfterAll([scriptblock]$Block) { $global:MiniPester.Current.AfterAll += $Block }
function It([string]$Name, [scriptblock]$Block) { $null = $global:MiniPester.Current.Its.Add(@{ Name = $Name; Block = $Block }) }
function Describe([string]$Name, [scriptblock]$Block) {
    $null = $global:MiniPester.Describes.Add(@{ Name = $Name; Body = $Block; BeforeAll = @(); BeforeEach = @(); AfterAll = @(); Its = (New-Object System.Collections.ArrayList) })
}

function Should {
    param(
        [Parameter(ValueFromPipeline = $true)]$ActualValue,
        [switch]$Not, $Be, $Match, $Contain, $BeGreaterThan,
        [switch]$BeNullOrEmpty, [switch]$BeTrue, [switch]$BeFalse
    )
    begin { $items = New-Object System.Collections.ArrayList }
    process { $null = $items.Add($ActualValue) }
    end {
        $actual = if ($items.Count -eq 1) { $items[0] } elseif ($items.Count -eq 0) { $null } else { $items.ToArray() }
        $ok = $true; $what = ''
        if ($PSBoundParameters.ContainsKey('Be')) { $ok = $actual -eq $Be; $what = "be '$Be'" }
        elseif ($PSBoundParameters.ContainsKey('Match')) { $ok = [string]$actual -match $Match; $what = "match '$Match'" }
        elseif ($PSBoundParameters.ContainsKey('Contain')) { $ok = @($items) -contains $Contain; $what = "contain '$Contain'" }
        elseif ($PSBoundParameters.ContainsKey('BeGreaterThan')) { $ok = $actual -gt $BeGreaterThan; $what = "be greater than $BeGreaterThan" }
        elseif ($BeNullOrEmpty) { $ok = ($null -eq $actual) -or ([string]$actual -eq '') -or (@($actual).Count -eq 0); $what = 'be null or empty' }
        elseif ($BeTrue) { $ok = [bool]$actual -eq $true; $what = 'be true' }
        elseif ($BeFalse) { $ok = [bool]$actual -eq $false; $what = 'be false' }
        if ($Not) { $ok = -not $ok; $what = "not $what" }
        if (-not $ok) { throw "Expected '$actual' to $what" }
    }
}
