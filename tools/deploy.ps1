# Copy this mod into Forager's mods folder.
#
#   powershell -File tools/deploy.ps1
#   powershell -File tools/deploy.ps1 -ModsDir "D:\elsewhere\mods" -Name "Forager Coop"
#
# The game picks the mod up by folder path; it still has to be enabled and COMPILEd
# once in the in-game modding menu.

param(
    [string]$ModsDir = (Join-Path $env:LOCALAPPDATA 'Forager\mods'),
    [string]$Name    = 'Forager Coop'
)

$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
$dst  = Join-Path $ModsDir $Name

if (-not (Test-Path (Join-Path $root 'fmConfig.json'))) {
    throw "fmConfig.json not found in $root - run this from a checkout of the mod."
}

New-Item -ItemType Directory -Force -Path $dst | Out-Null
New-Item -ItemType Directory -Force -Path (Join-Path $dst 'Events') | Out-Null

# Remove our previous scripts so a deleted file does not linger in the game.
Get-ChildItem -Path $dst -Filter '*.gml' -File -ErrorAction SilentlyContinue | Remove-Item -Force
Get-ChildItem -Path (Join-Path $dst 'Events') -Filter '*.gml' -File -ErrorAction SilentlyContinue | Remove-Item -Force

Copy-Item (Join-Path $root 'fmConfig.json') $dst -Force
Get-ChildItem -Path $root -Filter '*.gml' -File | Copy-Item -Destination $dst -Force
Get-ChildItem -Path (Join-Path $root 'Events') -Filter '*.gml' -File |
    Copy-Item -Destination (Join-Path $dst 'Events') -Force

$files = Get-ChildItem -Recurse -File $dst | ForEach-Object { $_.FullName.Substring($dst.Length + 1) }
Write-Host "Deployed to $dst"
$files | ForEach-Object { Write-Host "  $_" }
Write-Host ''
Write-Host 'Next: in the game, modding menu -> enable "Forager Co-op" -> COMPILE.'
