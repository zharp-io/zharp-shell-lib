@{
    RootModule = 'Zharp.psm1'
    ModuleVersion = '0.1.0'
    GUID = '4d7c2b1e-8f3a-4c6e-9b25-7a1f0e6d3c58'
    Author = 'Zharp'
    CompanyName = 'Zharp'
    Copyright = '(c) 2026 Zharp. MIT License.'
    Description = 'Zharp for PowerShell scripts: errors with the stack and the code that ran, a trace per run, logs, and Cron job monitor pings. Windows PowerShell 5.1 and PowerShell 7, no dependencies.'
    PowerShellVersion = '5.1'
    CompatiblePSEditions = @('Desktop', 'Core')
    FunctionsToExport = @(
        'Start-Zharp', 'Invoke-Zharp', 'Out-Zharp', 'Start-ZharpSpan', 'Stop-ZharpSpan',
        'Set-ZharpUser', 'Set-ZharpTag', 'Write-ZharpLog', 'Send-Zharp',
        'Invoke-ZharpRestMethod', 'Invoke-ZharpWebRequest'
    )
    CmdletsToExport = @()
    VariablesToExport = @()
    AliasesToExport = @()
    PrivateData = @{
        PSData = @{
            Tags = @('Zharp', 'monitoring', 'errors', 'tracing', 'OpenTelemetry', 'OTLP', 'logging', 'cron', 'scheduled-tasks', 'PSEdition_Desktop', 'PSEdition_Core', 'Windows', 'Linux', 'MacOS')
            LicenseUri = 'https://github.com/zharp-io/zharp-shell-lib/blob/main/LICENSE'
            ProjectUri = 'https://zharp.io/docs/sdks/powershell'
            ReleaseNotes = 'https://github.com/zharp-io/zharp-shell-lib/blob/main/CHANGELOG.md'
        }
    }
}
