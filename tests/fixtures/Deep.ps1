# Functions the tests call: an error three levels deep, and other ways scripts fail.
function Copy-Database {
    param([string]$Name)
    Get-Item -Path (Join-Path ([IO.Path]::GetTempPath()) "zharp-missing-$Name")
    'copied'
}

function Invoke-Backup {
    Copy-Database -Name 'shop'
}

function Start-Nightly {
    Invoke-Backup
}

function Stop-WithText {
    throw 'disk is full'
}

function Read-MissingFile {
    [IO.File]::ReadAllText((Join-Path ([IO.Path]::GetTempPath()) 'zharp-no-such-file.txt'))
}
