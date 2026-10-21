# Offline end-to-end test of the protocol layer: mock server <-> mock client.
#
# It needs no game running, so it is what catches breakage in the peer itself
# (it already caught two: a server that never sent its GameMaker banner, and an
# INTENT_PLACE target computed as a tuple). The *game* half still needs a live
# run - see the README.
#
#   powershell -ExecutionPolicy Bypass -File tools/mock_e2e.ps1
#
# Exit code 0 only if every step of the session appears in the log.

$ErrorActionPreference = "Stop"
$here = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
Set-Location $here

$port = 6599
$log = Join-Path $env:TEMP "coop_e2e"
New-Item -ItemType Directory -Force -Path $log | Out-Null
$srvLog = Join-Path $log "server.log"
$cliLog = Join-Path $log "client.log"
Remove-Item $srvLog, $cliLog -ErrorAction SilentlyContinue

python -u tools/coop_mockpeer.py selftest
if ($LASTEXITCODE -ne 0) { Write-Host "selftest FAILED"; exit 1 }

$srv = Start-Process -FilePath "python" `
    -ArgumentList "-u", "tools/coop_mockpeer.py", "server", "--port", "$port", "--loot" `
    -RedirectStandardOutput $srvLog -RedirectStandardError "$log/server.err" `
    -PassThru -NoNewWindow
Start-Sleep -Seconds 2

python -u tools/coop_mockpeer.py client --port $port --for 8 > $cliLog 2>&1
Stop-Process -Id $srv.Id -Force -ErrorAction SilentlyContinue

$text = Get-Content $cliLog -Raw
$want = @(
    "GM handshake complete (client side)",
    "<- WELCOME protocol=5",
    # M3.1: the name rides the handshake, so a WELCOME that does not carry it is a failure -
    # the field order slip this catches is exactly the one that cost M2.2 a whole evening.
    "name='mock'",
    "<- PONG",
    "<- STRUCTURE_TABLE",
    "<- ITEM_TABLE",
    "<- DROP",
    "<- PICKUP",
    "<- RESOURCE_DESTROY",
    "<- DEBUG e2e: a debug line from the mock host",
    "-> INTENT_PLACE",
    # The mock as a **host** confirms the client's placement. Without this the client's
    # apply path - "the host says a structure exists here, so put it here" - has no offline
    # test at all, because the mock used to be only ever a client. (The log line is
    # "MUTATION seq=...", not "MUTATION_PLACE": that is how the peer prints it.)
    "<- MUTATION seq="
)
$failed = @()
foreach ($w in $want) { if ($text -notmatch [regex]::Escape($w)) { $failed += $w } }

if ($failed.Count -gt 0) {
    Write-Host "e2e FAILED, missing: $($failed -join '; ')"
    Write-Host "--- client log ---"; Get-Content $cliLog -Tail 20
    exit 1
}
Write-Host "e2e ok: handshake, welcome, pong, structure table, item table, the three loot packets and INTENT_PLACE all seen"
Write-Host "(logs in $log)"
exit 0
