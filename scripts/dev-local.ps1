# Starts SupoClip natively on Windows (no Docker).
#
#   powershell -ExecutionPolicy Bypass -File scripts/dev-local.ps1
#
# Starts, in this order: PostgreSQL (project-local cluster on port 5433),
# Redis (6379), FastAPI backend (8000), the video/cron worker, and Next.js
# (3107). Each service gets its own log under logs/.
#
# Stop everything with scripts/stop-local.ps1.

$ErrorActionPreference = "Stop"

$root = Split-Path -Parent $PSScriptRoot
$pgBin = "C:\Program Files\PostgreSQL\17\bin"
$logDir = Join-Path $root "logs"
$pgData = Join-Path $root ".pgdata"
$compatPath = Join-Path $root "backend\.win-compat"

New-Item -ItemType Directory -Force $logDir | Out-Null
New-Item -ItemType Directory -Force (Join-Path $root "backend\uploads") | Out-Null
New-Item -ItemType Directory -Force (Join-Path $root "backend\clips") | Out-Null

function Test-Port([int]$port) {
    return [bool](Get-NetTCPConnection -State Listen -LocalPort $port -ErrorAction SilentlyContinue)
}

function Start-Logged([string]$name, [string]$workdir, [scriptblock]$command) {
    $log = Join-Path $logDir "$name.log"
    Start-Process -FilePath "powershell" -WindowStyle Hidden -WorkingDirectory $workdir `
        -ArgumentList "-NoProfile", "-Command", "& { $command } *> '$log'"
    Write-Host "  started $name -> logs/$name.log"
}

Write-Host "SupoClip local stack" -ForegroundColor Cyan

# 1. PostgreSQL (project-local cluster, port 5433; leaves the machine-wide
#    service on 5432 untouched).
if (-not (Test-Port 5433)) {
    Write-Host "Starting PostgreSQL on 127.0.0.1:5433 ..."
    Start-Logged "postgres" $root "& '$pgBin\postgres.exe' -D '$pgData' -p 5433"
    Start-Sleep -Seconds 3
} else {
    Write-Host "PostgreSQL already listening on 5433"
}

# 2. Redis
if (-not (Test-Port 6379)) {
    Write-Host "Starting Redis on 127.0.0.1:6379 ..."
    Start-Logged "redis" $root "redis-server --port 6379 --save '' --appendonly no"
    Start-Sleep -Seconds 2
} else {
    Write-Host "Redis already listening on 6379"
}

# 3. Backend API
if (-not (Test-Port 8000)) {
    Write-Host "Starting backend on http://127.0.0.1:8000 ..."
    Start-Logged "backend" (Join-Path $root "backend") "`$env:PYTHONPATH='$compatPath'; uv run uvicorn src.main:app --host 127.0.0.1 --port 8000"
} else {
    Write-Host "Backend already listening on 8000"
}

# 4. Video + cron worker
Write-Host "Starting worker (video + cron) ..."
Start-Logged "worker" (Join-Path $root "backend") "`$env:PYTHONPATH='$compatPath'; uv run python -m src.workers.run_workers"

# 5. Next.js frontend
if (-not (Test-Port 3107)) {
    Write-Host "Starting frontend on http://localhost:3107 ..."
    Start-Logged "frontend" (Join-Path $root "frontend") "pnpm run dev"
} else {
    Write-Host "Frontend already listening on 3107"
}

Write-Host ""
Write-Host "Ready:" -ForegroundColor Green
Write-Host "  App       http://localhost:3107"
Write-Host "  API docs  http://localhost:8000/docs"
Write-Host "  Logs      logs\"
