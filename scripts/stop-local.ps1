# Stops the native Windows SupoClip stack started by scripts/dev-local.ps1.
#
#   powershell -ExecutionPolicy Bypass -File scripts/stop-local.ps1

$ErrorActionPreference = "Continue"

$root = Split-Path -Parent $PSScriptRoot
$pgBin = "C:\Program Files\PostgreSQL\17\bin"

function Stop-Port([int]$port, [string]$label) {
    $connections = Get-NetTCPConnection -State Listen -LocalPort $port -ErrorAction SilentlyContinue
    foreach ($owner in ($connections.OwningProcess | Sort-Object -Unique)) {
        if ($owner) {
            Write-Host "Stopping $label (pid $owner)"
            Stop-Process -Id $owner -Force -ErrorAction SilentlyContinue
        }
    }
}

Stop-Port 3107 "frontend"
Stop-Port 8000 "backend"

# Workers are not listeners: match the runner, the arq children it spawns, and
# any orphaned arq process left behind by an earlier start.
Get-CimInstance Win32_Process -Filter "Name = 'python.exe'" |
    Where-Object { $_.CommandLine -like "*src.workers*" -or $_.CommandLine -like "*src.workers.tasks.WorkerSettings*" } |
    ForEach-Object {
        Write-Host "Stopping worker (pid $($_.ProcessId))"
        Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue
    }

Stop-Port 6379 "redis"

Write-Host "Stopping PostgreSQL (port 5433)"
& "$pgBin\pg_ctl.exe" -D (Join-Path $root ".pgdata") -m fast stop 2>&1 | Out-Null

Write-Host "Stopped."
