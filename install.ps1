# WinMole installer
#   irm https://raw.githubusercontent.com/Penz7/winmole/main/install.ps1 | iex
# Downloads WinMole to %LOCALAPPDATA%\Programs\WinMole and adds it to the user PATH (no admin needed).
# Run the same command again to update to the latest version.
# (ASCII only on purpose: safe for both `irm | iex` and Windows PowerShell 5.1 without BOM.)

$ErrorActionPreference = 'Stop'
& {
    $repo = 'https://raw.githubusercontent.com/Penz7/winmole/main'
    $dir = Join-Path $env:LOCALAPPDATA 'Programs\WinMole'
    $files = 'mo.cmd', 'winmole.ps1', 'README.md', 'LICENSE'
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

    Write-Host ''
    Write-Host '  WinMole installer' -ForegroundColor Cyan
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }

    foreach ($f in $files) {
        Write-Host "  - download $f" -ForegroundColor DarkGray
        Invoke-WebRequest -UseBasicParsing -Uri "$repo/$f" -OutFile (Join-Path $dir "$f.tmp")
    }
    # Replace files only after every download succeeded, so a failed run never leaves a half-installed copy
    foreach ($f in $files) {
        Move-Item -LiteralPath (Join-Path $dir "$f.tmp") -Destination (Join-Path $dir $f) -Force
    }
    # Drop the old compiled core so it is rebuilt for the new version
    Remove-Item (Join-Path $dir 'lib') -Recurse -Force -ErrorAction SilentlyContinue

    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $dir 'winmole.ps1') install
}
